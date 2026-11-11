# frozen_string_literal: true

# Minimal Chrome DevTools Protocol driver for the demo screencasts —
# the Ruby port of Knowledge-BA46-Flow's scripts/e2e/lib/browser.mjs.
# Uses the system Chrome/Chromium and a hand-rolled RFC 6455 client over
# a plain loopback socket: no gems, no remote-debugging dependency.
#
# Only what the screencast scripts need is implemented: /json target
# management, Runtime.evaluate, Page.navigate, Page.startScreencast, and
# event dispatch with reentrant-safe request/response matching.

require "fileutils"
require "io/wait"
require "json"
require "net/http"
require "securerandom"
require "socket"
require "tmpdir"
require "uri"

module DemoCdp
  CHROME_CANDIDATES = [
    ENV.fetch("CAF_DEMO_CHROME", nil),
    ENV.fetch("CHROME_PATH", nil),
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "google-chrome",
    "google-chrome-stable",
    "chromium",
    "chromium-browser"
  ].compact.freeze

  def self.find_chrome
    CHROME_CANDIDATES.find do |candidate|
      candidate.include?("/") ? File.executable?(candidate) : which?(candidate)
    end
  end

  def self.which?(name)
    ENV.fetch("PATH", "").split(":").any? { |dir| File.exist?(File.join(dir, name)) }
  end

  def self.wait_http(url, timeout: 20)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    begin
      response = Net::HTTP.get_response(URI(url))
      return JSON.parse(response.body) if response.is_a?(Net::HTTPSuccess)

      raise "HTTP #{response.code}"
    rescue StandardError => e
      raise "timeout waiting for #{url}: #{e.message}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.15
      retry
    end
  end

  # RFC 6455 client over TCPSocket: masked text frames out, frames in
  # (masked or not), fragmented messages reassembled, pings answered.
  # No extension negotiation, so payloads arrive uncompressed.
  class WebSocket
    attr_reader :io

    def initialize(url)
      uri = URI(url)
      @io = TCPSocket.new(uri.host, uri.port)
      handshake(uri)
      @fragments = []
    end

    def send_text(payload)
      @io.write(frame_header(0x81, payload.bytesize) + mask_payload(payload))
    end

    # Returns the next complete text message, or nil on close.
    def recv
      loop do
        header = read_exact(2) or return nil
        fin = header.getbyte(0).anybits?(0x80)
        opcode = header.getbyte(0) & 0x0f
        payload = read_payload(header.getbyte(1))
        case opcode
        when 0x8 then return nil
        when 0x9 then send_pong(payload)
        when 0x0, 0x1, 0x2
          @fragments << payload
          return @fragments.join.tap { @fragments.clear } if fin
        end
      end
    end

    def close
      @io.close unless @io.closed?
    end

    private

    def handshake(uri)
      key = [SecureRandom.random_bytes(16)].pack("m0")
      @io.write(
        "GET #{uri.path} HTTP/1.1\r\nHost: #{uri.host}:#{uri.port}\r\n" \
        "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
        "Sec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
      )
      response = +""
      while (chunk = read_exact(1))
        response << chunk
        break if response.end_with?("\r\n\r\n")
      end
      raise "WebSocket upgrade failed: #{response.lines.first}" unless response.start_with?("HTTP/1.1 101")
    end

    def frame_header(opcode, bytesize)
      if bytesize < 126
        [opcode, 0x80 | bytesize].pack("C2")
      elsif bytesize < 65_536
        [opcode, 0x80 | 126, bytesize].pack("C2n")
      else
        [opcode, 0x80 | 127, bytesize].pack("C2Q>")
      end
    end

    def mask_payload(payload)
      mask = SecureRandom.random_bytes(4)
      mask + payload.b.each_byte.with_index.map { |b, i| b ^ mask.getbyte(i % 4) }.pack("C*")
    end

    def read_payload(flags)
      masked = flags.anybits?(0x80)
      length = flags & 0x7f
      length = read_exact(2).unpack1("n") if length == 126
      length = read_exact(8).unpack1("Q>") if length == 127
      mask = masked ? read_exact(4) : nil
      payload = read_exact(length) || ""
      return payload unless mask

      payload.each_byte.with_index.map { |b, i| b ^ mask.getbyte(i % 4) }.pack("C*")
    end

    def send_pong(payload)
      @io.write(frame_header(0x8a, payload.bytesize) + mask_payload(payload))
    end

    def read_exact(count)
      data = +""
      while data.bytesize < count
        chunk = @io.read(count - data.bytesize)
        break if chunk.nil? || chunk.empty?

        data << chunk
      end
      data.empty? && count.positive? ? nil : data
    rescue IOError, SystemCallError
      nil
    end
  end

  # Thin JSON-RPC wrapper over one DevTools WebSocket session. `call`
  # pumps the socket until its own response id resolves, buffering any
  # other pending responses and dispatching events to registered
  # handlers — so `write` (fire-and-forget, used for screencast acks)
  # is safe inside handlers without recursion.
  class Client
    def initialize(ws_url)
      @ws = WebSocket.new(ws_url)
      @next_id = 0
      @pending = {}
      @responses = {}
      @handlers = Hash.new { |hash, key| hash[key] = [] }
    end

    def on(method, &block)
      @handlers[method] << block
    end

    def write(method, params = {})
      id = (@next_id += 1)
      @ws.send_text(JSON.generate(id: id, method: method, params: params))
      id
    end

    def call(method, params = {})
      id = write(method, params)
      @pending[id] = true
      pump_until { @responses.key?(id) }
      result = @responses.delete(id)
      raise "CDP #{method}: #{result.dig('error', 'message')}" if result["error"]

      result.fetch("result", {})
    end

    # Pumps incoming messages for `seconds`, dispatching events — the
    # pause the tour scripts use so screencast frames keep flowing.
    def pump(seconds)
      pump_until(deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds) { false }
    end

    def close
      @ws.close
    end

    private

    def pump_until(deadline: nil, &condition)
      until condition.call
        break if deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        timeout = deadline ? [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max : nil
        break unless @ws.io.wait_readable(timeout)

        message = recv_message or raise "CDP socket closed"
        dispatch(message)
      end
    end

    def recv_message
      text = @ws.recv
      text.nil? ? nil : JSON.parse(text)
    end

    def dispatch(message)
      if (id = message["id"])
        @responses[id] = message if @pending.delete(id)
        return
      end
      @handlers[message["method"]].each { |handler| handler.call(message["params"] || {}) }
    end
  end

  # Page wraps one Chrome tab target: eval with awaitPromise,
  # wait_for polling, and error capture for diagnostics.
  class Page
    attr_reader :client, :errors

    def initialize(client)
      @client = client
      @errors = []
      client.on("Runtime.exceptionThrown") do |params|
        detail = params["exceptionDetails"] || {}
        url = detail["url"].to_s
        next if url.start_with?("chrome-extension://")

        @errors << "exception: #{detail['text']} #{detail.dig('exception', 'description')}"
      end
    end

    def evaluate(expression)
      result = client.call("Runtime.evaluate", { expression: expression, awaitPromise: true, returnByValue: true })
      if (detail = result["exceptionDetails"])
        raise "page eval failed: #{detail.dig('exception', 'description') || detail['text']} — in: #{expression[0, 120]}"
      end

      result.dig("result", "value")
    end

    def wait_for(expression, timeout: 10)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until evaluate(expression)
        raise "timeout waiting for: #{expression[0, 80]}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        client.pump(0.1)
      end
    end

    def goto(url)
      client.call("Page.navigate", { url: url })
    end
  end

  # Launches headless Chrome with CDP on an ephemeral port and hands out
  # Page objects; close kills the process and removes the temp profile.
  class Browser
    def initialize(cdp_port)
      chrome = DemoCdp.find_chrome or raise "no Chrome/Chromium found (set CAF_DEMO_CHROME)"
      @profile = Dir.mktmpdir("caf-demo-chrome-")
      @pid = spawn(
        chrome, "--headless=new", "--remote-debugging-port=#{cdp_port}",
        "--user-data-dir=#{@profile}", "--no-first-run", "--disable-extensions",
        "--disable-component-update", "--mute-audio", "about:blank",
        in: "/dev/null", out: "/dev/null", err: "/dev/null"
      )
      Process.detach(@pid)
      @base = "http://127.0.0.1:#{cdp_port}"
      DemoCdp.wait_http("#{@base}/json/version")
    end

    def new_page(width: 1440, height: 900)
      uri = URI("#{@base}/json/new?about:blank")
      target = JSON.parse(Net::HTTP.start(uri.host, uri.port) { |http| http.send_request("PUT", uri.request_uri).body })
      client = Client.new(target.fetch("webSocketDebuggerUrl"))
      %w[Runtime.enable Page.enable Log.enable Network.enable].each { |m| client.call(m) }
      client.call(
        "Emulation.setDeviceMetricsOverride",
        { width: width, height: height, deviceScaleFactor: 1, mobile: false }
      )
      Page.new(client)
    end

    def close
      Process.kill("SIGKILL", @pid)
    rescue Errno::ESRCH
      nil
    ensure
      remove_profile
    end

    private

    # Helper processes can still be writing the profile on their way
    # out; retry the cleanup briefly instead of failing the teardown.
    def remove_profile
      removed = 5.times.any? do |attempt|
        sleep 0.3 if attempt.positive?
        profile_gone?
      end
      raise "could not remove Chrome profile #{@profile}" unless removed
    end

    def profile_gone?
      FileUtils.remove_entry(@profile)
      true
    rescue Errno::ENOTEMPTY
      false
    rescue Errno::ENOENT
      true
    end
  end
end
