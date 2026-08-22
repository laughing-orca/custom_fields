module CustomFields
  class ChoiceValidator
    ROOT = ChoiceEditor::ROOT_PARENT_ID

    def initialize(fields, choice_class)
      @by_id = fields.index_by(&:id)
      @choice_fields_by_name = @by_id.values.select(&:has_choices).to_h { |f| [f.name, f] }

      @choices = Hash.new do |cache, field_id|
        list = choice_class.cached_choices(field_id)
        cache[field_id] = {
          by_value: list.to_h { |choice| [[choice.parent_id.to_i, choice.value.to_s], choice] },
          by_id: list.to_h { |choice| [[choice.parent_id.to_i, choice.id], choice] },
        }
      end
    end

    def validate(submitted, carried)
      @submitted = submitted
      @carried = carried
      @choice_memo = {}
      @errors = {}
      resolved = {}

      @submitted.each do |name, value|
        resolved[name] = value unless @choice_fields_by_name.key?(name)
      end

      @choice_fields_by_name.each do |name, field|
        next unless @submitted.key?(name) || @carried.key?(name)

        choice = resolve(field)
        resolved[name] = choice ? field.match_value(choice) : nil
      end

      [@carried.merge(resolved), @errors]
    end

    private

    def resolve(field)
      return @choice_memo[field.name] if @choice_memo.key?(field.name)

      @choice_memo[field.name] = nil
      return if effective_nil?(field.name)

      parent_choice_id = parent_choice_id(field)
      return if parent_choice_id.nil?

      @choice_memo[field.name] = find_choice(field, parent_choice_id)
    end

    def parent_choice_id(field)
      depends_on_field_id = field.depends_on_field_id.to_i
      return ROOT if depends_on_field_id == ROOT

      parent_field = @by_id[depends_on_field_id]
      unless parent_field&.has_choices
        error_if_submitted(field, "depends on field was not found")
        return
      end

      parent_choice = resolve(parent_field)
      unless parent_choice
        error_if_submitted(field, "parent choice was not found")
        return
      end

      parent_choice.id
    end

    def find_choice(field, parent_choice_id)
      key, value =
        if @submitted.key?(field.name)
          [:by_value, @submitted[field.name].to_s]
        elsif field.match_type == :id
          [:by_id, @carried[field.name].to_i]
        else
          [:by_value, @carried[field.name].to_s]
        end

      choice = @choices[field.id][key][[parent_choice_id, value]]
      error_if_submitted(field, "choice was not found") unless choice
      choice
    end

    def error_if_submitted(field, message)
      add_error(field.name, "E002", message) if submitted_value?(field.name)
    end

    def submitted_value?(field_name)
      @submitted.key?(field_name) && !@submitted[field_name].nil?
    end

    def effective_nil?(field_name)
      if @submitted.key?(field_name)
        @submitted[field_name].nil?
      else
        @carried[field_name].nil?
      end
    end

    def add_error(field_name, code, message)
      @errors[field_name] ||= [code, message]
    end
  end
end
