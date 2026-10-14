# frozen_string_literal: true

require "digest"
require "json"
require "optparse"

module CredAlignFlow
  class CLI
    COMMANDS = %w[doctor inventory pull plan diff check apply ui scaffold help].freeze

    def run(argv)
      return puts(VERSION) || 0 if contains_global_flag?(argv, %w[--version -v])
      return puts(help_text) || 0 if argv.empty? || contains_global_flag?(argv, %w[--help -h])

      command_index = find_command_index(argv)
      unless command_index
        return puts(help_text) || 0 if options_only?(argv)

        warn "cred-align-flow: expected one of #{COMMANDS.join(', ')}; run `cred-align-flow help`"
        return 1
      end
      command = argv.delete_at(command_index)
      if command == "help"
        raise OptionParser::ParseError, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?

        return puts(help_text) || 0
      end

      options = parse_options(command, argv)
      config, state, env_values = load_context(options)
      validate_filters!(options, config)

      case command
      when "doctor"
        return doctor(config, env_values, verify: options[:verify])
      when "scaffold"
        return scaffold_secrets(config, env_values, options)
      when "ui"
        editor = ConfigEditor.new(config_path: config.path, env_path: @env_path, state_path: state.path)
        ConfigServer.new(editor: editor, port: options[:port] || ConfigServer::DEFAULT_PORT).start
      when "inventory", "pull"
        refresh_inventory(config, state, env_values, source_filter: options[:source])
      when "plan", "diff", "check"
        return run_plan_command(command, config, state, env_values, options)
      when "apply"
        return run_apply(config, state, env_values, options)
      end

      0
    rescue Error, OptionParser::ParseError, SystemCallError => e
      warn "cred-align-flow: #{e.message}"
      1
    end

    VALUE_OPTION_ARITY = {
      "--config" => 1,
      "--env-file" => 1,
      "--state" => 1,
      "--port" => 1,
      "--source" => 1,
      "--repo" => 1,
      "--secret" => 1,
      "--context" => 1,
      "--only" => 1,
      "--ignore" => 1,
      "--target" => 1
    }.freeze
    FLAG_OPTIONS = %w[--offline --strict --verify --dry-run --force --yes --digests-only --help --version].freeze

    private

    def run_plan_command(command, config, state, env_values, options)
      load_inventory(config, state, env_values, options)
      planner = build_planner(config, state, env_values, options)
      print_items(planner.plan)
      validate_repo_filter!(options, config, state)
      return 0 unless command == "check"

      planner.blocking_items(strict: options[:strict]).empty? ? 0 : 1
    end

    def run_apply(config, state, env_values, options)
      refresh_inventory(config, state, env_values, source_filter: options[:source],
                                                   context_filter: options[:context])
      state = State.new(state.path)
      ensure_inventory!(config, state, source_filter: options[:source], context_filter: options[:context])
      verify_loaded_inputs!(config, @env_path)
      plan_revision = input_revision(config, @env_path, state.path)
      planner = build_planner(config, state, env_values, options)
      plan = planner.plan
      print_items(plan)
      validate_repo_filter!(options, config, state)
      if options[:dry_run]
        puts
        puts "Dry run: no remote secrets were changed."
        return 0
      end

      actionable = planner.actionable_items(force: options[:force])
      blockers = apply_blockers(plan, options[:force])
      return report_outcomes([], blockers: blockers) if actionable.empty?

      approval = apply_approval(options, actionable.length)
      unless approval == :approved
        puts "Cancelled; no remote secrets were changed." if approval == :declined
        return approval == :declined && blockers.empty? ? 0 : 1
      end

      verify_plan_inputs!(config, @env_path, state.path, plan_revision)
      outcomes = Applier.new(config, state, env_values).apply(actionable, force: options[:force])
      report_outcomes(outcomes, blockers: blockers)
    end

    def contains_global_flag?(argv, flags)
      index = 0
      while index < argv.length
        argument = argv[index]
        return true if flags.include?(argument)

        index = next_argument_index(argv, index)
      end
      false
    end

    def find_command_index(argv)
      index = 0
      while index < argv.length
        argument = argv[index]
        unless argument.start_with?("--")
          return index if COMMANDS.include?(argument)

          index += 1
          next
        end

        index = next_argument_index(argv, index)
      end
      nil
    end

    # True when every token is a known option (with its value) — invoked
    # without a command that prints help rather than an error.
    def options_only?(argv)
      index = 0
      while index < argv.length
        argument = argv[index]
        return false unless argument.start_with?("--")

        option = argument.split("=", 2).first
        arity = VALUE_OPTION_ARITY[option]
        return false unless arity || FLAG_OPTIONS.include?(option)

        index = next_argument_index(argv, index)
      end
      true
    end

    def next_argument_index(argv, index)
      argument = argv[index]
      option = argument.split("=", 2).first
      arity = VALUE_OPTION_ARITY[option]
      index + (arity && !argument.include?("=") ? arity + 1 : 1)
    end

    def parse_options(command, argv)
      options = {
        offline: false,
        force: false,
        strict: false,
        dry_run: false,
        verify: false,
        source: nil,
        repo: nil,
        secret: nil,
        context: nil,
        port: nil,
        only: nil,
        ignore: nil,
        targets: [],
        digests_only: false,
        yes: false
      }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: cred-align-flow #{command} [options]"
        register_path_options(opts, options, command)
        register_filter_options(opts, options, command)
        register_command_options(opts, options, command)
      end
      parser.parse!(argv)
      raise OptionParser::ParseError, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?
      if command == "apply" && options[:dry_run] && options[:yes]
        raise OptionParser::ParseError, "--yes cannot be combined with --dry-run"
      end

      options
    end

    def register_path_options(opts, options, command)
      opts.on("--config PATH", "Configuration file") { |value| options[:config] = value }
      opts.on("--env-file PATH", "Local environment/value file") { |value| options[:env_file] = value }
      opts.on("--state PATH", "Inventory state file") { |value| options[:state] = value }
      opts.on("--port PORT", Integer, "Local config UI port") { |value| options[:port] = value } if command == "ui"
    end

    def register_filter_options(opts, options, command)
      if %w[inventory pull plan diff check apply].include?(command)
        opts.on("--source PATTERN", "Limit to matching source names") { |value| options[:source] = value }
      end
      return unless %w[plan diff check apply].include?(command)

      opts.on("--repo PATTERN", "Limit to matching repository names") { |value| options[:repo] = value }
      opts.on("--secret PATTERN", "Limit to matching secret names") { |value| options[:secret] = value }
      opts.on("--context PATTERN", "Limit to matching provider contexts") { |value| options[:context] = value }
    end

    def register_command_options(opts, options, command)
      opts.on("--offline", "Use cached inventory") { options[:offline] = true } if %w[plan diff check].include?(command)
      opts.on("--strict", "Treat unexpected remote secrets as failures") { options[:strict] = true } if command == "check"
      opts.on("--verify", "Also probe provider authentication/connectivity") { options[:verify] = true } if command == "doctor"
      register_apply_options(opts, options) if command == "apply"
      register_scaffold_options(opts, options) if command == "scaffold"
    end

    def register_apply_options(opts, options)
      opts.on("--dry-run", "Refresh and report without writing remote secrets") { options[:dry_run] = true }
      opts.on("--force", "Overwrite unverified or remotely newer secrets") { options[:force] = true }
      opts.on("--yes", "Approve the exact plan printed by this invocation") { options[:yes] = true }
    end

    def register_scaffold_options(opts, options)
      opts.on("--only NAMES", "Import only these comma-separated env names") { |value| options[:only] = value.split(",") }
      opts.on("--target TARGET", "Exact SOURCE|CONTEXT|OWNER/REPO destination; repeat for every tuple") do |value|
        target = value.split("|", -1)
        validate_target_option!(target)
        options[:targets] << target
      end
      opts.on("--ignore NAMES", "Add env names to ignored_env_names and skip them") do |value|
        options[:ignore] = value.split(",")
      end
      opts.on("--digests-only", "Refresh value digests without importing new names") do
        options[:digests_only] = true
      end
    end

    def validate_target_option!(target)
      return if target.length == 3 && target.none?(&:empty?)

      raise OptionParser::ParseError, "expected SOURCE|CONTEXT|OWNER/REPO"
    end

    def load_context(options)
      config_path = options[:config] || Config.default_path
      config = Config.new(config_path)
      env_path = File.expand_path(options[:env_file] || config.env_path)
      state_path = File.expand_path(options[:state] || config.state_file)
      config.validate_runtime_paths!(env_path: env_path, state_path: state_path)
      state = State.new(state_path)
      unless Fingerprint.configured?
        Fingerprint.configure!(
          Fingerprint.default_key_file(env_path),
          require_existing: Fingerprint.protected_records_present?(config, state)
        )
      end
      @env_path = env_path
      @config_input_revision = input_revision(config, env_path)
      env_values = Dotenv.load(env_path)
      verify_loaded_inputs!(config, env_path)
      [config, state, env_values]
    end

    def input_revision(config, env_path, state_path = nil)
      paths = [config.path, config.rules.path, env_path, Fingerprint.default_key_file(env_path), state_path].compact.uniq
      inputs = paths.map do |path|
        expanded = File.expand_path(path)
        content = File.binread(expanded)
        [expanded, Fingerprint.digest("apply-input:#{expanded}", content)]
      rescue Errno::ENOENT
        [expanded, nil]
      end
      Digest::SHA256.hexdigest(JSON.generate(inputs))
    rescue SystemCallError => e
      raise ConfigError, "could not verify local apply inputs (#{e.class})"
    end

    def verify_loaded_inputs!(config, env_path)
      return if input_revision(config, env_path) == @config_input_revision

      raise ConfigError, "config, rules, env file, or fingerprint key changed while preparing this command; rerun"
    end

    def verify_plan_inputs!(config, env_path, state_path, expected_revision)
      return if input_revision(config, env_path, state_path) == expected_revision

      raise ConfigError, "local inputs or inventory changed while approval was pending; no remote write was attempted"
    end

    # Source/secret/context filters match configured names here; repository
    # filters are checked against refreshed inventory after provider reads.
    def validate_filters!(options, config)
      if options[:source] && config.source_ids.none? { |id| Selector.matches_filter?(options[:source], id) }
        raise ConfigError, "no configured source matches --source #{options[:source].inspect}"
      end

      if options[:secret]
        names = config.secrets.map { |secret| secret.fetch("name") }
        if names.none? { |name| Selector.matches_filter?(options[:secret], name) }
          raise ConfigError, "no configured secret matches --secret #{options[:secret].inspect}"
        end
      end
      return unless options[:context]

      source_ids = config.source_ids.select { |source_id| Selector.matches_filter?(options[:source], source_id) }
      contexts = source_ids.flat_map do |source_id|
        adapter = Providers.adapter_for(config.source(source_id)["type"])
        adapter ? adapter::CONTEXTS : []
      end.uniq
      return if contexts.any? { |context| Selector.matches_filter?(options[:context], context) }

      raise ConfigError, "no provider context matches --context #{options[:context].inspect}"
    end

    def validate_repo_filter!(options, config, state)
      return unless options[:repo]

      sources = config.source_ids.select { |source_id| Selector.matches_filter?(options[:source], source_id) }
      matched = sources.any? do |source_id|
        state.selected_repositories(source_id).any? do |_name, repository|
          Selector.matches_any?([options[:repo]], repository)
        end
      end
      return if matched

      raise ConfigError, "no selected repository matches --repo #{options[:repo].inspect}"
    end

    def load_inventory(config, state, env_values, options)
      unless options[:offline]
        refresh_inventory(config, state, env_values, source_filter: options[:source],
                                                     context_filter: options[:context])
      end
      ensure_inventory!(config, state, source_filter: options[:source], context_filter: options[:context])
    end

    def refresh_inventory(config, state, env_values, source_filter: nil, context_filter: nil)
      refreshed = Inventory.new(config, state, env_values).refresh!(
        source_filter: source_filter,
        context_filter: context_filter
      )
      refreshed.each do |source_id|
        selected = state.selected_repositories(source_id).length
        total = state.data.dig("sources", source_id, "repositories")&.length || 0
        label = config.repositories_config(source_id)["include"].empty? ? "discovered" : "configured"
        truncated = state.data.dig("sources", source_id, "truncated") ? " (may be truncated at the provider limit)" : ""
        puts "#{source_id}: #{label} #{total} repositories; #{selected} selected#{truncated}"
      end
      puts "No configured sources matched #{source_filter.inspect}." if refreshed.empty?
      puts "Inventory written to #{state.path}"
    end

    def ensure_inventory!(config, state, source_filter: nil, context_filter: nil)
      expected = config.source_ids.select { |source_id| Selector.matches_filter?(source_filter, source_id) }
      missing = expected - state.data.fetch("sources", {}).keys
      raise StateError, "No cached inventory for #{missing.join(', ')}; run inventory first" unless missing.empty?

      expected.each do |source_id|
        status = InventoryCheck.source_status(config, state, source_id)
        if status["state"] == "stale"
          raise StateError,
                "Cached inventory for #{source_id} is stale (#{status['reasons'].join('; ')}); " \
                "run inventory again before planning"
        end

        needed = config.contexts_for_source(source_id)
        needed = needed.select { |context| Selector.matches_filter?(context_filter, context) } if context_filter
        uncovered = needed & status["missing_contexts"]
        next if uncovered.empty?

        covered = needed - uncovered
        raise StateError,
              "Cached inventory for #{source_id} does not cover #{uncovered.join(', ')}" \
              "#{" (covers #{covered.join(', ')})" unless covered.empty?}; run inventory again first"
      end
    end

    def build_planner(config, state, env_values, options)
      Planner.new(
        config,
        state,
        env_values,
        source_filter: options[:source],
        repo_filter: options[:repo],
        secret_filter: options[:secret],
        context_filter: options[:context]
      )
    end

    def apply_blockers(plan, force)
      plan.select do |item|
        %w[missing_value pull_only].include?(item.action) ||
          (!force && %w[unverified_present remote_newer].include?(item.action))
      end
    end

    def apply_approval(options, target_count)
      return :approved if options[:yes]

      unless $stdin.tty?
        warn "apply requires --yes when stdin is not interactive"
        return :requires_yes
      end

      print "Apply #{target_count} planned secret update#{'s' unless target_count == 1}? [y/N] "
      $stdin.gets.to_s.strip.casecmp?("y") ? :approved : :declined
    end

    def scaffold_secrets(config, env_values, options)
      scaffolder = Scaffolder.new(config.path)
      only = options[:only]&.uniq
      targets = options[:targets].uniq
      ignored_names = options[:ignore] || []
      validate_scaffold_options!(options, only, targets)

      candidates = scaffolder.candidates(env_values, config)
      eligible = candidates - ignored_names
      names, target_scope = resolve_scaffold_selection(
        scaffolder, config, eligible, only, targets, digests_only: options[:digests_only]
      )

      ignored = scaffolder.ignore!(ignored_names)
      unless ignored.empty?
        puts "Added #{ignored.length} name#{'s' unless ignored.length == 1} to ignored_env_names: #{ignored.join(', ')}"
        config = Config.new(config.path)
        scaffolder = Scaffolder.new(config.path)
      end
      unless names.empty?
        pending = scaffolder.candidates(env_values, config)
        unknown = names - pending
        raise ConfigError, "env names ceased to be eligible for import: #{unknown.join(', ')}" unless unknown.empty?

        puts "Will add #{names.length} active secret entr#{names.length == 1 ? 'y' : 'ies'} for exact targets:"
        target_scope.each { |source, context, repository| puts "  #{source} #{context} #{repository}" }
      end

      result = scaffolder.apply!(names, config, env_values, targets: target_scope)
      report_scaffold_result(result, config, ignored, eligible)
    end

    def validate_scaffold_options!(options, only, targets)
      return unless options[:digests_only] && (only || !targets.empty?)

      raise ConfigError, "--digests-only cannot be combined with --only or --target"
    end

    def resolve_scaffold_selection(scaffolder, config, eligible, only, targets, digests_only:)
      if only.nil?
        if targets.empty?
          unless digests_only || eligible.empty?
            puts "Unimported env names: #{eligible.join(', ')}"
            puts "No active entries were added. Use --only NAMES and repeat --target 'SOURCE|CONTEXT|OWNER/REPO' per destination."
          end
          return [[], []]
        end

        raise ConfigError, "--target requires --only so imported env names are explicit"
      end
      raise ConfigError, "--only requires at least one env name" if only.empty?

      unknown = only - eligible
      raise ConfigError, "env names are not eligible for import: #{unknown.join(', ')}" unless unknown.empty?

      [only, scaffolder.validate_targets(config, targets)]
    end

    def report_scaffold_result(result, config, ignored, eligible)
      added = result["added"]
      digests = result["digests"]
      skipped = result["skipped_digests"]
      if added.empty? && digests.empty? && skipped.empty? && ignored.empty? && eligible.empty?
        puts "No unmanaged env-file variables to scaffold into #{config.path}."
        return 0
      end

      unless added.empty?
        puts "Scaffolded #{added.length} active secret entr#{added.length == 1 ? 'y' : 'ies'} into #{config.path}:"
        added.each { |name| puts "  #{name}" }
        puts "Entries are active only for the exact targets listed above."
      end
      unless digests.empty?
        puts "Updated value digests for #{digests.length} secret#{'s' unless digests.length == 1}:"
        digests.each { |name| puts "  #{name}" }
      end
      unless skipped.empty?
        puts "Could not update digests for #{skipped.length} secret#{'s' unless skipped.length == 1} " \
             "(entry format not editable): #{skipped.join(', ')}"
      end
      0
    end

    def doctor(config, env_values, verify: false)
      puts "Config: #{config.path}"
      puts "Env file: #{@env_path}#{' (not found)' unless File.exist?(@env_path)}"
      puts "State: #{config.state_file}"
      puts "Rules: #{config.rules_file}"
      puts "Sources: #{config.source_ids.join(', ')}"
      puts "Secrets configured: #{config.secrets.length}"

      missing_auth = config.source_ids.select do |source_id|
        auth_ref = config.source(source_id)["auth_env"]
        auth_ref && env_values[auth_ref].to_s.empty? && ENV[auth_ref].to_s.empty?
      end
      problems = report_missing_auth(config, missing_auth)
      problems += report_missing_values(config, env_values)
      problems += report_digest_status(config, env_values)
      config.source_ids.each do |source_id|
        problems += check_doctor_provider(config, env_values, source_id, missing_auth, verify)
      end
      problems.zero? ? 0 : 1
    end

    def report_missing_auth(config, missing_auth)
      return 0 if missing_auth.empty?

      puts "Authentication environment references not set:"
      missing_auth.each { |source_id| puts "  #{source_id}: #{config.source(source_id)['auth_env']}" }
      1
    end

    def report_missing_values(config, env_values)
      missing = config.secrets.select { |secret| config.value_for(secret, env_values).nil? }
      if missing.empty?
        puts "Secret value references: all configured values are available"
      else
        puts "Missing secret value references:"
        missing.each { |secret| puts "  #{secret.fetch('name')}: #{config.value_ref(secret)}" }
      end
      missing.empty? ? 0 : 1
    end

    def check_doctor_provider(config, env_values, source_id, missing_auth, verify)
      # Do not even probe a provider whose credential reference is unset.
      if missing_auth.include?(source_id)
        puts "#{source_id}: skipped (authentication reference is not set)"
        return 0
      end

      provider = Providers.build(config.source(source_id), env_values)
      line = "#{source_id}: #{provider.cli_version || 'provider CLI unavailable'}"
      line += " (pull-only)" unless provider.writable?
      puts line
      problems = 0
      if verify
        readiness = provider.readiness
        puts "  readiness: #{readiness || 'probe unavailable'}"
        problems += 1 if readiness.nil? || readiness.start_with?("not authenticated:", "gh unavailable:")
      end
      config.secrets.each do |secret|
        next unless config.secret_applies_to_source?(secret, source_id)

        config.contexts_for(secret, source_id).each { |context| provider.validate_context!(context) }
      end
      problems
    end

    def report_digest_status(config, env_values)
      statuses = config.secrets.group_by { |secret| config.value_digest_status(secret, env_values) }
      current = statuses.fetch(:current, []).length
      changed = statuses.fetch(:changed, [])
      missing = statuses.fetch(:missing, [])
      unverifiable = statuses.fetch(:unverifiable, [])
      unrecorded = statuses.fetch(:unrecorded, []).length
      puts "Value digests: #{current} current, #{changed.length} changed, " \
           "#{missing.length} missing value, #{unverifiable.length} unverifiable, #{unrecorded} unrecorded"
      unless changed.empty?
        puts "Values changed since the recorded digest (run apply to push, scaffold to re-record):"
        changed.each { |secret| puts "  #{secret.fetch('name')}" }
      end
      unverifiable.each { |secret| puts "  unverifiable (fingerprint key unavailable): #{secret.fetch('name')}" }
      # Changed digests and missing values are warnings — `check` is the CI
      # gate; doctor fails only for structural problems. Missing values are
      # already counted in the missing-value section above.
      unverifiable.empty? ? 0 : 1
    end

    def report_outcomes(outcomes, blockers: [])
      applied = outcomes.select { |outcome| outcome.status == "applied" }
      skipped = outcomes.select { |outcome| outcome.status == "skipped" }
      failed = outcomes.select { |outcome| outcome.status == "failed" }
      puts
      applied.each { |outcome| puts "applied #{outcome.item.source} #{outcome.item.repository} #{outcome.item.secret}" }
      blockers.each do |item|
        puts "blocked #{item.source} #{item.repository} #{item.secret}: #{item.detail}"
      end
      skipped.each { |outcome| puts "skipped #{outcome.item.repository} #{outcome.item.secret}: #{outcome.detail}" }
      failed.each { |outcome| puts "FAILED #{outcome.item.repository} #{outcome.item.secret}: #{outcome.detail}" }
      skipped_count = skipped.length + blockers.length
      puts "Applied #{applied.length} secret update#{'s' unless applied.length == 1}" \
           "#{"; #{skipped_count} blocked or skipped" unless skipped_count.zero?}" \
           "#{"; #{failed.length} failed" unless failed.empty?}."
      puts "No changes needed." if applied.empty? && skipped_count.zero? && failed.empty?
      blockers.empty? && skipped.empty? && failed.empty? ? 0 : 1
    end

    def print_items(items)
      if items.empty?
        puts "No managed targets selected."
        return
      end

      row_format = "%<action>-20s %<source>-22s %<repository>-34s %<context>-12s %<secret>-28s %<detail>s"
      puts format(row_format, action: "ACTION", source: "SOURCE", repository: "REPOSITORY",
                              context: "CONTEXT", secret: "SECRET", detail: "DETAIL")
      puts "-" * 132
      items.each do |item|
        puts format(row_format, action: item.action, source: item.source, repository: item.repository,
                                context: item.context, secret: item.secret, detail: item.detail)
      end

      puts
      puts items.group_by(&:action).sort.map { |action, grouped| "#{action}: #{grouped.length}" }.join(", ")
    end

    def help_text
      <<~HELP
        cred-align-flow #{VERSION}

        Usage:
          cred-align-flow doctor [options]
          cred-align-flow inventory [options]
          cred-align-flow pull [options]
          cred-align-flow plan [options]
          cred-align-flow diff [options]
          cred-align-flow check [options]
          cred-align-flow apply [options]
          cred-align-flow scaffold [options]
          cred-align-flow ui [options]

        Commands:
          doctor     Validate local configuration, values, and provider support
          inventory  Refresh repository and secret metadata
          pull       Alias for inventory
          plan       Show desired changes without writing remote secrets
          diff       Alias for plan
          check      Exit non-zero when expected secrets are missing or stale
          apply      Write missing or stale secrets
          scaffold   Add active secret entries for unmanaged env-file variables
          ui         Edit token defaults, presets, and repository rules in a local browser

        Common options:
          --config PATH     Configuration file
          --env-file PATH   Local secret-value environment file
          --state PATH      Inventory state file
          --port PORT       ui only: local server port (default: #{ConfigServer::DEFAULT_PORT})
          --verify          doctor only: probe provider authentication/connectivity

        Inventory/pull/plan/diff/check/apply options:
          --source PATTERN  Limit source names (supports glob patterns)

        Plan/diff/check/apply options:
          --repo PATTERN    Limit repository names (supports glob patterns)
          --secret PATTERN  Limit secret names (supports glob patterns)
          --context PATTERN Limit provider contexts (supports glob patterns)
          --offline         plan/check only: use the existing inventory
          --strict          check only: unexpected remote secrets fail
          --dry-run         apply only: refresh and report without writing
          --force           apply only: overwrite unverified or remotely newer secrets
          --yes             apply only: approve the freshly printed plan in noninteractive use

        Scaffold options:
          --only NAMES      Import only these comma-separated env names
          --target TARGET   Exact SOURCE|CONTEXT|OWNER/REPO tuple; repeat per target
          --ignore NAMES    Add env names to ignored_env_names and skip them
          --digests-only    Refresh value digests without importing new names

        Default files:
          Config: cred-align.local.yml, config/cred-align.local.yml, config/config.yml,
                  or ~/.config/cred-align-flow/config.yml
          Values: .env.local, config/secrets.env, or ~/.config/cred-align-flow/secrets.env
          State:  ~/.local/state/cred-align-flow/inventory.json
                  (relative state_file/rules_file resolve against the config file's directory)
      HELP
    end
  end
end
