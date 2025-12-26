# SDK Configuration for foobar2000 macOS Extensions
#
# This file provides a centralized SDK path configuration.
# The SDK is NOT included in the repository - download from foobar2000.org
#
# Usage in generate_xcode_project.rb:
#   require_relative '../../../../shared/sdk_config'
#   SDK_PATH = Fb2kSdk.path
#
# Configure via environment variable:
#   export FB2K_SDK_PATH="/path/to/SDK-2025-03-07"
#
# Or use the default relative path from extension directories.

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
