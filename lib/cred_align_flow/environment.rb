# frozen_string_literal: true

module CredAlignFlow
  # Process environment consulted for credential/value fallbacks: when an
  # env-file value is absent, resolution checks these variables. Tests
  # replace it with a clean map so ambient variables — a CI SONAR_TOKEN,
  # a developer's GH_TOKEN — can never masquerade as configured secrets.
  def self.environment
    @environment || ENV
  end

  def self.environment=(environment)
    @environment = environment
  end
end
