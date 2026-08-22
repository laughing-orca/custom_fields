require_relative "boot"

ActiveRecord::Schema.verbose = false

ActiveRecord::Schema.define do
  create_table :forms, force: true do |t|
    t.string :name
    t.integer :latest_version
    t.timestamps
  end

  create_table :form_fields, force: true do |t|
    t.bigint :form_id
    t.string :name
    t.string :field_type
    t.string :slot
    t.integer :valid_from_version
    t.integer :valid_to_version, null: false, default: 0   # 0 = currently active; else the version it retired at; [valid_from, valid_to) interval
    t.bigint :parent_id, null: false, default: 0
    t.bigint :depends_on_field_id, null: false, default: 0
    t.boolean :has_choices, null: false, default: false   # true = dropdown; its choices reference this field's (stable) id
    t.string :choice_match                    # "value" or "id"; blank uses the configured default
    t.timestamps
    # Active fields share valid_to_version = 0, so this keeps one field per slot/name
    # among them; retired rows on a reused slot/name always carry distinct retire versions.
    t.index [:form_id, :valid_to_version, :slot], unique: true
    t.index [:form_id, :valid_to_version, :name], unique: true
  end

  create_table :form_sequences, force: true do |t|
    t.bigint :form_id
    t.bigint :value, null: false, default: 0
    t.index :form_id, unique: true   # required for the INSERT ... ON DUPLICATE KEY bump
  end

  # Current / live revision: exactly one row per lineage (instance_version_id).
  create_table :form_instances, force: true do |t|
    t.bigint :form_id
    t.string :instance_version_id
    t.bigint :sequence_number
    t.integer :instance_version
    t.integer :form_version
    t.timestamps
    t.index :instance_version_id, unique: true
    t.index [:form_id, :form_version]
  end

  # History: the superseded revisions of an instance, one row per past version.
  create_table :form_previous_instances, force: true do |t|
    t.bigint :form_id
    t.string :instance_version_id
    t.bigint :sequence_number
    t.integer :instance_version
    t.integer :form_version
    t.timestamps
    t.index [:instance_version_id, :instance_version], unique: true
    t.index [:form_id, :form_version]
  end

  create_table :form_data_1, force: true do |t|
    t.bigint :instance_id
    t.string :text01
    t.string :text02
    t.string :text03
    t.string :text04
    t.string :text05
    t.integer :integer01
    t.integer :integer02
    t.integer :integer03
    t.string :section01
    t.string :section02
    t.timestamps
    t.index :instance_id, unique: true
    # Index any slot column you filter on (see README "Indexing filtered slots").
    t.index :text01
    t.index :text02
    t.index :integer01
  end

  create_table :form_data_2, force: true do |t|
    t.bigint :instance_id
    t.string :text06
    t.string :text07
    t.string :text08
    t.string :text09
    t.string :text10
    t.integer :integer04
    t.integer :integer05
    t.integer :integer06
    t.timestamps
    t.index :instance_id, unique: true
  end

  # Previous-revision data stores mirror the live stores' slot columns exactly.
  create_table :form_previous_data_1, force: true do |t|
    t.bigint :instance_id
    t.string :text01
    t.string :text02
    t.string :text03
    t.string :text04
    t.string :text05
    t.integer :integer01
    t.integer :integer02
    t.integer :integer03
    t.string :section01
    t.string :section02
    t.timestamps
    t.index :instance_id, unique: true
  end

  create_table :form_previous_data_2, force: true do |t|
    t.bigint :instance_id
    t.string :text06
    t.string :text07
    t.string :text08
    t.string :text09
    t.string :text10
    t.integer :integer04
    t.integer :integer05
    t.integer :integer06
    t.timestamps
    t.index :instance_id, unique: true
  end

  create_table :form_audits, force: true do |t|
    t.bigint  :form_id, null: false
    t.string  :entity_type, null: false      # "field" | "choice" | "instance"
    t.bigint  :entity_id, null: false        # instance.id / dropdown field.id (choices) / 0 (form-level field ops)
    t.string  :action, null: false           # "create" | "update" | "delete" | "add" | "rename" | "set"
    t.integer :form_version                   # schema version in effect at the change
    t.integer :instance_version               # revision produced (instances only)
    t.json    :patch, null: false             # JSON-Patch op list: [{ op, path, value?, from? }]
    t.string  :actor                          # who made the change; nil = system-attributed
    t.datetime :created_at, null: false
    t.index [:form_id, :entity_type, :entity_id]
    t.index [:form_id, :created_at]
  end

  create_table :choices, force: true do |t|
    t.bigint :field_id                        # the dropdown field these choices belong to (field ids are stable across versions)
    t.string :value
    t.bigint :parent_id, null: false, default: 0
    t.boolean :active
    t.timestamps
    t.index [:field_id, :parent_id, :value], unique: true
    t.index :parent_id
  end
end
