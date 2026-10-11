# frozen_string_literal: true

require "fileutils"
require "tempfile"

module CredAlignFlow
  # Shared persistence primitives: replacement files are written to a
  # private temp file, fsynced, and atomically renamed; cross-process
  # read-modify-write coordination uses a stable sibling lockfile so the
  # replaced inode is never the lock target.
  module AtomicFile
    module_function

    def write(path, content, mode: 0o600, error_class: StateError)
      directory = File.dirname(path)
      directory_existed = File.directory?(directory)
      FileUtils.mkdir_p(directory)
      FileUtils.chmod(0o700, directory) unless directory_existed
      Tempfile.create([".#{File.basename(path)}-", ".tmp"], directory, mode: 0o600) do |file|
        file.write(content)
        file.flush
        file.fsync
        FileUtils.chmod(mode, file.path)
        File.rename(file.path, path)
      end
      FileUtils.chmod(mode, path)
      begin
        File.open(directory, File::RDONLY, &:fsync)
      rescue Errno::EINVAL, Errno::ENOTSUP
        nil
      end
    rescue SystemCallError => e
      raise error_class, "could not write #{path}: #{e.message}"
    end

    def with_lock(path, &block)
      directory = File.dirname(path)
      directory_existed = File.directory?(directory)
      FileUtils.mkdir_p(directory)
      FileUtils.chmod(0o700, directory) unless directory_existed
      lock_path = File.join(directory, ".cred-align-flow-#{File.basename(path)}.lock")
      raise StateError, "lock path must not be a symlink: #{lock_path}" if File.symlink?(lock_path)

      flags = File::RDWR | File::CREAT
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      File.open(lock_path, flags, 0o600) do |file|
        FileUtils.chmod(0o600, lock_path)
        file.flock(File::LOCK_EX)
        block.call
      end
    end
  end
end
