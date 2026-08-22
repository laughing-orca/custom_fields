module CustomFields
  class ChoiceEditor
    ROOT_PARENT_ID = 0

    def initialize(form)
      @form = form
      @audit = AuditLog.new(form)
    end

    def set_choices(field, values)
      set_dependent_choices([field], Array(values).map { |v| { value: v } })
    end

    def set_dependent_choices(fields, tree)
      inputs = Array(fields)
      return Response.new(results: [], errors: []) if inputs.empty?

      field_ids = inputs.map(&:id)
      errors = []
      results = []

      targets = @form.with_lock do
        live_by_id = @form.fields.where(id: field_ids).index_by(&:id)
        field_errors = {}

        inputs.each { |f| field_errors[f] = Response.build_error("E002", input: f) unless live_by_id.key?(f.id) }

        if field_errors.empty?
          live = field_ids.map { |id| live_by_id[id] }
          if parent_dropdown_field_id(live.first)
            field_errors[live.first] = Response.build_error("E001", reason: "must be root dropdown", input: live.first)
          end

          live.each_cons(2) do |parent, child|
            unless child.depends_on_field_id == parent.id
              field_errors[child] = Response.build_error("E001", reason: "broken dependency chain", input: child)
            end
          end

          live.each do |f|
            unless f.has_choices
              field_errors[f] = Response.build_error("E001", reason: "not a dropdown", input: f)
            end
          end
        end

        if field_errors.any?
          errors = inputs.map do |f|
            field_errors[f] || Response.build_error("E001", reason: "dependency tree validation failed", input: f)
          end
          next
        end

        patch = Changes::ChoicePatch.new
        apply_tree(live, tree, patch)
        @audit.record("choice", live.first.id, "set", patch.to_change, form_version: @form.latest_version)
        live
      end

      if errors.any? || targets.nil?
        return Response.new(results: [], errors: errors)
      end

      expire_cache(targets.map(&:id))
      Response.new(results: targets, errors: [])
    end

    def add_choices(field, values, parent: nil)
      inputs = Array(values)
      return Response.new(results: [], errors: []) if inputs.empty?

      errors = []
      results = []

      added = @form.with_lock do
        live = @form.fields.find_by(id: field.id)
        unless live
          errors = inputs.map { |v| Response.build_error("E002", reason: "field missing", input: v) }
          next
        end
        unless live.has_choices
          errors = inputs.map { |v| Response.build_error("E001", reason: "not a dropdown", input: v) }
          next
        end

        parent_id = parent_choice_id(live, parent)
        unless parent_id
          errors = inputs.map { |v| Response.build_error("E001", parent: parent, reason: "parent choice missing", input: v) }
          next
        end

        # Deterministic sort to prevent deadlock on unique index
        rows = inputs.map { |v| { field_id: live.id, parent_id: parent_id, value: v.to_s, active: true } }
                     .sort_by { |r| [r[:field_id], r[:parent_id], r[:value].to_s] }

        choice_class.upsert_all(rows)
        @audit.record("choice", live.id, "add", Changes::Choice.add(live.name, inputs.map(&:to_s)), form_version: @form.latest_version)
        choice_class.where(field_id: live.id, parent_id: parent_id, value: inputs.map(&:to_s), active: true).to_a
      end

      if errors.any? || added.nil?
        return Response.new(results: [], errors: errors)
      end

      expire_cache(added.map(&:field_id).uniq) if added.any?
      Response.new(results: added, errors: [])
    end

    def rename_choice(field, from, to, parent: nil)
      err = nil
      success = @form.with_lock do
        scope = choices_for(field, [from], parent: parent)
        unless scope.update_all(value: to.to_s).positive?
          err = Response.build_error("E002", value: from, input: from)
          next false
        end

        @audit.record("choice", field.id, "rename", Changes::Choice.rename(field.name, from.to_s, to.to_s), form_version: @form.latest_version)
        true
      rescue ActiveRecord::RecordNotUnique
        err = Response.build_error("E001", reason: "target value already exists", from: from, to: to)
        false
      end

      expire_cache([field.id]) if success
      if success
        Response.new(results: [to.to_s], errors: [])
      else
        Response.new(results: [], errors: [err])
      end
    end

    def delete_choices(field, values, parent: nil)
      inputs = Array(values)
      return Response.new(results: [], errors: []) if inputs.empty?

      errors = []
      results = []

      marked_ids = @form.with_lock do
        found = choices_for(field, inputs, parent: parent).to_a
        found_values = found.map(&:value).to_set
        missing = inputs.map(&:to_s).reject { |v| found_values.include?(v) }
        errors = missing.map { |v| Response.build_error("E002", value: v, input: v) }

        if found.any?
          results = inputs.map(&:to_s).select { |v| found_values.include?(v) }
          closure_ids = subtree_closure(found.map(&:id))
          choice_class.where(id: closure_ids).update_all(active: false)
          @audit.record("choice", field.id, "delete", Changes::Choice.remove(field.name, results), form_version: @form.latest_version)
          closure_ids
        else
          []
        end
      end

      expire_cache(choice_class.where(id: marked_ids).distinct.pluck(:field_id)) if marked_ids.any?
      Response.new(results: results, errors: errors)
    end

    private

    def choices_for(field, values, parent:)
      live = @form.fields.find_by(id: field.id)
      return choice_class.none unless live&.has_choices

      parent_id = parent_choice_id(live, parent)
      return choice_class.none unless parent_id

      choice_class.where(field_id: live.id, parent_id: parent_id, value: values.map(&:to_s), active: true)
    end

    def parent_choice_id(field, parent_value)
      parent_field_id = parent_dropdown_field_id(field)
      return ROOT_PARENT_ID if parent_field_id.nil? && parent_value.nil?
      return if parent_field_id.nil? || parent_value.nil?

      choice_class.where(field_id: parent_field_id, value: parent_value.to_s, active: true).pick(:id)
    end

    def parent_dropdown_field_id(field)
      return if field.depends_on_field_id.to_i.zero?

      @form.fields.where(id: field.depends_on_field_id, has_choices: true).pick(:id)
    end

    # applies choices in bulk one field at a time
    def apply_tree(fields, tree, patch)
      path_by_id = {}
      removed_ids = Set.new
      desired = desired_level(tree, fields.first.name, ROOT_PARENT_ID, [])

      fields.each_with_index do |field, depth|
        active = choice_class.where(field_id: field.id, active: true).pluck(:id, :parent_id, :value)
        active_id_by_key = active.to_h { |id, parent_id, value| [[parent_id, value.to_s], id] }

        # create (or activate) desired choices for a field
        unless desired.empty?
          upsert_level(field, desired)
          desired.each do |node|
            path_by_id[node[:id]] = node[:path]
            patch.add(node[:path]) unless active_id_by_key.key?([node[:parent_id], node[:value]])
          end
        end

        # deactive choices are not desired
        kept_ids = desired.map { |node| node[:id] }.to_set
        pruned_ids = []
        active.each do |id, parent_id, value|
          next if kept_ids.include?(id)

          parent_path = parent_id == ROOT_PARENT_ID ? [] : path_by_id[parent_id]
          path_by_id[id] = parent_path + [field.name, value.to_s]
          patch.remove(path_by_id[id]) unless removed_ids.include?(parent_id)
          removed_ids << id
          pruned_ids << id
        end
        choice_class.where(id: pruned_ids).update_all(active: false) if pruned_ids.any?

        next_field = fields[depth + 1]
        desired =
          if next_field
            # choices for the next field
            desired.flat_map do |parent|
              desired_level(parent[:children], next_field.name, parent[:id], parent[:path])
            end
          else
            []
          end
      end
    end

    def desired_level(nodes, field_name, parent_id, prefix)
      Array(nodes).map do |raw|
        node = raw.symbolize_keys
        value = node[:value].to_s
        { value: value, children: node[:children], parent_id: parent_id, path: prefix + [field_name, value] }
      end
    end

    def upsert_level(field, level)
      rows = level.map { |n| { field_id: field.id, parent_id: n[:parent_id], value: n[:value].to_s, active: true } }
                  .sort_by { |r| [r[:field_id], r[:parent_id], r[:value]] }

      choice_class.upsert_all(rows)
      parent_ids = level.map { |n| n[:parent_id] }.uniq
      ids = choice_class.where(field_id: field.id, parent_id: parent_ids).pluck(:parent_id, :value, :id)
                        .to_h { |p_id, val, id| [[p_id.to_i, val.to_s], id] }
      level.each { |node| node[:id] = ids.fetch([node[:parent_id].to_i, node[:value].to_s]) }
    end

    def subtree_closure(ids)
      return [] if ids.empty?
      table = choice_class.table_name

      sql = choice_class.sanitize_sql_array([<<~SQL.squish, ids: ids])
        WITH RECURSIVE subtree (id) AS (
          SELECT id FROM #{table} WHERE id IN (:ids)
          UNION ALL
          SELECT c.id FROM #{table} c JOIN subtree s ON c.parent_id = s.id
        ) SELECT id FROM subtree
      SQL
      choice_class.connection.select_values(sql).map(&:to_i)
    end

    def expire_cache(ids)
      choice_class.expire_choices_cache(ids) if ids.any?
    end

    def choice_class
      @choice_class ||= @form.class.choice_class_name.constantize
    end
  end
end
