# frozen_string_literal: true

require_relative "test_helper"

class TimestampTest < Minitest::Test
  def test_parses_iso8601_values_as_utc
    assert_equal Time.utc(2026, 1, 5, 12), CredAlignFlow::Timestamp.parse("2026-01-05T13:00:00+01:00")
  end

  def test_normalizes_time_objects_to_utc
    value = Time.new(2026, 1, 5, 13, 0, 0, "+01:00")

    assert_equal Time.utc(2026, 1, 5, 12), CredAlignFlow::Timestamp.parse(value)
  end

  def test_returns_nil_for_missing_or_malformed_values
    assert_nil CredAlignFlow::Timestamp.parse(nil)
    assert_nil CredAlignFlow::Timestamp.parse("")
    assert_nil CredAlignFlow::Timestamp.parse("not-a-time")
    assert_nil CredAlignFlow::Timestamp.parse("2026-01-05 13:00:00 +0100")
  end
end
