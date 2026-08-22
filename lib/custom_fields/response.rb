module CustomFields
  class Response
    include Enumerable

    ERRORS = {
      "E001" => "the submitted values are not valid",
      "E002" => "the target does not exist",
      "E003" => "the operation could not complete because of concurrent changes",
    }.freeze

    attr_reader :results, :errors

    def self.build_error(code, message: nil, **details)
      error_code = code.to_s.upcase
      base_message = message || ERRORS.fetch(error_code, error_code)

      context = details.reject { |_, v| v.nil? || (v.respond_to?(:empty?) && v.empty?) }
                       .map { |k, v| "#{k}: #{v.is_a?(Array) ? v.join(", ") : v}" }
                       .join("; ")
      full_message = context.empty? ? base_message : "#{base_message} (#{context})"

      { code: error_code, message: full_message }.merge(details)
    end

    def self.success(result = nil, results: nil)
      list = results ? Array(results) : (result.nil? ? [] : [result])
      new(results: list, errors: [])
    end

    def self.failure(code_or_error, **details)
      err = code_or_error.is_a?(Hash) ? code_or_error : build_error(code_or_error, **details)
      new(results: [], errors: [err])
    end

    def initialize(results: [], errors: [])
      @results = Array(results)
      @errors = Array(errors)
    end

    def success?
      @errors.empty?
    end

    alias_method :successful?, :success?
    alias_method :success, :success?

    def failed?
      !success?
    end

    alias_method :failure?, :failed?

    def partial_success?
      @results.any? && @errors.any?
    end

    alias_method :partial?, :partial_success?

    def all_success?
      @results.any? && @errors.empty?
    end

    def result
      @results.first
    end

    alias_method :value, :result
    alias_method :data, :result

    def error
      @errors.first
    end

    def message
      error ? error[:message] : nil
    end

    def each(&block)
      @results.each(&block)
    end

    def [](index)
      @results[index]
    end

    def count
      @results.size
    end

    alias_method :size, :count

    def empty?
      @results.empty?
    end

    def to_ary
      [results, errors]
    end

    def deconstruct
      to_ary
    end

    def deconstruct_keys(keys)
      {
        success: success?,
        result: result,
        results: results,
        error: error,
        errors: errors,
      }.slice(*keys)
    end
  end
end
