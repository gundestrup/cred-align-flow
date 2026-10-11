# frozen_string_literal: true

require "time"

module CredAlignFlow
  module Timestamp
    module_function

    def parse(value)
      return nil if value.to_s.empty?
      return value.utc if value.is_a?(Time)

      Time.iso8601(value.to_s).utc
    rescue ArgumentError
      nil
    end
  end
end
