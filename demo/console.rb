require_relative "boot"
require_relative "schema"

COLORS = %w[Black White Red Blue Green Silver Gold Pink].freeze
BRANDS = %w[Acme Globex Initech Umbrella Soylent Hooli].freeze

def seed
  form = Form.create_form(name: "Survey", latest_version: 1)

  CustomFields::FieldEditor.new(form).create_fields([
    { name: "color", field_type: "text" },
    { name: "brand", field_type: "text" },
    { name: "rating", field_type: "integer" },
    { name: "price", field_type: "integer" },
  ])

  editor = CustomFields::InstanceEditor.new(form)

  34.times do |i|
    editor.create_instance(values: {
                             "color" => COLORS[i % COLORS.size],
                             "brand" => BRANDS[i % BRANDS.size],
                             "rating" => (i % 5) + 1,
                             "price" => 100 + i,
                           })
  end

  CustomFields::FieldEditor.new(form).delete_fields(["brand"])
  form.reload

  33.times do |i|
    editor.create_instance(values: {
                             "color" => COLORS[i % COLORS.size],
                             "rating" => (i % 5) + 1,
                             "price" => 200 + i,
                           })
  end

  CustomFields::FieldEditor.new(form).delete_fields(["rating"])
  form.reload

  33.times do |i|
    editor.create_instance(values: {
                             "color" => COLORS[i % COLORS.size],
                             "price" => 300 + i,
                           })
  end

  form
end

$form = seed

puts "seeded Form ##{$form.id} '#{$form.name}' (latest v#{$form.latest_version})"
puts "field intervals:            #{$form.fields.order(:valid_from_version, :id).pluck(:name, :valid_from_version, :valid_to_version).map { |n, f, t| "#{n}[v#{f}..#{t.zero? ? "∞" : t})" }}"
puts "instances by form_version: #{$form.instances.group(:form_version).order(:form_version).count}"
puts "total instances:           #{$form.instances.count} (previous revisions: #{$form.previous_instances.count})"
puts
puts "available: Form, Form::Field, Form::Instance, Form::PreviousInstance, and $form (the seeded record)"
puts "try: $form.instances.group(:form_version).count"
puts "     CustomFields::InstanceFilter.new($form).filter_instances(color: 'Red').count"
