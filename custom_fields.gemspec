require_relative "lib/custom_fields/version"

Gem::Specification.new do |spec|
  spec.name = "custom_fields"
  spec.version = CustomFields::VERSION
  spec.authors = ["Pranav Surya"]
  spec.email = ["trulyop100@gmail.com"]
  spec.summary = "versioned custom attributes backed by typed slot columns"
  spec.description = "versioned custom attributes backed by typed slot columns"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb"] + ["README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 7.0"
  spec.add_dependency "sidekiq", ">= 6.0"
end
