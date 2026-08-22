module CustomFields
  module Model
    module Choice
      extend ActiveSupport::Concern

      Cached = Data.define(:id, :parent_id, :value)

      class_methods do
        def custom_fields_choice
          has_many :choices, class_name: self.name, foreign_key: :parent_id
        end

        def cached_choices(field_id)
          cached_choices_by_id(field_id).values
        end

        def cached_choices_by_id(field_id)
          Rails.cache.fetch(choices_cache_key(field_id)) do
            where(field_id: field_id, active: true).to_h { |choice| [choice.id.to_s, choice.to_cached] }
          end
        end

        def expire_choices_cache(field_ids)
          Array(field_ids).uniq.each { |id| Rails.cache.delete(choices_cache_key(id)) }
        end

        def choices_cache_key(field_id)
          [name, "choices", field_id]
        end
      end

      def to_cached
        Cached.new(id: id, parent_id: parent_id, value: value)
      end
    end
  end
end
