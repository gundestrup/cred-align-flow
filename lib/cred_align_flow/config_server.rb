# frozen_string_literal: true

module CredAlignFlow
  class ConfigServer
    DEFAULT_PORT = 8043

    def initialize(editor:, port: DEFAULT_PORT)
      @editor = editor
      @port = Integer(port)
      raise ConfigError, "UI port must be between 1 and 65535" unless (1..65_535).cover?(@port)
    rescue ArgumentError, TypeError
      raise ConfigError, "UI port must be an integer between 1 and 65535"
    end

    def start
      root = File.expand_path("../..", __dir__)
      rackup = File.join(__dir__, "config_ui.ru")
      puts "Config UI: http://127.0.0.1:#{@port}/"
      exec(
        {
          "CRED_ALIGN_FLOW_CONFIG_PATH" => @editor.config_path,
          "CRED_ALIGN_FLOW_ENV_PATH" => @editor.env_path,
          "CRED_ALIGN_FLOW_STATE_PATH" => @editor.state_path,
          "CRED_ALIGN_FLOW_UI_PORT" => @port.to_s
        },
        "bundle", "exec", "itsi", "serve",
        "--bind", "http://127.0.0.1:#{@port}",
        "--rackup_file", rackup,
        "--workers", "1",
        "--threads", "1",
        "--fiber_scheduler",
        chdir: root
      )
    rescue SystemCallError => e
      raise ConfigError, "could not start Itsi config UI: #{e.message}"
    end
  end
end
