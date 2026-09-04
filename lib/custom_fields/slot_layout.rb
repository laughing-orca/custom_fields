module CustomFields
  class SlotLayout
    def initialize(stores:, instance_class:, field_type_names:)
      @stores = stores
      @instance_class = instance_class
      @field_type_names = field_type_names
    end

    attr_reader :stores

    def store_for(slot)
      store_by_slot[slot.to_s]
    end

    def backed?(slot)
      store_by_slot.key?(slot.to_s)
    end

    def stores_for(slots)
      slots.map { |slot| store_by_slot[slot.to_s] }.compact.uniq.sort_by(&:name)
    end

    def read(instance, slots: nil)
      values = {}
      stores_to_scan(slots).each do |store|
        row = store.find_by(instance_id: instance.id)
        next if row.nil?

        slots_by_store.fetch(store).each { |slot| values[slot] = row[slot] }
      end
      values
    end

    def read_many(instance_ids, slots: nil)
      slots_by_instance = Hash.new { |h, id| h[id] = {} }

      stores_to_scan(slots).each do |store|
        store.where(instance_id: instance_ids).each do |row|
          values = slots_by_instance[row.instance_id]
          slots_by_store.fetch(store).each { |slot| values[slot] = row[slot] }
        end
      end
      slots_by_instance
    end

    def write(instance, slots, prune_empty: false)
      write_many({ instance.id => slots }, prune_empty: prune_empty)
    end

    def write_many(slots_by_instance_id, prune_empty: false)
      return if slots_by_instance_id.empty?

      sorted_instance_ids = slots_by_instance_id.keys.compact.sort

      @stores.each do |store|
        store_slots = slots_by_store.fetch(store)
        rows = []
        empty_ids = []

        sorted_instance_ids.each do |instance_id|
          slots = slots_by_instance_id[instance_id] || {}
          if store_slots.all? { |slot| slots[slot.to_s].nil? }
            empty_ids << instance_id
            next
          end

          row = { "instance_id" => instance_id }
          store_slots.each { |slot| row[slot] = slots[slot.to_s] }
          rows << row
        end

        if prune_empty && empty_ids.any?
          row_ids = store.where(instance_id: empty_ids.sort).order(:id).pluck(:id)
          store.where(id: row_ids).delete_all if row_ids.any?
        end

        if rows.any?
          rows.sort_by! { |r| r["instance_id"] }
          store.upsert_all(rows)
        end
      end
    end

    def delete_with_data(instance_ids)
      ids = instance_ids.to_a.uniq.sort
      return 0 if ids.empty?

      @stores.each do |store|
        row_ids = store.where(instance_id: ids).order(:id).pluck(:id)
        store.where(id: row_ids).delete_all if row_ids.any?
      end
      @instance_class.where(id: ids).delete_all
    end

    def slot_columns
      slots_by_store.transform_keys(&:table_name)
    end

    private

    def stores_to_scan(slots)
      slots ? stores_for(slots) : @stores
    end

    def slots_by_store
      @slots_by_store ||= @stores.to_h { |store| [store, store.column_names.select { |column| slot?(column) }] }
    end

    def store_by_slot
      @store_by_slot ||= slots_by_store.each_with_object({}) do |(store, slots), map|
        slots.each { |slot| map[slot] = store }
      end
    end

    def slot?(column)
      @field_type_names.each do |name|
        rest = column[name.length..]
        return true if column.start_with?(name) && rest.present? && rest.match?(/\A\d+\z/)
      end
      false
    end
  end
end
