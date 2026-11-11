# frozen_string_literal: true

# Shared recording helpers for the demo screencasts — the same technique
# as Knowledge-BA46-Flow's screencast-demo.mjs: CDP Page.startScreencast
# emits a PNG frame on repaint only (static dwells emit nothing, so
# chapter time derives from frame index / FPS, never wall clock), each
# frame must be acked, and the frames dir under tmp/ is the durable
# lossless intermediate that convert.rb feeds on.

require "fileutils"

module DemoRecording
  # Playback speed for the encoded master. Frames arrive on repaint, so a
  # lower rate stretches each captured frame over more video seconds —
  # CAF_DEMO_FPS=1 plays a take at half pace.
  FPS = (ENV["CAF_DEMO_FPS"] || "2").to_f

  module_function

  def frames_dir_for(name)
    File.expand_path("../../tmp/screencast-frames/#{name}", __dir__)
  end

  # Wipes frames_dir first so stale frames never bleed into a later
  # encode, then captures frames until stop_screencast is called.
  # Returns a counter Hash: { n: <frames>, chapters: [] }.
  def start_recording(page, frames_dir)
    FileUtils.rm_rf(frames_dir)
    FileUtils.mkdir_p(frames_dir)
    counter = { n: 0, chapters: [], timeline: [] }
    page.client.on("Page.screencastFrame") do |params|
      page.client.write("Page.screencastFrameAck", { sessionId: params["sessionId"] })
      path = File.join(frames_dir, format("f%04d.png", counter[:n]))
      counter[:n] += 1
      counter[:timeline] << {
        "file" => path,
        "ts" => params.dig("metadata", "timestamp") || Process.clock_gettime(Process::CLOCK_MONOTONIC)
      }
      File.binwrite(path, params["data"].unpack1("m"))
    end
    page.client.call("Page.startScreencast", { format: "png", everyNthFrame: 1 })
    counter
  end

  # Repaints emit frames only when pixels change, so a static hold
  # collapses to a single frame at a fixed-rate encode. Resample the
  # timeline at `fps`, repeating each frame until the next repaint, so
  # holds play at their true duration. Output frames are hardlinks into
  # a sibling dir. Returns { dir:, frames:, chapters: } with the chapter
  # markers remapped to the resampled indexes.
  def resample(frames_dir, counter, fps:, tail: 1.0)
    timeline = counter[:timeline]
    return nil if timeline.empty?

    out_dir = "#{frames_dir}-#{format('%g', fps)}fps"
    FileUtils.rm_rf(out_dir)
    FileUtils.mkdir_p(out_dir)
    t0 = timeline.first["ts"]
    t_end = timeline.last["ts"] + tail
    total = ((t_end - t0) * fps).ceil
    cursor = 0
    total.times do |index|
      t = t0 + (index / fps)
      cursor += 1 while cursor + 1 < timeline.length && timeline[cursor + 1]["ts"] <= t
      FileUtils.ln(timeline[cursor]["file"], File.join(out_dir, format("f%04d.png", index)))
    end
    chapters = counter[:chapters].map do |chapter|
      ts = timeline.dig(chapter["frame"], "ts") || t0
      { "title" => chapter["title"], "frame" => [((ts - t0) * fps).floor, total - 1].min }
    end
    { "dir" => out_dir, "frames" => total, "chapters" => chapters }
  end

  def stop_recording(page)
    page.client.call("Page.stopScreencast")
  rescue StandardError
    nil
  end

  def step(counter, title)
    counter[:chapters] << { "title" => title, "frame" => counter[:n] }
    warn "step: #{title}"
  end

  # chapters = [{title, frame}] markers; times derive from frame index /
  # fps so they land on the right video second even though capture wall
  # clock is irregular. First chapter always starts at 0.
  def encode_mp4(frames_dir, out, chapters = [], total_frames = 0, fps: FPS)
    FileUtils.mkdir_p(File.dirname(out))
    spans = chapter_spans(chapters, total_frames, fps)
    inputs = ["-framerate", fps.to_s, "-i", File.join(frames_dir, "f%04d.png")]
    if spans.any?
      meta_path = File.join(frames_dir, "chapters.ffmeta")
      File.write(meta_path, ffmetadata(spans))
      inputs += ["-i", meta_path, "-map", "0:v", "-map_chapters", "1"]
    end
    system(
      "ffmpeg", "-y", *inputs, "-c:v", "libx264", "-pix_fmt", "yuv420p",
      "-movflags", "+faststart", "-vf", "scale=1280:-2", out,
      exception: true
    )
  end

  def chapter_spans(chapters, total_frames, fps = FPS)
    spans = chapters.each_with_index.map do |chapter, index|
      start = [0, (chapter["frame"] / fps * 1000).round].max
      end_frame = chapters.dig(index + 1, "frame") || total_frames
      { "title" => chapter["title"], "start" => start, "end" => (end_frame / fps * 1000).round }
    end
    spans.reject { |span| span["end"] <= span["start"] }
  end

  def ffmetadata(spans)
    lines = [";FFMETADATA1"]
    spans.each_with_index do |span, index|
      lines += [
        "[CHAPTER]", "TIMEBASE=1/1000",
        "START=#{index.zero? ? 0 : span['start']}",
        "END=#{span['end']}",
        "title=#{span['title']}"
      ]
    end
    "#{lines.join("\n")}\n"
  end
end
