# frozen_string_literal: true

module CredAlignFlow
  class ConfigServer
    DEFAULT_PORT = 8043
    LOCK_NAME = ".ui.lock"

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
      # Kept in an ivar so GC can't close the fd before exec; the fd
      # survives exec (close_on_exec = false) so the Itsi master holds
      # the lock for its lifetime.
      @ui_lock = claim_ui_lock
      puts "Config UI: http://127.0.0.1:#{@port}/"
      exec(
        {
          # Itsi crashes on US-ASCII locales while loading its bundled docs
          # (engineering-memory: tools/ruby-web-servers.md).
          "LANG" => "en_US.UTF-8",
          "LC_ALL" => "en_US.UTF-8",
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

    def stop
      pid = read_lock_pid
      raise ConfigError, "no config UI lock at #{lock_path} — is the UI running?" unless pid

      command = `ps -o command= -p #{pid}`.to_s.strip
      unless command.include?("itsi") || command.include?("config_ui")
        File.delete(lock_path)
        raise ConfigError,
              "lock pid #{pid} is not a config UI process#{" (#{command})" unless command.empty?}; removed stale lock"
      end
      Process.kill("TERM", pid)
      puts "Sent TERM to config UI (pid #{pid}); the Itsi workers exit with it."
    rescue Errno::ESRCH
      File.delete(lock_path)
      raise ConfigError, "stale lock removed; no config UI process was running"
    end

    private

    # The lock lives beside the hand-edited config so its contents never
    # matter — the file just records the itsi master's pid while held.
    def lock_path
      File.join(File.dirname(@editor.config_path), LOCK_NAME)
    end

    def read_lock_pid
      return nil unless File.exist?(lock_path)

      pid = Integer(File.read(lock_path).strip, exception: false)
      pid&.positive? ? pid : nil
    end

    def claim_ui_lock
      file = File.new(lock_path, File::RDWR | File::CREAT, 0o600)
      unless file.flock(File::LOCK_EX | File::LOCK_NB)
        pid = read_lock_pid
        file.close
        raise ConfigError,
              "a config UI already holds #{lock_path}#{" (pid #{pid})" if pid} — " \
              "stop it with `cred-align-flow ui --stop` or `lsof -tiTCP:#{@port} -sTCP:LISTEN | xargs kill`"
      end
      file.rewind
      file.truncate(0)
      file.write(Process.pid.to_s)
      file.flush
      file.close_on_exec = false
      file
    end
  end
end
