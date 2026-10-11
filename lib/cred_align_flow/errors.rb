# frozen_string_literal: true

module CredAlignFlow
  class Error < StandardError; end
  class ConfigError < Error; end
  class ProviderError < Error; end
  class StateError < Error; end
end
