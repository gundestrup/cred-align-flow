# frozen_string_literal: true

module CredAlignFlow
  # Strict dotenv parser. Supported grammar:
  #
  #   # comment
  #   NAME=value
  #   NAME="double-quoted"      escapes: \\ \" \n \r \t \$ — may span lines
  #   NAME='single-quoted'      literal — may span lines
  #   export NAME=value
  #
  # Bare values strip a trailing " #..." comment. Anything else — unclosed
  # quotes, missing names, malformed lines, duplicate names — is an error
  # with a line number so credential material is never silently truncated.
  # Values are literal: no variable interpolation and no file expansion.
  class Dotenv
    NAME_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]*\z/
    ESCAPES = { "n" => "\n", "r" => "\r", "t" => "\t", "\\" => "\\", '"' => '"', "$" => "$", "'" => "'" }.freeze

    def self.load(path)
      return {} if path.nil? || !File.exist?(path)

      parse(File.read(path, encoding: "UTF-8"), path: path)
    rescue SystemCallError => e
      raise ConfigError, "could not read env file #{path}: #{e.message}"
    end

    def self.parse(text, path: "<env>")
      values = {}
      lines = text.split("\n", -1)
      index = 0
      while index < lines.length
        line_number = index + 1
        stripped = lines[index].sub(/\r\z/, "").strip
        index += 1
        next if stripped.empty? || stripped.start_with?("#")

        stripped = stripped.sub(/\Aexport\s+/, "")
        match = stripped.match(/\A([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\z/m)
        raise ConfigError, "#{path}:#{line_number}: expected NAME=value (line is not a valid assignment)" unless match

        name = match[1]
        raise ConfigError, "#{path}:#{line_number}: duplicate #{name}" if values.key?(name)

        value, index = parse_value(match[2], lines, index, path, line_number)
        values[name] = value
      end
      values
    end

    # Returns [value, next_line_index]. `rest` is the text after "=" on the
    # first line; quoted values may consume further lines.
    def self.parse_value(rest, lines, index, path, line_number)
      if rest.start_with?('"') || rest.start_with?("'")
        quoted_value(rest, lines, index, path, line_number)
      else
        [rest.sub(/\s+#.*\z/m, "").rstrip, index]
      end
    end

    def self.quoted_value(rest, lines, index, path, line_number)
      quote = rest[0]
      buffer = rest[1..]
      loop do
        closing = closing_quote_index(buffer, quote)
        if closing
          tail = buffer[(closing + 1)..]
          unless tail.strip.empty? || tail.strip.start_with?("#")
            raise ConfigError, "#{path}:#{line_number}: characters after closing quote"
          end

          return [decode(buffer[0...closing], quote, path, line_number), index]
        end

        raise ConfigError, "#{path}:#{line_number}: unterminated quoted value" if index >= lines.length

        buffer = "#{buffer}\n#{lines[index].sub(/\r\z/, '')}"
        index += 1
      end
    end

    # Index of the quote that ends the value, skipping backslash escapes in
    # double-quoted strings only.
    def self.closing_quote_index(buffer, quote)
      offset = 0
      loop do
        found = buffer.index(quote, offset)
        return nil unless found
        return found unless quote == '"'

        backslashes = 0
        backslashes += 1 while found - 1 - backslashes >= 0 && buffer[found - 1 - backslashes] == "\\"
        return found if backslashes.even?

        offset = found + 1
      end
    end

    def self.decode(raw, quote, path, line_number)
      return raw unless quote == '"'

      raw.gsub(/\\(.)/m) do
        replacement = ESCAPES[Regexp.last_match(1)]
        raise ConfigError, "#{path}:#{line_number}: unsupported escape \\#{Regexp.last_match(1)}" unless replacement

        replacement
      end
    end
  end
end
