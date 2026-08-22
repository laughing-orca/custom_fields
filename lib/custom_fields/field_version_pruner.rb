module CustomFields
  class FieldVersionPruner
    def initialize(form, self_enqueues: 0)
      @form = form
      @self_enqueues = self_enqueues
      @cutoff = @form.min_retained_form_version
      @layout = @form.slot_layout
      @previous_layout = @form.previous_slot_layout
    end

    def call
      return 0 unless @form.prune_due?
      return 0 unless rewrite_stale_instances

      delete_superseded_instances
      finalize
    end

    private

    def instance_class
      @form.instances.klass
    end

    def stale_versions
      @stale_versions ||= begin
          oldest = [
            @form.fields.minimum(:valid_from_version),
            @form.instances.minimum(:form_version),
            @form.previous_instances.minimum(:form_version),
          ].compact.min
          oldest ? (oldest...@cutoff).to_a : []
        end
    end

    def rewrite_stale_instances
      target_fields = @form.cached_fields(@cutoff)

      stale_versions.each do |version|
        loop do
          return false if cutoff_advanced?

          ids = next_stale_batch(version)
          break if ids.empty?

          rewrite_batch(ids, version, target_fields)
        end
      end

      true
    end

    def cutoff_advanced?
      @form.reload.min_retained_form_version > @cutoff
    end

    def next_stale_batch(version)
      @form.instances.where(form_version: version).order(:id).limit(CustomFields.configuration.batch_size).pluck(:id)
    end

    def rewrite_batch(ids, version, target_fields)
      @form.transaction(isolation: :read_committed) do
        stale = instance_class.lock("FOR UPDATE SKIP LOCKED").where(id: ids).order(:id).to_a
        next if stale.empty?

        stale_ids = stale.map(&:id)
        read = @layout.read_many(stale_ids, slots: target_fields.map(&:slot))
        projected = stale.to_h do |inst|
          [inst.id, target_fields.to_h { |f| [f.slot, inst.projected_value(version, read[inst.id], f)] }]
        end

        instance_class.where(id: stale_ids).update_all(form_version: @cutoff)
        @layout.write_many(projected, prune_empty: true)
      end
    end

    def delete_superseded_instances
      stale_versions.each do |version|
        @form
          .previous_instances
          .where(form_version: version)
          .in_batches(of: CustomFields.configuration.batch_size) { |batch| @previous_layout.delete_with_data(batch.pluck(:id)) }
      end
    end

    def finalize
      @form.with_lock do
        if live_stale_instances_remain?
          reschedule
          return 0
        end

        prune_field_definitions
      end
    end

    def live_stale_instances_remain?
      @form.instances.where("form_version < ?", @cutoff).exists?
    end

    def reschedule
      PruneFormVersionsJob.perform_async(@form.class.name, @form.id, @self_enqueues + 1)
    end

    def prune_field_definitions
      prunable = @form.fields.where.not(valid_to_version: 0).where("valid_to_version <= ?", @cutoff)
      dropdown_field_ids = prunable.where(has_choices: true).pluck(:id)
      deleted_count = prunable.delete_all

      @form.fields.where("valid_from_version < ?", @cutoff).update_all(valid_from_version: @cutoff)

      prune_choices(dropdown_field_ids)
      @form.touch
      deleted_count
    end

    def prune_choices(field_ids)
      return if field_ids.empty?

      choice_class = @form.class.choice_class_name.constantize
      field_ids.each_slice(CustomFields.configuration.batch_size) do |batch|
        choice_class.where(field_id: batch).in_batches(of: CustomFields.configuration.batch_size).delete_all
        choice_class.expire_choices_cache(batch)
      end
    end
  end
end
