module CustomFields
  class AuditLog
    def initialize(form)
      @form = form
      @audit_class = form.class.audit_class
    end

    def record(entity_type, entity_id, action, change, form_version:, instance_version: nil)
      return if change.empty?

      @audit_class.insert_all([{
        form_id: @form.id,
        entity_type: entity_type,
        entity_id: entity_id,
        action: action,
        form_version: form_version,
        instance_version: instance_version,
        patch: change.payload,
        created_at: Time.current,
      }])
    end
  end
end
