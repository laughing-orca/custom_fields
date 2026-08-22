$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "active_record"
require "active_support/cache"
require "sidekiq"
require "custom_fields"

module Rails
  def self.cache
    @cache ||= ActiveSupport::Cache::MemoryStore.new
  end
end

REDIS_URL = ENV.fetch("REDIS_URL", "redis://localhost:6379/0")
REDIS_READ_TIMEOUT = ENV.fetch("REDIS_READ_TIMEOUT", 15.0).to_f
Sidekiq.configure_server { |c| c.redis = { url: REDIS_URL, read_timeout: REDIS_READ_TIMEOUT } }
Sidekiq.configure_client { |c| c.redis = { url: REDIS_URL, read_timeout: REDIS_READ_TIMEOUT } }

DB_CONFIG = {
  adapter: "mysql2",
  encoding: "utf8mb4",
  host: ENV.fetch("DB_HOST", "127.0.0.1"),
  port: ENV.fetch("DB_PORT", 3306).to_i,
  username: ENV.fetch("DB_USERNAME", "root"),
  password: ENV.fetch("DB_PASSWORD", ""),
}
DB_NAME = ENV.fetch("DB_NAME", "custom_fields_demo")

ActiveRecord::Base.establish_connection(DB_CONFIG)
ActiveRecord::Base.connection.create_database(DB_NAME, charset: "utf8mb4") rescue nil
ActiveRecord::Base.establish_connection(DB_CONFIG.merge(database: DB_NAME))
ActiveRecord::Base.logger = Logger.new(STDOUT)

require_relative "models"

CustomFields.configure do |c|
  c.max_form_versions = 3
  c.prune_version_buffer = 0
  c.batch_size = 50
end
