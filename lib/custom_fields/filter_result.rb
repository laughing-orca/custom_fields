module CustomFields
  class FilterResult
    include Enumerable

    def initialize(form, relation, layout: nil, fields: nil)
      @form = form
      @relation = relation
      @layout = layout || @form.slot_layout
      @fields = fields || @form.cached_fields(@form.latest_version)
    end

    def instances
      @instances ||= @relation.to_a
    end

    def each(&block)
      instances.each(&block)
    end

    def count
      @instances ? @instances.size : @relation.count
    end

    def pluck(*columns)
      @relation.pluck(*columns)
    end

    def values(as: :field)
      key = as == :slot ? :slot : :name

      instances.map do |instance|
        slots = slots_by_instance[instance.id]
        @fields.to_h do |field|
          [field.public_send(key), instance.projected_value(@form.latest_version, slots, field)]
        end
      end
    end

    private

    def slots_by_instance
      @slots_by_instance ||= @layout.read_many(instances.map(&:id), slots: @fields.map(&:slot))
    end
  end
end
