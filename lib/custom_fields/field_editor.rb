module CustomFields
  class FieldEditor
    ROOT_ID = 0
    SELF_REFERENCE_COLUMNS = { depends_on: :depends_on_field_id, parent: :parent_id }.freeze

    def initialize(form)
      @form = form
      @audit = AuditLog.new(form)
    end

    def create_fields(field_specs)
      inputs = Array(field_specs)
      return Response.new(results: [], errors: []) if inputs.empty?

      specs = dependency_order(inputs.map(&:symbolize_keys))
      types = @form.cached_field_types.index_by(&:name)
      errors = []
      results = []

      @form.with_lock do
        version = @form.latest_version
        rows = allocate_slots(specs, types, version)

        allocated_names = rows.map { |r| r[:name] }.to_set
        unallocated = specs.reject { |s| allocated_names.include?(s[:name]) }

        if rows.empty?
          errors = specs.map { |s| Response.build_error("E001", reason: "no free slot for field type", input: s) }
          next
        end

        @form.fields.klass.insert_all(rows.sort_by { |r| [r[:form_id], r[:name]] })
        active_fields = @form.active_fields.to_a

        failed_specs = link_dependencies(specs, active_fields)
        if failed_specs.any?
          failed_set = failed_specs.to_set
          unallocated_set = unallocated.to_set
          errors = specs.map do |s|
            if failed_set.include?(s)
              Response.build_error("E001", reason: "unresolved dependency reference", input: s)
            elsif unallocated_set.include?(s)
              Response.build_error("E001", reason: "no free slot for field type", input: s)
            else
              Response.build_error("E001", reason: "rolled back due to dependency failure", input: s)
            end
          end
          raise ActiveRecord::Rollback
        end

        @form.touch
        created = active_fields.select { |f| allocated_names.include?(f.name) }
        @audit.record("field", 0, "create", Changes::Field.created(created.map(&:name).sort), form_version: version)
        results = created.map { |f| [f.id, f.name] }
        errors = unallocated.map { |s| Response.build_error("E001", reason: "no free slot for field type", input: s) }
      end

      Response.new(results: results, errors: errors)
    end

    def delete_fields(field_names)
      inputs = Array(field_names).compact.uniq
      return Response.new(results: [], errors: []) if inputs.empty?

      errors = []
      results = []

      @form.with_lock do
        current_version = @form.latest_version
        next_version = current_version + 1

        targets = deletion_names(current_version, inputs)
        missing = inputs - targets
        errors = missing.map { |n| Response.build_error("E002", input: n, name: n) }

        if targets.any?
          sorted_targets = targets.sort
          @form.active_fields.where(name: sorted_targets).update_all(valid_to_version: next_version)
          @form.update_columns(latest_version: next_version)
          @form.touch
          @audit.record("field", 0, "delete", Changes::Field.removed(sorted_targets), form_version: next_version)
          results = inputs & targets
        end
      end

      PruneFormVersionsJob.perform_async(@form.class.name, @form.id) if results.any? && @form.prune_due?
      Response.new(results: results, errors: errors)
    end

    private

    def dependency_order(specs)
      by_name = specs.index_by { |s| s[:name].to_s }
      graph = DirectedGraph.new

      specs.each do |spec|
        graph.add_node(spec)
        SELF_REFERENCE_COLUMNS.each_key do |link|
          target = by_name[spec[link].to_s]
          graph.add_edge(spec, target) if target
        end
      end
      graph.topological_order
    end

    def link_dependencies(specs, fields)
      id_by_name = fields.to_h { |f| [f.name, f.id] }
      updates = Hash.new { |h, k| h[k] = { id: k, depends_on_field_id: ROOT_ID, parent_id: ROOT_ID } }
      failed_specs = []

      SELF_REFERENCE_COLUMNS.each do |link, col|
        graph = DirectedGraph.new

        specs.each do |spec|
          next unless spec[link].present?
          child_id = id_by_name[spec[:name]]
          target_id = id_by_name[spec[link].to_s]

          unless child_id && target_id
            failed_specs << spec
            next
          end

          graph.add_edge(child_id, target_id)
          updates[child_id][col] = target_id
        end

        graph.break_cycles do |component|
          component.each do |child|
            target = updates[child][col]
            updates[child][col] = ROOT_ID if component.include?(target) && child <= target
          end
        end
      end

      return failed_specs if failed_specs.any?
      return [] if updates.empty?

      @form.fields.klass.upsert_all(updates.values.sort_by { |r| r[:id] })
      []
    end

    def deletion_names(version, inputs)
      fields = @form.cached_fields(version)
      seeds = fields.select { |f| inputs.include?(f.name) }.map(&:id)
      return [] if seeds.empty?

      children = Hash.new { |h, k| h[k] = [] }
      fields.each do |f|
        children[f.parent_id] << f.id unless f.parent_id == ROOT_ID
        children[f.depends_on_field_id] << f.id unless f.depends_on_field_id == ROOT_ID
      end

      reachable = Set.new(seeds)
      queue = seeds.dup
      until queue.empty?
        children[queue.shift].each { |c| queue << c if reachable.add?(c) }
      end

      fields.select { |f| reachable.include?(f.id) }.map(&:name)
    end

    def allocate_slots(specs, types, version)
      layout = @form.slot_layout
      occupied = Hash.new { |h, k| h[k] = Set.new }
      @form.active_fields.each { |f| occupied[f.field_type].add(f.slot) }

      specs.filter_map do |spec|
        type = types[spec.fetch(:field_type, CustomFields.configuration.default_type)]
        next unless type

        slot = type.slot_names.find { |s| !occupied[type.name].include?(s) && layout.backed?(s) }
        next unless slot

        occupied[type.name].add(slot)
        {
          form_id: @form.id, valid_from_version: version, valid_to_version: 0,
          name: spec[:name].presence || SecureRandom.hex, field_type: type.name,
          slot: slot, has_choices: !!spec[:choices], choice_match: (spec[:choice_match] || "id").to_s,
        }
      end
    end
  end
end
