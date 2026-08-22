module CustomFields
  class PruneFormVersionsJob
    include Sidekiq::Job

    def perform(form_class, id, self_enqueues = 0)
      return if self_enqueues >= CustomFields.configuration.max_self_enqueues

      form = form_class.constantize.find_by(id: id)
      return unless form

      FieldVersionPruner.new(form, self_enqueues: self_enqueues).call
    end
  end
end
