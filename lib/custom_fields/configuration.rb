module CustomFields
  class Configuration
    DEFAULT_MAX_FORM_VERSIONS = 3
    DEFAULT_MAX_INSTANCE_REVISIONS = 3
    DEFAULT_PRUNE_VERSION_BUFFER = 5
    DEFAULT_TYPE = "text"
    DEFAULT_BATCH_SIZE = 1000
    DEFAULT_MAX_SELF_ENQUEUES = 10

    attr_writer :max_form_versions,
                :max_instance_revisions,
                :prune_version_buffer,
                :default_type,
                :batch_size,
                :max_self_enqueues

    def max_form_versions
      @max_form_versions || DEFAULT_MAX_FORM_VERSIONS
    end

    def max_instance_revisions
      @max_instance_revisions || DEFAULT_MAX_INSTANCE_REVISIONS
    end

    def prune_version_buffer
      @prune_version_buffer || DEFAULT_PRUNE_VERSION_BUFFER
    end

    def default_type
      @default_type || DEFAULT_TYPE
    end

    def batch_size
      @batch_size || DEFAULT_BATCH_SIZE
    end

    def max_self_enqueues
      @max_self_enqueues || DEFAULT_MAX_SELF_ENQUEUES
    end
  end
end
