module CustomFields
  class InstanceEditor
    include Retryable

    def initialize(form)
      @form = form
      @layout = @form.slot_layout
      @previous_layout = @form.previous_slot_layout
      @instance_class = @form.instances.klass
      @previous_instance_class = @form.previous_instances.klass
      @choice_class = @form.class.choice_class_name.constantize
      @sequence_class = @form.class.sequence_class
      @audit = AuditLog.new(@form)
    end

    def create_instance(values: {}, max_retries: 3)
      with_retries(max_retries) do
        insert_at_current_version(values)
      end
    end

    def update_instance(instance, values: {}, max_retries: 3)
      response = with_retries(max_retries) do
        @instance_class.transaction do
          current = @instance_class.find_by(id: instance.id)
          next Response.failure("E002", reason: "instance not found") unless current

          version = fetch_latest_version(current.form_id)
          next Response.failure("E002", reason: "form missing") unless version

          fields = @form.cached_fields(version)
          raw = @layout.read(current)
          slots, error = validated_slots(fields, values, raw)
          next error if error

          res = supersede(current, slots, raw, version, fields)
          Response.success(res)
        end
      end

      return response if response.failed? || response.result.nil?

      response.result.prune_revisions
      response
    end

    private

    def fetch_latest_version(form_id)
      @form.class.where(id: form_id).pick(:latest_version)
    end

    def choice_label(field, token)
      return unless token && field.has_choices && field.match_type == :id
      choice = @choice_class.cached_choices_by_id(field.id)[token.to_s]
      choice && choice.value
    end

    def validated_slots(fields, values, carried_slots)
      submitted = values.stringify_keys
      carried = fields.to_h { |f| [f.name, carried_slots[f.slot]] }

      validator = ChoiceValidator.new(fields, @choice_class)
      resolved, errors = validator.validate(submitted, carried)

      if errors.present?
        reason = errors.map { |pair| pair.join(": ") }.join(", ")
        return [nil, Response.failure("E001", fields: errors.keys, reason: reason)]
      end

      slots = fields.filter_map { |f| [f.slot, resolved[f.name]] if resolved.key?(f.name) }.to_h
      [slots, nil]
    end

    def insert_at_current_version(values)
      version = fetch_latest_version(@form.id)
      return Response.failure("E002", reason: "form missing") unless version

      fields = @form.cached_fields(version)
      slots, error = validated_slots(fields, values, {})
      return error if error

      sequence_number = @sequence_class.next_number(@form.id)

      @form.transaction do
        inst = @form.instances.create!(
          instance_version_id: SecureRandom.hex,
          sequence_number: sequence_number,
          form_version: version,
          instance_version: 1,
        )
        @layout.write(inst, slots)
        change = Changes::Instance.diff(fields, {}, slots, version) { |field, token| choice_label(field, token) }
        @audit.record("instance", inst.id, "create", change,
          form_version: inst.form_version, instance_version: inst.instance_version)
        Response.success(inst)
      end
    end

    def supersede(current, new_slots, old_slots, version, fields)
      old_version = current.instance_version
      old_form_version = current.form_version

      claimed = @instance_class
        .where(id: current.id, instance_version: old_version)
        .update_all(form_version: version, instance_version: old_version + 1)
      raise ActiveRecord::SerializationFailure if claimed == 0

      current.assign_attributes(form_version: version, instance_version: old_version + 1)
      @layout.write(current, new_slots, prune_empty: true)
      change = Changes::Instance.diff(fields, old_slots, new_slots, old_form_version) { |field, token| choice_label(field, token) }
      @audit.record("instance", current.id, "update", change,
        form_version: current.form_version, instance_version: current.instance_version)

      return current if CustomFields.configuration.max_instance_revisions == 1

      prev_inst = @previous_instance_class.create!(
        form_id: current.form_id,
        instance_version_id: current.instance_version_id,
        sequence_number: current.sequence_number,
        form_version: old_form_version,
        instance_version: old_version,
      )
      @previous_layout.write(prev_inst, old_slots)
      current
    end
  end
end
