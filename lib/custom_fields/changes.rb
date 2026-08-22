module CustomFields
  module Changes
    Instance = Data.define(:ops) do
      def self.diff(fields, before_slots, after_slots, before_version, &resolve)
        ops = fields.filter_map do |field|
          before = before_slots[field.slot] if field.valid_at?(before_version)
          after = after_slots[field.slot]
          next if before == after

          op = change_op(field.name, before, after)
          if resolve
            from_label = resolve.call(field, before) if op.key?("from")
            value_label = resolve.call(field, after) if op.key?("value")
            op["from_label"] = from_label if from_label
            op["value_label"] = value_label if value_label
          end
          op
        end

        new(ops: ops)
      end

      def self.change_op(name, before, after)
        path = ["instance_values", name]
        if before.nil?
          { "op" => "add", "path" => path, "value" => after }
        elsif after.nil?
          { "op" => "remove", "path" => path, "from" => before }
        else
          { "op" => "replace", "path" => path, "from" => before, "value" => after }
        end
      end

      def empty? = ops.empty?
      def payload = ops
    end

    Field = Data.define(:ops) do
      def self.created(names) = new(ops: names.map { |name| { "op" => "add", "path" => ["fields", name] } })
      def self.removed(names) = new(ops: names.map { |name| { "op" => "remove", "path" => ["fields", name] } })

      def empty? = ops.empty?
      def payload = ops
    end

    Choice = Data.define(:ops) do
      def self.add(field_name, values)
        new(ops: values.map { |value| { "op" => "add", "path" => [field_name, value] } })
      end

      def self.remove(field_name, values)
        new(ops: values.map { |value| { "op" => "remove", "path" => [field_name, value] } })
      end

      def self.rename(field_name, from, to)
        new(ops: [{ "op" => "replace", "path" => [field_name, from], "value" => to }])
      end

      def empty? = ops.empty?
      def payload = ops.map { |op| op.merge("path" => ["choices", *op["path"]]) }
    end

    class ChoicePatch
      def initialize
        @ops = []
      end

      def add(path)
        @ops << { "op" => "add", "path" => path }
      end

      def remove(path)
        @ops << { "op" => "remove", "path" => path }
      end

      def to_change
        Choice.new(ops: @ops)
      end
    end
  end
end
