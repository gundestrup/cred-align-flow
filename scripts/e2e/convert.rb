#!/usr/bin/env ruby
# frozen_string_literal: true

# Convert an approved screencast into the animated web formats
# (apng, webp, avif, svg-wrapped raster) in docs/assets/demo/.
# Input may be the mp4 — or, for maximum fidelity, the durable PNG
# frames dir a screencast run leaves in tmp/screencast-frames/<name>
# (printed by the screencast scripts): frames feed img2webp/apng/avif
# without a lossy mp4 generation.
# Ruby port of Knowledge-BA46-Flow's scripts/e2e/screencast-convert.mjs.
#
# Usage:
#   ruby scripts/e2e/convert.rb <input.mp4|frames-dir>
#     [--scale 640] [--fps 2] [--crf 35] [--quality 80]
#     [--name base] [--out docs/assets/demo] [--svg-payload webp|avif]

require "fileutils"
require "json"
require "optparse"
require "tmpdir"

require_relative "recording"

opts = {
  scale: 640, crf: 35, quality: 80, preset: 4,
  out: File.expand_path("../../docs/assets/demo", __dir__),
  svg_payload: "webp"
}
parser = OptionParser.new do |o|
  o.banner = "usage: convert.rb <input.mp4|frames-dir> [options]"
  o.on("--scale PX", Integer) { |v| opts[:scale] = v }
  o.on("--fps RATE", Float) { |v| opts[:fps] = v }
  o.on("--crf N", Integer) { |v| opts[:crf] = v }
  o.on("--quality N", Integer) { |v| opts[:quality] = v }
  o.on("--preset N", Integer) { |v| opts[:preset] = v }
  o.on("--name NAME") { |v| opts[:name] = v }
  o.on("--out DIR") { |v| opts[:out] = File.expand_path(v) }
  o.on("--svg-payload FMT", %w[webp avif]) { |v| opts[:svg_payload] = v }
end
parser.parse!
src = ARGV[0] or abort parser.banner
abort "not found: #{src}" unless File.exist?(src)
is_dir = File.directory?(src)

def ffprobe_fps(file)
  out = IO.popen(
    ["ffprobe", "-v", "error", "-select_streams", "v:0",
     "-show_entries", "stream=r_frame_rate", "-of", "csv=p=0", file],
    &:read
  )
  num, den = out.strip.split("/").map(&:to_f)
  num&.positive? && den&.positive? ? num / den : DemoRecording::FPS
end

fps = opts[:fps] || (is_dir ? DemoRecording::FPS : ffprobe_fps(src))
name = opts[:name] || File.basename(src, ".*")
name = "screencast" if name == "frames"

# argv-form system() never reaches a shell; the allowlist keeps the
# executable set statically obvious to scanners and reviewers.
TOOLS = %w[ffmpeg img2webp].freeze

def run(bin, *)
  raise "unexpected demo tool: #{bin}" unless TOOLS.include?(bin)

  system(bin, *, exception: true)
rescue StandardError => e
  abort "#{bin} failed: #{e.message}"
end

# One directory of scaled PNG frames regardless of input kind.
scaled_dir = Dir.mktmpdir("caf-convert-scaled-")
if is_dir
  run("ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
      "-framerate", fps.to_s, "-i", File.join(src, "f%04d.png"),
      "-vf", "scale=#{opts[:scale]}:-2", File.join(scaled_dir, "f%04d.png"))
else
  run("ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
      "-i", src, "-vf", "scale=#{opts[:scale]}:-2",
      File.join(scaled_dir, "f%04d.png"))
end
frames = Dir.glob(File.join(scaled_dir, "f*.png"))
abort "no frames produced from #{src}" if frames.empty?

FileUtils.mkdir_p(opts[:out])
base = File.join(opts[:out], name)

# 1. APNG — lossless frames straight through ffmpeg's apng muxer.
run("ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
    "-framerate", fps.to_s, "-i", File.join(scaled_dir, "f%04d.png"),
    "-plays", "0", "-f", "apng", "#{base}.apng")

# 2. Animated WebP — img2webp (this ffmpeg has no libwebp). -d is the
#    per-frame delay in ms matching the frame rate.
run("img2webp", "-loop", "0", "-d", (1000 / fps).round.to_s,
    "-lossy", "-q", opts[:quality].to_s, "-m", "6",
    *frames, "-o", "#{base}.webp")

# 3. Animated AVIF — ffmpeg's avif muxer + SVT-AV1 sequence encode.
run("ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
    "-framerate", fps.to_s, "-i", File.join(scaled_dir, "f%04d.png"),
    "-c:v", "libsvtav1", "-crf", opts[:crf].to_s, "-preset", opts[:preset].to_s,
    "-pix_fmt", "yuv420p", "#{base}.avif")

# 4. SVG — self-contained wrapper around a raster animation (animates
#    inside <img>; needs no JS).
info = IO.popen(["webpinfo", "-summary", "#{base}.webp"], &:read)
width, height = (info.match(/Canvas size\s*:\s*(\d+) x (\d+)/)&.captures || %w[640 400]).map(&:to_i)
b64 = [File.binread("#{base}.#{opts[:svg_payload]}")].pack("m0")
File.write(
  "#{base}.svg",
  <<~SVG
    <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 #{width} #{height}" width="#{width}" height="#{height}" role="img" aria-label="#{name} screencast">
      <image xlink:href="data:image/#{opts[:svg_payload]};base64,#{b64}" width="#{width}" height="#{height}"/>
    </svg>
  SVG
)

puts "#{frames.length} frames @ #{fps}fps -> #{base}.{apng,webp,avif,svg}"
