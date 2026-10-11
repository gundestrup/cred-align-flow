# frozen_string_literal: true

require_relative "../cred_align_flow"

editor = CredAlignFlow::ConfigEditor.new(
  config_path: ENV.fetch("CRED_ALIGN_FLOW_CONFIG_PATH"),
  env_path: ENV.fetch("CRED_ALIGN_FLOW_ENV_PATH"),
  state_path: ENV.fetch("CRED_ALIGN_FLOW_STATE_PATH")
)

run CredAlignFlow::ConfigRackApp.new(
  editor: editor,
  port: ENV.fetch("CRED_ALIGN_FLOW_UI_PORT", "8043")
)
