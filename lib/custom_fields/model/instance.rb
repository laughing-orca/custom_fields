module CustomFields
  module Model
    module Instance
      extend ActiveSupport::Concern

      class_methods do
        def custom_fields_instance(form:)
          belongs_to :form, class_name: form.to_s
        end
      end

      def versions
        history = form.previous_instances.where(instance_version_id: instance_version_id)
        current = form.instances.where(instance_version_id: instance_version_id)
        (history.to_a + current.to_a).sort_by(&:instance_version)
      end

      def field_values(form_version, fields, slot_layout: nil)
        slot_layout ||= (form_version >= form.latest_version) ? layout : previous_layout
        slots = slot_layout.read(self, slots: fields.map(&:slot))
        fields.to_h { |field| [field.name, projected_value(form_version, slots, field)] }
      end

      def slot_values(form_version, fields, slot_layout: nil)
        slot_layout ||= (form_version >= form.latest_version) ? layout : previous_layout
        slots = slot_layout.read(self, slots: fields.map(&:slot))
        fields.to_h { |field| [field.slot, projected_value(form_version, slots, field)] }
      end

      def layout
        @layout ||= form.slot_layout
      end

      def previous_layout
        @previous_layout ||= form.previous_slot_layout
      end

      def projected_value(version, slots, field)
        field.valid_at?(version) && slots[field.slot]
      end

      def choice_class
        @choice_class ||= form.class.choice_class_name.constantize
      end

      def prune_revisions(keep_count: CustomFields.configuration.max_instance_revisions)
        self.class.transaction do
          cutoff = instance_version - keep_count
          return unless cutoff.positive?

          oldest = form.previous_instances.where(instance_version_id: instance_version_id).minimum(:instance_version)
          return unless oldest && (cutoff - oldest + 1) >= CustomFields.configuration.prune_version_buffer

          ids = form
            .previous_instances
            .where(instance_version_id: instance_version_id)
            .where("instance_version <= ?", cutoff)
            .order(:id)
            .pluck(:id)
          return unless ids.any?

          form.previous_slot_layout.delete_with_data(ids)
        end
      rescue => e
        Response.build_error("E003")
      end
    end
  end
end
