# frozen_string_literal: true

module Bookworm
  class Error < StandardError
    attr_reader :code, :details

    def initialize(message, code: "ERROR", details: {})
      super(message)
      @code = code
      @details = details
    end

    def to_h
      { code: code, message: message, details: details }
    end
  end

  class ValidationError < Error
    def initialize(message, details: {})
      super(message, code: "VALIDATION_ERROR", details: details)
    end
  end

  class NotFoundError < Error
    def initialize(message, details: {})
      super(message, code: "NOT_FOUND", details: details)
    end
  end

  class UnsupportedFormatError < Error
    def initialize(message, details: {})
      super(message, code: "UNSUPPORTED_FORMAT", details: details)
    end
  end

  class DependencyMissingError < Error
    def initialize(message, details: {})
      super(message, code: "DEPENDENCY_MISSING", details: details)
    end
  end

  class TextTooLargeError < Error
    def initialize(message, details: {})
      super(message, code: "TEXT_TOO_LARGE", details: details)
    end
  end

  class OcrRequiredError < Error
    def initialize(message, details: {})
      super(message, code: "OCR_REQUIRED", details: details)
    end
  end
end
