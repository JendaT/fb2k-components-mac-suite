#!/usr/bin/env ruby
# Generate compile_commands.json for CLion IDE support
#
# Usage:
#   ruby Scripts/generate_compile_commands.rb
#
# Generates a compile_commands.json at the repo root covering all
# components in extensions/. No build required.

require 'json'

SCRIPT_DIR = File.expand_path(File.dirname(__FILE__))
REPO_ROOT = File.expand_path('..', SCRIPT_DIR)

# Resolve system SDK path
SYSTEM_SDK = `xcrun --show-sdk-path`.strip
if SYSTEM_SDK.empty?
  abort "Error: Failed to resolve system SDK path via xcrun"
end

# Resolve foobar2000 SDK path
FB2K_SDK = if ENV['FB2K_SDK_PATH'] && !ENV['FB2K_SDK_PATH'].empty?
             File.expand_path(ENV['FB2K_SDK_PATH'])
           else
             File.join(REPO_ROOT, "SDK-2025-03-07")
           end

unless File.directory?(FB2K_SDK)
  abort "Error: foobar2000 SDK not found at: #{FB2K_SDK}\n" \
        "Set FB2K_SDK_PATH or place SDK at the expected location."
end

# Discover all component directories
component_dirs = Dir.glob(File.join(REPO_ROOT, "extensions", "foo_jl_*"))
                    .select { |d| File.directory?(d) }
                    .sort

entries = []

component_dirs.each do |component_dir|
  src_dir = File.join(component_dir, "src")
  next unless File.directory?(src_dir)

  prefix_pch = File.join(src_dir, "Prefix.pch")
  has_prefix = File.exist?(prefix_pch)

  # Discover source subdirectories dynamically
  source_subdirs = Dir.children(src_dir)
                      .map { |d| File.join(src_dir, d) }
                      .select { |d| File.directory?(d) }

  source_files = source_subdirs.flat_map do |subdir|
    Dir.glob(File.join(subdir, "*.{cpp,mm,h}"))
  end

  next if source_files.empty?

  source_files.sort.each do |source_file|
    ext = File.extname(source_file)
    arguments = ["clang++"]

    if ext == ".mm" || ext == ".h"
      arguments += ["-x", "objective-c++", "-std=gnu++17", "-fobjc-arc"]
    else
      arguments += ["-std=gnu++17"]
    end

    arguments += [
      "-mmacosx-version-min=12.0",
      "-DFOOBAR2000_HAVE_CFG_VAR_LEGACY=1",
      "-isysroot", SYSTEM_SDK,
      "-I#{FB2K_SDK}",
      "-I#{File.join(FB2K_SDK, 'foobar2000')}",
      "-I#{File.join(FB2K_SDK, 'pfc')}",
    ]

    if has_prefix
      arguments += ["-include", prefix_pch]
    end

    arguments += ["-c", source_file]

    entries << {
      "directory" => component_dir,
      "file" => source_file,
      "arguments" => arguments
    }
  end

  puts "  #{File.basename(component_dir)}: #{source_files.size} files"
end

# Include shared/ files
shared_dir = File.join(REPO_ROOT, "shared")
shared_files = Dir.glob(File.join(shared_dir, "*.{h,mm,cpp}")).sort
shared_files.each do |source_file|
  ext = File.extname(source_file)
  arguments = ["clang++"]

  if ext == ".mm" || ext == ".h"
    arguments += ["-x", "objective-c++", "-std=gnu++17", "-fobjc-arc"]
  else
    arguments += ["-std=gnu++17"]
  end

  arguments += [
    "-mmacosx-version-min=12.0",
    "-DFOOBAR2000_HAVE_CFG_VAR_LEGACY=1",
    "-isysroot", SYSTEM_SDK,
    "-I#{FB2K_SDK}",
    "-I#{File.join(FB2K_SDK, 'foobar2000')}",
    "-I#{File.join(FB2K_SDK, 'pfc')}",
    "-c", source_file
  ]

  entries << {
    "directory" => REPO_ROOT,
    "file" => source_file,
    "arguments" => arguments
  }
end
puts "  shared: #{shared_files.size} files" unless shared_files.empty?

output_path = File.join(REPO_ROOT, "compile_commands.json")
File.write(output_path, JSON.pretty_generate(entries) + "\n")

puts ""
puts "Generated: #{output_path}"
puts "Total entries: #{entries.size}"
