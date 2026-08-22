module CustomFields
  module Model
    module Audit
      extend ActiveSupport::Concern

      class_methods do
        def custom_fields_audit(form:)
          belongs_to :form, class_name: form.to_s, optional: true
        end
      end
    end
  end
end
