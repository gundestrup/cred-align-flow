#!/usr/bin/env ruby
# frozen_string_literal: true

# Config UI demo screencast: builds the shared e2e fixture, starts the
# real `cred-align-flow ui` server (Itsi, loopback-only, fake `gh`), and
# drives a tour in headless Chrome while CDP records the repaints.
# Output feeds docs/assets/demo/ui-flow.mp4 + tmp/screencast-frames/ui/ —
# convert with: ruby scripts/e2e/convert.rb tmp/screencast-frames/ui --name ui-flow

require "json"
require "rbconfig"
require "socket"

require_relative "cdp"
require_relative "demo_fixture"
require_relative "recording"

# Small tour vocabulary on top of the Page: pump() replaces sleep so
# screencast frames keep flowing during every pause.
def pause(client, seconds)
  client.pump(seconds)
end

# evaluate("document.querySelector(\".card\")?.click()")
def js_click(page, selector)
  page.evaluate("document.querySelector(#{selector.to_json})?.click()")
end

# evaluate("(() => { const el = document.querySelector(\".card\"); if (el) el.open = true; return !!el; })()")
def open_details(page, selector)
  page.evaluate("(() => { const el = document.querySelector(#{selector.to_json}); if (el) el.open = true; return !!el; })()")
end

# evaluate("(() => { const el = document.querySelector(\"select\"); el.value = \"include\"; el.dispatchEvent(...); })()")
def set_select(page, selector, value)
  page.evaluate(<<~JS)
    (() => {
      const el = document.querySelector(#{selector.to_json});
      if (!el) return false;
      el.value = #{value.to_json};
      el.dispatchEvent(new Event("change", { bubbles: true }));
      return true;
    })()
  JS
end

# evaluate("(() => { const el = document.querySelector(\"input\"); el.value = \"alpha\"; el.dispatchEvent(...); })()")
def set_input(page, selector, value)
  page.evaluate(<<~JS)
    (() => {
      const el = document.querySelector(#{selector.to_json});
      el.value = #{value.to_json};
      el.dispatchEvent(new Event("input", { bubbles: true }));
      return true;
    })()
  JS
end

fixture = DemoFixture.build
DemoFixture.seed_inventory(fixture)

port = rand(20_000...40_000)
server = spawn(
  DemoFixture.ui_env(fixture),
  RbConfig.ruby, "bin/cred-align-flow", "--config", fixture.config_path,
  "ui", "--port", port.to_s,
  chdir: File.expand_path("../../", __dir__),
  in: "/dev/null", out: "/dev/null", err: "/dev/null"
)
Process.detach(server)
base_url = "http://127.0.0.1:#{port}"
DemoCdp.wait_http("#{base_url}/api/data", timeout: 30)

browser = DemoCdp::Browser.new(rand(12_000...32_000))
page = nil
counter = nil
frames_dir = DemoRecording.frames_dir_for("ui")
begin
  page = browser.new_page(width: 1440, height: 900)
  page.goto("#{base_url}/")
  page.wait_for('document.getElementById("repositories").children.length > 0', timeout: 20)
  counter = DemoRecording.start_recording(page, frames_dir)
  client = page.client

  DemoRecording.step(counter, "repositories")
  pause(client, 2.5)
  open_details(page, ".repo-card details.repo-rule-list")
  pause(client, 1.4)

  DemoRecording.step(counter, "repo-rule")
  # .assignment-row selects are the per-token rule controls; the preset
  # picker in p.small also lives inside the details and comes first.
  set_select(page, ".repo-card details.repo-rule-list .assignment-row select:not([disabled])", "include")
  page.wait_for('!document.getElementById("save").disabled')
  pause(client, 1.4)

  DemoRecording.step(counter, "filter")
  set_input(page, "#repo-filter", "alpha")
  pause(client, 1.2)
  set_input(page, "#repo-filter", "")
  pause(client, 0.8)

  DemoRecording.step(counter, "tokens")
  js_click(page, "label[for=tab-tokens]")
  pause(client, 1.6)
  open_details(page, "#tokens details")
  pause(client, 1.6)

  DemoRecording.step(counter, "presets")
  js_click(page, "label[for=tab-presets]")
  pause(client, 1.8)

  DemoRecording.step(counter, "apply-preset")
  js_click(page, "label[for=tab-repositories]")
  pause(client, 0.8)
  # Second repo card (beta-api): open its rule list and stamp the
  # seeded "sonar-only" repository preset.
  open_details(page, ".repo-card:nth-of-type(2) details.repo-rule-list, section .repo-card ~ * details.repo-rule-list")
  # evaluate("(() => { const card = [...document.querySelectorAll(\".repo-card\")].find(...); ... })()")
  page.evaluate(<<~JS)
    (() => {
      const card = [...document.querySelectorAll(".repo-card")].find((c) =>
        c.querySelector("h4")?.textContent.includes("beta-api"));
      if (!card) return "no-card";
      card.querySelector("details.repo-rule-list").open = true;
      const select = card.querySelector("p.small select");
      if (!select) return "no-select";
      select.value = "sonar-only";
      select.dispatchEvent(new Event("change", { bubbles: true }));
      return "applied";
    })()
  JS
  page.wait_for('!document.getElementById("save").disabled')
  pause(client, 1.6)

  # Save before refresh: refreshing with a dirty draft triggers the
  # app's window.confirm discard guard, which headless CDP declines.
  DemoRecording.step(counter, "save")
  js_click(page, "#save")
  page.wait_for('document.getElementById("message").textContent.match(/saved/i)', timeout: 30)
  pause(client, 1.8)

  DemoRecording.step(counter, "refresh")
  js_click(page, "#refresh-inventory")
  page.wait_for('document.getElementById("message").textContent.includes("refreshed")', timeout: 30)
  pause(client, 2.0)
ensure
  DemoRecording.stop_recording(page) if page
  browser.close
  Process.kill("TERM", server)
end

out = File.expand_path("../../docs/assets/demo/ui-flow.mp4", __dir__)
# UI repaints are sparse between interactions — resample at the real
# timestamps so each hold plays for its true on-screen duration.
resampled = DemoRecording.resample(frames_dir, counter, fps: 9, tail: 2.0)
source_dir = resampled ? resampled["dir"] : frames_dir
chapters = resampled ? resampled["chapters"] : counter[:chapters]
total = resampled ? resampled["frames"] : counter[:n]
DemoRecording.encode_mp4(source_dir, out, chapters, total, fps: resampled ? 9 : DemoRecording::FPS)
puts "screencast: #{out} (#{counter[:n]} captured frames, #{total} resampled)"
puts "frames (lossless, for convert.rb): #{source_dir}"
puts "page errors: #{page.errors.inspect}" unless page.errors.empty?
puts "fixture: #{fixture.dir}"
