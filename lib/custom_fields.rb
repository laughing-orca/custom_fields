require "active_record"
require "active_support"
require "active_support/concern"
require "active_support/core_ext"
require "sidekiq"

require_relative "custom_fields/version"
require_relative "custom_fields/configuration"
require_relative "custom_fields/response"
require_relative "custom_fields/retryable"
require_relative "custom_fields/directed_graph"
require_relative "custom_fields/slot_layout"
require_relative "custom_fields/model/field"
require_relative "custom_fields/model/instance"
require_relative "custom_fields/model/data_store"
require_relative "custom_fields/model/sequence"
require_relative "custom_fields/model/form"
require_relative "custom_fields/model/choice"
require_relative "custom_fields/model/audit"
require_relative "custom_fields/changes"
require_relative "custom_fields/audit_log"
require_relative "custom_fields/field_editor"
require_relative "custom_fields/choice_editor"
require_relative "custom_fields/choice_validator"
require_relative "custom_fields/instance_editor"
require_relative "custom_fields/filter_result"
require_relative "custom_fields/instance_filter"
require_relative "custom_fields/field_version_pruner"
require_relative "custom_fields/prune_form_versions_job"

module CustomFields
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end
  end
end
