module CustomFields
  module Model
    module Form
      extend ActiveSupport::Concern

      CachedType = Data.define(:name, :max_slots) do
        def slot_names
          (1..max_slots).map { |i| format("%s%02d", name, i) }
        end
      end

      class_methods do
        attr_reader :choice_class_name, :sequence_class_name, :audit_class_name, :data_store_class_names, :previous_data_store_class_names, :max_slots_by_type

        def custom_fields_form(field:, instance:, previous_instance:, data_stores:, previous_data_stores:, choice:, sequence:, audit:, max_slots_by_type:)
          has_many :fields, class_name: field.to_s, foreign_key: :form_id, inverse_of: :form
          has_many :instances, class_name: instance.to_s, foreign_key: :form_id, inverse_of: :form
          has_many :previous_instances, class_name: previous_instance.to_s, foreign_key: :form_id, inverse_of: :form
          has_many :audits, class_name: audit.to_s, foreign_key: :form_id, inverse_of: :form

          @data_store_class_names = Array(data_stores).map(&:to_s)
          @previous_data_store_class_names = Array(previous_data_stores).map(&:to_s)
          @choice_class_name = choice.to_s
          @sequence_class_name = sequence.to_s
          @audit_class_name = audit.to_s
          @max_slots_by_type = max_slots_by_type
        end

        def audit_class
          @audit_class ||= audit_class_name.constantize
        end

        def data_store_classes
          @data_store_classes ||= data_store_class_names.map(&:constantize)
        end

        def previous_data_store_classes
          @previous_data_store_classes ||= previous_data_store_class_names.map(&:constantize)
        end

        def sequence_class
          @sequence_class ||= sequence_class_name.constantize
        end

        def create_form(**attributes)
          transaction do
            form = create!(attributes)
            connection.execute(
              sanitize_sql_array(["INSERT INTO #{sequence_class.table_name} (form_id, value) VALUES (?, 0)", form.id]),
            )
            form
          end
        end
      end

      def slot_layout
        SlotLayout.new(
          stores: self.class.data_store_classes.sort_by(&:name),
          instance_class: self.instances.klass,
          field_type_names: cached_field_types.map(&:name).sort,
        )
      end

      def previous_slot_layout
        SlotLayout.new(
          stores: self.class.previous_data_store_classes.sort_by(&:name),
          instance_class: self.previous_instances.klass,
          field_type_names: cached_field_types.map(&:name).sort,
        )
      end

      def cached_field_types
        Rails.cache.fetch([cache_key_with_version, "field_types"]) do
          self.class.max_slots_by_type.map do |type, count|
            CachedType.new(name: type.to_s, max_slots: count)
          end
        end
      end

      def fields_at(version)
        fields
          .where("valid_from_version <= ?", version)
          .where("valid_to_version = 0 OR valid_to_version > ?", version)
      end

      def active_fields
        fields.where(valid_to_version: 0)
      end

      def cached_fields(version)
        Rails.cache.fetch([cache_key_with_version, "fields", version]) do
          cached_list = fields_at(version).map(&:to_cached)
          order_fields_parent_first(cached_list)
        end
      end

      def order_fields_parent_first(fields)
        root_id = ChoiceEditor::ROOT_PARENT_ID
        children_by_parent = Hash.new { |h, k| h[k] = [] }

        fields.each do |f|
          parent_id = f.respond_to?(:depends_on_field_id) ? f.depends_on_field_id.to_i : root_id
          children_by_parent[parent_id] << f
        end

        ordered = []
        visited = Set.new

        traverse = lambda do |parent_id|
          children_by_parent[parent_id].each do |field|
            next if visited.include?(field.id)

            visited.add(field.id)
            ordered << field
            traverse.call(field.id)
          end
        end

        traverse.call(root_id)
        ordered + fields.reject { |f| visited.include?(f.id) }
      end

      def min_retained_form_version
        [1, latest_version - (CustomFields.configuration.max_form_versions - 1)].max
      end

      def prune_due?
        cutoff = min_retained_form_version
        return false if cutoff <= 1

        oldest_dead = fields.where.not(valid_to_version: 0).minimum(:valid_to_version)
        oldest_dead.present? && (cutoff - oldest_dead) >= CustomFields.configuration.prune_version_buffer
      end
    end
  end
end
