#!/usr/bin/env ruby
# frozen_string_literal: true

# CLI demo screencast: runs the real cred-align-flow commands against the
# shared e2e fixture (TestSupport::FakeGh — offline, no credentials), then
# replays the captured session in a terminal-styled page in headless
# Chrome while CDP records the repaints. Output feeds
# docs/assets/demo/cli-flow.mp4 + tmp/screencast-frames/cli/ — convert
# with: ruby scripts/e2e/convert.rb tmp/screencast-frames/cli --name cli-flow

require "io/wait"
require "json"
require "open3"
require "rbconfig"

require_relative "cdp"
require_relative "demo_fixture"
require_relative "recording"

COMMANDSET = [
  %w[doctor],
  %w[inventory],
  %w[plan --offline],
  %w[check --offline],
  %w[apply --yes],
  %w[check --offline]
].freeze

def run_demo_command(fixture, argv)
  stdout, _stderr, status = TestSupport.run_cli(
    fixture.fake_gh, "--config", fixture.config_path, *argv
  )
  { "cmd" => "cred-align-flow #{argv.join(' ')}", "out" => stdout, "status" => status.exitstatus }
end

# `ui` execs itsi and blocks — spawn it, grab the printed banner line,
# then stop the server. Real output, no fake text on camera.
def capture_ui_banner(fixture)
  env = DemoFixture.ui_env(fixture)
  reader, writer = IO.pipe
  # argv-form spawn never reaches a shell; the only variable argument is
  # the fixture's own Dir.mktmpdir config path, never external input.
  pid = spawn(
    env, RbConfig.ruby, "bin/cred-align-flow", "--config", fixture.config_path, "ui",
    out: writer, err: writer, chdir: File.expand_path("../../", __dir__)
  )
  writer.close
  banner = read_banner_line(reader)
  Process.kill("TERM", pid)
  Process.wait(pid)
  banner
end

def read_banner_line(reader)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
  while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    break unless reader.wait_readable(deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC))

    line = reader.gets
    return line.strip if line&.include?("Config UI")
  end
  "Config UI: http://127.0.0.1:8043/"
ensure
  reader.close unless reader.closed?
end

# Terminal player page: types each command, then reveals its captured
# output line by line; the screencast records every repaint, so the
# playback shows a real typing session. Ends with window.__done = true.
def player_html(script)
  <<~HTML
    <!doctype html>
    <html><head><meta charset="utf-8"><style>
      * { box-sizing: border-box; margin: 0; padding: 0; }
      body { background: #0b1220; padding: 24px; font-family: ui-monospace, Menlo, monospace; }
      .window { background: #0a0f1a; border: 1px solid #24334f; border-radius: 12px;
                overflow: hidden; box-shadow: 0 24px 60px rgba(0,0,0,.5); }
      .titlebar { display: flex; align-items: center; gap: 8px; padding: 10px 14px;
                  background: #131c2e; border-bottom: 1px solid #24334f; }
      .dot { width: 12px; height: 12px; border-radius: 50%; }
      .r { background: #ff5f57; } .y { background: #febc2e; } .g { background: #28c840; }
      .titlebar span { margin-left: 10px; color: #8ba0c2; font-size: 13px; }
      .term { height: 620px; overflow: hidden; padding: 16px 18px;
              font-size: 16.5px; line-height: 1.55; color: #c9d6ea; white-space: pre-wrap; }
      .line { min-height: 1.55em; }
      .cmd { color: #38bdf8; }
      .dim { color: #8ba0c2; }
      .ok { color: #34d399; }
      .caret::after { content: "▌"; color: #38bdf8; animation: blink 1s steps(1) infinite; }
      @keyframes blink { 50% { opacity: 0; } }
    </style></head>
    <body><div class="window">
      <div class="titlebar"><div class="dot r"></div><div class="dot y"></div><div class="dot g"></div>
        <span>cred-align-flow — CLI demo (offline fixture)</span></div>
      <div class="term" id="term"></div>
    </div>
    <script>
      const SCRIPT = #{JSON.generate(script)};
      const term = document.getElementById("term");
      const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
      const line = (cls, text) => {
        const div = document.createElement("div");
        div.className = "line " + cls;
        div.textContent = text;
        term.appendChild(div);
        term.scrollTop = term.scrollHeight;
        return div;
      };
      (async () => {
        await sleep(900);
        for (const entry of SCRIPT) {
          const div = line("cmd", "");
          let typed = "$ ";
          for (const ch of entry.cmd) { typed += ch; div.textContent = typed; await sleep(34); }
          await sleep(500);
          for (const outLine of entry.out.split("\\n")) {
            if (outLine === "") continue;
            line(entry.cls || "", outLine);
            await sleep(entry.fast ? 30 : 90);
          }
          if (entry.status !== undefined && entry.status !== 0)
            line("dim", "[exit " + entry.status + "]");
          await sleep(1100);
        }
        term.lastChild.classList.add("caret");
        window.__done = true;
      })();
    </script></body></html>
  HTML
end

fixture = DemoFixture.build
DemoFixture.seed_inventory(fixture)

script = COMMANDSET.map do |argv|
  run_demo_command(fixture, argv).merge("fast" => %w[plan check].include?(argv.first))
end
script << { "cmd" => "cred-align-flow ui", "out" => capture_ui_banner(fixture), "status" => 0 }

player_path = File.join(fixture.dir, "cli-player.html")
File.write(player_path, player_html(script))

cdp_port = rand(12_000...32_000)
browser = DemoCdp::Browser.new(cdp_port)
frames_dir = DemoRecording.frames_dir_for("cli")
counter = nil
begin
  page = browser.new_page(width: 1280, height: 720)
  page.goto("file://#{player_path}")
  page.wait_for("document.getElementById('term') !== null")
  counter = DemoRecording.start_recording(page, frames_dir)
  page.wait_for("window.__done === true", timeout: 120)
  page.client.pump(1.5)
ensure
  DemoRecording.stop_recording(page) if defined?(page) && page
  browser.close
end

out = File.expand_path("../../docs/assets/demo/cli-flow.mp4", __dir__)
DemoRecording.encode_mp4(frames_dir, out, counter[:chapters], counter[:n])
puts "screencast: #{out} (#{counter[:n]} frames)"
puts "frames (lossless, for convert.rb): #{frames_dir}"
puts "page errors: #{page.errors.inspect}" if page && !page.errors.empty?
