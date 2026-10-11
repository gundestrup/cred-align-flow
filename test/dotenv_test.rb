# frozen_string_literal: true

require_relative "test_helper"

class DotenvTest < Minitest::Test
  def test_loads_unquoted_single_and_double_quoted_values
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".env.local")
      File.write(path, <<~ENV)
        export FIRST=value
        SECOND='single quoted value'
        THIRD="double quoted value"
      ENV

      values = CredAlignFlow::Dotenv.load(path)

      assert_equal "value", values["FIRST"]
      assert_equal "single quoted value", values["SECOND"]
      assert_equal "double quoted value", values["THIRD"]
    end
  end

  def test_double_quoted_escapes_and_multiline_values
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".env")
      File.write(path, "A=\"line one\\nline two\"\nB=\"literal\\t\"\nC='\\n'\n")

      values = CredAlignFlow::Dotenv.load(path)

      assert_equal "line one\nline two", values["A"]
      assert_equal "literal\t", values["B"]
      assert_equal "\\n", values["C"] # single quotes keep escapes literal
    end
  end

  def test_preserves_physical_newlines_in_quoted_values
    values = CredAlignFlow::Dotenv.parse("SSH_KEY=\"first line\nsecond line\"\n")

    assert_equal "first line\nsecond line", values.fetch("SSH_KEY")
  end

  def test_comments_and_empty_values
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".env")
      File.write(path, "# comment\nEMPTY=\nA=value # trailing comment\n")

      values = CredAlignFlow::Dotenv.load(path)

      assert_equal "", values["EMPTY"]
      assert_equal "value", values["A"]
    end
  end

  def test_rejects_malformed_lines_instead_of_silently_dropping_them
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".env")
      File.write(path, "GOOD=value\nINVALID-NAME=ignored\n")

      error = assert_raises(CredAlignFlow::ConfigError) { CredAlignFlow::Dotenv.load(path) }

      assert_match(/secrets?\b|\.env|#{Regexp.escape(File.basename(path))}/, error.message)
    end
  end

  def test_rejects_unterminated_quotes_and_duplicate_names
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".env")
      File.write(path, "A='unterminated\n")

      assert_raises(CredAlignFlow::ConfigError) { CredAlignFlow::Dotenv.load(path) }

      File.write(path, "A=one\nA=two\n")

      assert_raises(CredAlignFlow::ConfigError) { CredAlignFlow::Dotenv.load(path) }
    end
  end

  def test_missing_file_returns_empty_hash
    Dir.mktmpdir do |dir|
      assert_equal({}, CredAlignFlow::Dotenv.load(File.join(dir, "absent.env")))
    end
  end
end
