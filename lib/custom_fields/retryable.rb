module CustomFields
  module Retryable
    RETRYABLE_ERRORS = [
      ActiveRecord::Deadlocked,
      ActiveRecord::LockWaitTimeout,
      ActiveRecord::SerializationFailure,
    ]

    def with_retries(max_retries, fallback_error: "E003")
      max_retries.times do
        begin
          return yield
        rescue *RETRYABLE_ERRORS
          # retry
        end
      end

      Response.failure(fallback_error)
    end
  end
end
