module CustomFields
  module Model
    module Field
      extend ActiveSupport::Concern

      module FieldMethods
        def valid_at?(version)
          valid_from_version <= version && (valid_to_version.zero? || valid_to_version > version)
        end

        def match_type
          (choice_match.to_s == "id" || choice_match.blank?) ? :id : :value
        end

        def match_value(choice)
          match_type == :id ? choice.id : choice.value
        end
      end

      Cached = Data.define(:id, :name, :field_type, :slot, :valid_from_version, :valid_to_version, :parent_id, :depends_on_field_id, :has_choices, :choice_match) do
        include FieldMethods
      end

      included do
        include FieldMethods
      end

      class_methods do
        def custom_fields_field(form:)
          belongs_to :form, class_name: form.to_s, inverse_of: :fields
          has_many :fields, class_name: self.name, foreign_key: :parent_id
        end
      end

      def to_cached
        Cached.new(id: id, name: name, field_type: field_type, slot: slot, valid_from_version: valid_from_version,
                   valid_to_version: valid_to_version, parent_id: parent_id, depends_on_field_id: depends_on_field_id,
                   has_choices: has_choices, choice_match: choice_match)
      end
    end
  end
end
