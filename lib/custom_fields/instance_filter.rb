module CustomFields
  class InstanceFilter
    def initialize(form)
      @form = form
      @layout = @form.slot_layout
    end

    def filter_instances(**filters)
      fields = @form.cached_fields(@form.latest_version)
      fields_by_name = fields.index_by(&:name)
      relation = @form.instances
      min_version = 1
      by_store = Hash.new { |h, store| h[store] = [] }

      filters.each do |name, value|
        field = fields_by_name[name.to_s]
        next unless field

        store = @layout.store_for(field.slot) or next
        by_store[store] << [field, value]
        min_version = [min_version, field.valid_from_version].max unless value.nil?
      end

      by_store.each { |store, predicates| relation = join_store(relation, store, predicates) }
      relation = relation.where(form_version: min_version..)

      FilterResult.new(@form, relation, layout: @layout, fields: fields)
    end

    private

    def join_store(relation, store, predicates)
      base = @form.instances.klass.arel_table
      data = store.arel_table

      join = base.join(data, Arel::Nodes::OuterJoin).on(data[:instance_id].eq(base[:id])).join_sources
      relation = relation.joins(join)

      predicates.each do |field, value|
        slot = data[field.slot]
        relation = if value.nil?
            relation.where(slot.eq(nil).or(base[:form_version].lt(field.valid_from_version)))
          else
            relation.where(slot.eq(value))
          end
      end

      relation
    end
  end
end
