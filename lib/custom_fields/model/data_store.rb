module CustomFields
  module Model
    module DataStore
      extend ActiveSupport::Concern

      class_methods do
        def custom_fields_data_store(instance:)
          belongs_to :instance, class_name: instance.to_s
        end
      end
    end
  end
end
