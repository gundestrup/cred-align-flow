# frozen_string_literal: true

require_relative "test_helper"

class SelectorTest < Minitest::Test
  def test_filter_matches_nil_as_unfiltered_and_supports_extglob
    assert_equal true, CredAlignFlow::Selector.matches_filter?(nil, "github-main")
    assert_equal true, CredAlignFlow::Selector.matches_filter?("github-*", "github-main")
    refute CredAlignFlow::Selector.matches_filter?("forgejo-*", "github-main")
  end
end
