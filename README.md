# Custom Fields

Add typed, versioned fields (with dropdowns) to a model without touching its own table.

## How it works

- Each field has a **type** (`text`, `integer`, …) and takes one **slot** — a fixed column `<type><NN>` (e.g. `text01`).
- Slots live in **data store** tables; add more tables for more slots. `max_slots_by_type` sets how many slots each type gets.
- An **instance** is one record. Its metadata lives in the instance table; its values live in the data stores, one row per store, joined by `instance_id`.
- **Live vs history:** `form_instances` holds one live row per instance; superseded revisions go to `form_previous_instances` (+ its own data stores). An update edits the live row in place and snapshots the old values into history.
- **Versioned schema:** fields carry an interval `[valid_from_version, valid_to_version)` (`0` = active). Adding a field keeps the version; deleting bumps it. Nothing is copied forward; field ids are stable.
- **Instances pin** to the version they were written at, until **pruning** carries them forward past the retention limit.
- **Dropdowns:** a field with `choices: true`; allowed values are `choices` rows. `depends_on:` makes a dependent dropdown (parent choice via `parent_id`).
- **`choice_match`:** `:id` (default) stores the choice id, `:value` stores the value. You always submit the value; reads return the stored token.
- **`sequence_number`:** each instance gets a per-form `1,2,3,…`, generated in SQL via a one-row-per-form counter (`form_sequences`), seeded when the form is created.

## Setup

```ruby
class Form < ActiveRecord::Base
  include CustomFields::Model::Form
  custom_fields_form field: "Form::Field",
                     instance: "Form::Instance", previous_instance: "Form::PreviousInstance",
                     data_stores: ["Form::Data1"], previous_data_stores: ["Form::PreviousData1"],
                     choice: "Form::Choice", sequence: "Form::Sequence",
                     audit: "Form::Audit",
                     max_slots_by_type: { text: 3, integer: 2 }
end

class Form::Field            < ActiveRecord::Base; include CustomFields::Model::Field;    custom_fields_field    form: "Form"; end
class Form::Instance         < ActiveRecord::Base; include CustomFields::Model::Instance; custom_fields_instance form: "Form"; end
class Form::PreviousInstance < ActiveRecord::Base; include CustomFields::Model::Instance; custom_fields_instance form: "Form"; end
class Form::Data1            < ActiveRecord::Base; include CustomFields::Model::DataStore; custom_fields_data_store instance: "Form::Instance"; end
class Form::PreviousData1    < ActiveRecord::Base; include CustomFields::Model::DataStore; custom_fields_data_store instance: "Form::PreviousInstance"; end
class Form::Choice           < ActiveRecord::Base; include CustomFields::Model::Choice;    custom_fields_choice; end
class Form::Sequence         < ActiveRecord::Base; include CustomFields::Model::Sequence;  custom_fields_sequence form: "Form"; end
class Form::Audit            < ActiveRecord::Base; include CustomFields::Model::Audit;     custom_fields_audit    form: "Form"; end
```

- Set `self.table_name` when it doesn't match the class name.
- Previous data stores must have the **same slot columns** as the live stores.

## Schema

Fixed column names. Key tables and indexes:

- `forms` — `latest_version`.
- `form_fields` — `name, field_type, slot, valid_from_version, valid_to_version, parent_id, depends_on_field_id, has_choices, choice_match`; unique on `[form_id, valid_to_version, slot]` and `[form_id, valid_to_version, name]`.
- `form_sequences` — `form_id, value`; unique on `form_id`.
- `form_instances` — `form_id, instance_version_id, sequence_number, instance_version, form_version`; unique on `instance_version_id`.
- `form_previous_instances` — same columns; unique on `[instance_version_id, instance_version]`.
- `form_data_*` / `form_previous_data_*` — `instance_id` + slot columns (`text01`, `integer01`, …); unique on `instance_id`. Index any slot you filter on.
- `choices` — `field_id, value, parent_id, active`; unique on `[field_id, parent_id, value]`, index on `parent_id`.
- `form_audits` — `entity_type, entity_id, action, form_version, instance_version, patch (json), actor, created_at`; indexes on `[form_id, entity_type, entity_id]` and `[form_id, created_at]`.

See `demo/schema.rb` for the full DDL.

## Usage

```ruby
form = Form.create_form(name: "orders", latest_version: 1)   # creates the sequence row too

CustomFields::FieldEditor.new(form).create_fields([
  { name: "color",   field_type: "text" },
  { name: "country", field_type: "text", choices: true },                        # dropdown (stores id)
  { name: "state",   field_type: "text", choices: true, depends_on: "country" }, # dependent dropdown
])
CustomFields::FieldEditor.new(form).delete_fields(["color"])

choices = CustomFields::ChoiceEditor.new(form)
choices.set_dependent_choices([country, state], [{ value: "USA", children: [{ value: "California" }] }])
choices.add_choices(state, ["Texas"], parent: "USA")
choices.rename_choice(country, "USA", "US")
choices.delete_choices(country, ["US"])

inst = CustomFields::InstanceEditor.new(form).create_instance(values: { "color" => "black" }).result
CustomFields::InstanceEditor.new(form).update_instance(inst, values: { "color" => "silver" })
CustomFields::InstanceFilter.new(form).filter_instances(color: "silver")

CustomFields::FieldVersionPruner.new(form).call   # trim old versions/revisions
```

- Submit dropdowns as the **value**; invalid values are rejected. Unsubmitted fields carry forward; a dependent child that goes invalid under a changed parent is cleared.
- `field_values(form_version, fields)` / `slot_values(...)` read back stored tokens.

## Change tracking

Every mutation through `FieldEditor`, `ChoiceEditor` and `InstanceEditor` appends a row to
`form_audits` **inside the editing transaction** — the audit commits atomically with the change, or
not at all. Auditing is mandatory: the form's `audit:` class must be configured. Rows are
append-only, one per operation.

Each `patch` payload is built by a change struct in `CustomFields::Changes`
(`Instance`, `Field`, `Choice`) — every one exposes the same `empty?`/`payload` pair, so `AuditLog`
persists them identically with no special-casing. (The column is `patch`, not `changes`, to avoid
shadowing ActiveRecord's dirty-tracking `Model#changes`.)

`patch` is always a flat **JSON-Patch-style op list**: `{ "op", "path", "value"?, "from"? }`
entries. `path` is rooted at the entity token (`"instance_values"`, `"fields"`, `"choices"`); for
choices it then alternates field/value (`["choices","country","USA","state","Texas"]`). `op` is
`add` (nil→value / created), `replace` (value→value), or `remove` (deleted). `value` carries the new
value, `from` the old one where it captures otherwise-lost data (instance edits/removes); fields
carry neither (name-only), and a choice rename is a `replace` at the old value's path.

```ruby
form.audits.order(:created_at)   # via has_many :audits
```

`patch` payloads:

```jsonc
// instance create — each first value is an "add" carrying the value
[ { "op": "add", "path": ["instance_values", "color"],  "value": "black" },
  { "op": "add", "path": ["instance_values", "rating"], "value": 5 } ]
// instance update — replace keeps from+value; nil→value is add; value→nil is remove (with from)
[ { "op": "replace", "path": ["instance_values", "color"],  "from": "black", "value": "silver" },
  { "op": "add",     "path": ["instance_values", "note"],   "value": "hi" },
  { "op": "remove",  "path": ["instance_values", "rating"], "from": 5 } ]

// field create / delete — name-only, one row per operation (delete lists the whole cascade)
[ { "op": "add", "path": ["fields", "color"] }, { "op": "add", "path": ["fields", "country"] } ]
[ { "op": "remove", "path": ["fields", "country"] }, { "op": "remove", "path": ["fields", "state"] } ]

// choice add / rename
[ { "op": "add", "path": ["choices", "country", "USA"] } ]
[ { "op": "replace", "path": ["choices", "country", "USA"], "value": "US" } ]

// set_dependent_choices — each new value is its own add; removed subtrees collapse to one remove
[ { "op": "add",    "path": ["choices", "country", "Canada"] },
  { "op": "remove", "path": ["choices", "country", "Mexico"] },
  { "op": "add",    "path": ["choices", "country", "USA", "state", "Texas"] },
  { "op": "remove", "path": ["choices", "country", "USA", "state", "Florida"] },
  { "op": "add",    "path": ["choices", "country", "USA", "state", "California", "city", "LosAngeles"] } ]

// cascading delete_choices — the whole subtree is one op
[ { "op": "remove", "path": ["choices", "country", "USA"] } ]
```

Each row also carries `entity_type` (`field`/`choice`/`instance`), `entity_id` (the instance id;
the dropdown field id for choices; `0` for form-level field ops), `action`, `form_version`,
`instance_version` (instances only) and `actor` (nil until you populate it).

## Config

```ruby
CustomFields.configure do |c|
  c.default_type           = "text"
  c.max_form_versions      = 3   # schema versions kept before pruning
  c.max_instance_revisions = 3   # revisions kept per instance (1 = no history)
  c.prune_version_buffer   = 5
  c.batch_size             = 50
end
```

## Demo

Needs MySQL + Redis.

- `ruby demo/schema.rb` — create tables.
- `ruby demo/server.rb` — web UI (default `http://localhost:4567`).
- `ruby demo/console.rb` — seed sample data and print a summary.
- `ruby demo/stress_test.rb` — parallel workload with 2 real Sidekiq workers; logs to `demo/*.log`.

Settings via env: `DB_HOST`, `DB_PORT`, `DB_USERNAME`, `DB_PASSWORD`, `DB_NAME`, `REDIS_URL`, `PORT`.
