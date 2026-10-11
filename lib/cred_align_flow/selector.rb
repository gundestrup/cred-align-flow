# frozen_string_literal: true

module CredAlignFlow
  module Selector
    module_function

    # An `include` list disables discovery: those exact repositories are
    # the whole universe for that source.
    def discover?(repositories_config)
      Array(repositories_config["include"]).empty?
    end

    def repository_selected?(repo, config)
      return false if matches_any?(Array(config["exclude"]), repo)

      # A discovered repository the account cannot administer can never
      # receive secrets; explicit includes fail closed in the inventory.
      return false if !repo["explicit"] && repo["viewerCanAdminister"] == false

      include = Array(config["include"])
      return matches_any?(include, repo) if repo["explicit"]
      return false if repo["isArchived"] && !config["include_archived"]
      return false if repo["isFork"] && !config["include_forks"]
      return matches_any?(include, repo) unless include.empty?

      visibility_matches?(repo, config["visibility"])
    end

    def visibility_matches?(repo, wanted)
      actual = repo["visibility"].to_s.downcase
      actual = repo["isPrivate"] ? "private" : "public" if actual.empty?

      case wanted.to_s.downcase
      when "all"
        true
      when "private"
        %w[private internal].include?(actual)
      else
        actual == "public"
      end
    end

    def matches_any?(patterns, repo)
      names = [repo["name"], repo["nameWithOwner"], repo["name_with_owner"]].compact
      Array(patterns).any? do |pattern|
        names.any? { |name| File.fnmatch?(pattern.to_s, name.to_s, File::FNM_EXTGLOB) }
      end
    end
  end
end
