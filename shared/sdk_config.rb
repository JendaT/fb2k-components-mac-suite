# SDK and Version Configuration for foobar2000 macOS Extensions
#
# This file provides centralized SDK path and version configuration.
# The SDK is NOT included in the repository - download from foobar2000.org
#
# Usage in generate_xcode_project.rb:
#   require_relative '../../../shared/sdk_config'
#   SDK_PATH = Fb2kSdk.path
#   VERSION = Fb2kVersions.get("simplaylist")  # Returns "1.1.0"
#
# Configure SDK via environment variable:
#   export FB2K_SDK_PATH="/path/to/SDK-2025-03-07"
#
# Or use the default relative path from extension directories.
#
# IMPORTANT: Versions are defined in shared/version.h - that is the source of truth.

module Fb2kSdk
  # Default SDK version (relative to project root)
  DEFAULT_SDK_DIR = "SDK-2025-03-07"

  def self.path
    # Check environment variable first
    if ENV['FB2K_SDK_PATH'] && !ENV['FB2K_SDK_PATH'].empty?
      return ENV['FB2K_SDK_PATH']
    end

    # Default: relative path from extension directory to project root
    # Extensions are at: PROJECT_ROOT/extensions/foo_*_mac/
    # So ../../ gets us to PROJECT_ROOT
    "../../#{DEFAULT_SDK_DIR}"
  end

  def self.absolute_path
    if ENV['FB2K_SDK_PATH'] && !ENV['FB2K_SDK_PATH'].empty?
      File.expand_path(ENV['FB2K_SDK_PATH'])
    else
      # Compute from this file's location
      project_root = File.expand_path('../../', __dir__)
      File.join(project_root, DEFAULT_SDK_DIR)
    end
  end

  def self.validate!
    sdk_path = absolute_path
    unless File.directory?(sdk_path)
      puts "ERROR: SDK not found at: #{sdk_path}"
      puts ""
      puts "Download the foobar2000 SDK from foobar2000.org and extract to:"
      puts "  #{sdk_path}"
      puts ""
      puts "Or set the FB2K_SDK_PATH environment variable:"
      puts "  export FB2K_SDK_PATH=\"/path/to/your/SDK\""
      exit 1
    end

    # Check for built SDK libraries
    sdk_lib = File.join(sdk_path, "foobar2000/SDK/build/Release/libfoobar2000_SDK.a")
    unless File.exist?(sdk_lib)
      puts "WARNING: SDK libraries not built. Run the SDK build first:"
      puts "  cd #{sdk_path}"
      puts "  # Build SDK projects in Xcode"
    end

    sdk_path
  end
end

# Version configuration - reads from shared/version.h
module Fb2kVersions
  # Map component names to their version constant names
  VERSION_MAP = {
    "simplaylist" => "SIMPLAYLIST_VERSION",
    "plorg" => "PLORG_VERSION",
    "waveform" => "WAVEFORM_VERSION",
    "wave_seekbar" => "WAVEFORM_VERSION",
    "scrobble" => "SCROBBLE_VERSION"
  }

  # Parse version.h and extract versions
  def self.parse_version_file
    version_file = File.join(File.dirname(__FILE__), "version.h")
    unless File.exist?(version_file)
      puts "ERROR: shared/version.h not found at: #{version_file}"
      exit 1
    end

    versions = {}
    File.readlines(version_file).each do |line|
      # Match: #define SIMPLAYLIST_VERSION "1.1.0"
      if line =~ /#define\s+(\w+_VERSION)\s+"([^"]+)"/
        versions[$1] = $2
      end
    end
    versions
  end

  # Get version for a component
  # Usage: Fb2kVersions.get("simplaylist") => "1.1.0"
  def self.get(component)
    const_name = VERSION_MAP[component.downcase]
    unless const_name
      puts "ERROR: Unknown component '#{component}'"
      puts "Valid components: #{VERSION_MAP.keys.join(', ')}"
      exit 1
    end

    versions = parse_version_file
    version = versions[const_name]
    unless version
      puts "ERROR: Version constant #{const_name} not found in version.h"
      exit 1
    end

    version
  end

  # Get version as integer (for CURRENT_PROJECT_VERSION)
  # "1.1.0" => 2 (second release)
  # "1.0.0" => 1 (first release)
  def self.get_build_number(component)
    version = get(component)
    parts = version.split('.')
    major = parts[0].to_i
    minor = parts[1].to_i
    patch = parts[2].to_i

    # Simple formula: major * 100 + minor * 10 + patch + 1
    # 1.0.0 => 1, 1.1.0 => 2, 1.2.0 => 3, 2.0.0 => 11
    (major - 1) * 10 + minor + 1
  end
end
