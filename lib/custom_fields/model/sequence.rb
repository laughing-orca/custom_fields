module CustomFields
  module Model
    module Sequence
      extend ActiveSupport::Concern

      class_methods do
        def custom_fields_sequence(form:)
          belongs_to :form, class_name: form.to_s
        end

        def next_number(form_id)
          connection.execute(sanitize_sql_array(["UPDATE #{table_name} SET value = LAST_INSERT_ID(value + 1) WHERE form_id = ?", form_id]))
          connection.select_value("SELECT LAST_INSERT_ID()").to_i
        end
      end
    end
  end
end
