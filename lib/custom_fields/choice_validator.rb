module CustomFields
  class ChoiceValidator
    ROOT = ChoiceEditor::ROOT_PARENT_ID

    def initialize(fields, choice_class, choices_cache: nil)
      @by_id = fields.index_by(&:id)
      
      @ordered_choice_fields = fields.select(&:has_choices)
      @choice_fields_by_name = @ordered_choice_fields.index_by(&:name)

      @choices = choices_cache || Hash.new do |cache, field_id|
        field = @by_id[field_id]
        list = choice_class.cached_choices(field_id)

        cache[field_id] = list.to_h do |choice|
          [[choice.parent_id.to_i, field.match_value(choice).to_s], choice]
        end
      end
    end

    def validate(submitted, carried)
      cleaned_carried, _ = resolve_all(carried, collect_errors: false)
      input = cleaned_carried.merge(submitted)
      resolve_all(input, collect_errors: true)
    end

    private

    def resolve_all(data, collect_errors:)
      resolved_data = {}
      resolved_choices = {}
      errors = {}

      data.each do |name, value|
        resolved_data[name] = value unless @choice_fields_by_name.key?(name)
      end

      @ordered_choice_fields.each do |field|
        next unless data.key?(field.name)

        raw_val = data[field.name]
        if raw_val.nil?
          resolved_data[field.name] = nil
          next
        end

        parent_choice_id = determine_parent_choice_id(field, resolved_choices, errors, collect_errors)
        unless parent_choice_id
          resolved_data[field.name] = nil
          next
        end

        choice = @choices[field.id][[parent_choice_id, raw_val.to_s]]

        if choice
          resolved_choices[field.id] = choice
          resolved_data[field.name] = field.match_value(choice)
        else
          resolved_data[field.name] = nil
          add_error(errors, field.name, "choice was not found", collect_errors)
        end
      end

      [resolved_data, errors]
    end

    def determine_parent_choice_id(field, resolved_choices, errors, collect_errors)
      depends_on_id = field.depends_on_field_id.to_i
      return ROOT if depends_on_id == ROOT

      parent_field = @by_id[depends_on_id]
      unless parent_field && parent_field.has_choices
        add_error(errors, field.name, "depends on field was not found", collect_errors)
        return
      end

      parent_choice = resolved_choices[parent_field.id]
      unless parent_choice
        add_error(errors, field.name, "parent choice was not found", collect_errors)
        return
      end

      parent_choice.id
    end

    def add_error(errors, field_name, message, collect_errors)
      return unless collect_errors
      errors[field_name] ||= ["E002", message]
    end
  end
end
