# foobar2000 macOS - Build Automation

## Overview

This document covers automating the build process for foobar2000 macOS components, including Xcode project generation, library linking, and build scripts.

## 1. Xcode Project Generation

### 1.1 Why Generate Projects?

- Avoid manual Xcode project maintenance
- Reproducible builds
- Easy SDK path configuration
- Automatic file discovery

### 1.2 Ruby Script Pattern

The recommended approach uses a Ruby script to generate `project.pbxproj`:

```ruby
#!/usr/bin/env ruby
# generate_xcode_project.rb

require 'securerandom'
require 'fileutils'

# Configuration
PROJECT_NAME = "foo_mycomponent"
BUNDLE_ID = "com.yourname.foo_mycomponent"
SDK_PATH = "../SDK-2025-03-07"
DEPLOYMENT_TARGET = "10.13"

# UUID generation
def uuid
  SecureRandom.uuid.gsub('-', '').upcase[0, 24]
end

# Collect source files
def collect_sources(dir, extensions)
  files = []
  Dir.glob("#{dir}/**/*").each do |path|
    ext = File.extname(path).downcase
    if extensions.include?(ext)
      files << {
        path: path,
        name: File.basename(path),
        uuid: uuid,
        build_uuid: uuid
      }
    end
  end
  files
end

# Main generation
sources = collect_sources("src", [".cpp", ".mm", ".m", ".c"])
headers = collect_sources("src", [".h", ".hpp"])
resources = collect_sources("Resources", [".xib", ".plist", ".xcassets"])

# Generate project.pbxproj
# ... (full implementation follows)
```

### 1.3 Project Structure Generation

```ruby
# Create project directory structure
def create_project_structure
  FileUtils.mkdir_p("#{PROJECT_NAME}.xcodeproj")
end

# PBXProject section
def generate_project_section
  <<~PBXPROJ
    /* Begin PBXProject section */
    #{@project_uuid} /* Project object */ = {
      isa = PBXProject;
      buildConfigurationList = #{@config_list_uuid};
      compatibilityVersion = "Xcode 14.0";
      mainGroup = #{@main_group_uuid};
      productRefGroup = #{@products_group_uuid};
      projectDirPath = "";
      projectRoot = "";
      targets = (
        #{@target_uuid} /* #{PROJECT_NAME} */,
      );
    };
    /* End PBXProject section */
  PBXPROJ
end
```

## 2. Library Search Paths

### 2.1 Required SDK Libraries

| Library | Path | Purpose |
|---------|------|---------|
| `libfoobar2000_SDK.a` | `SDK/build/Release/` | Core SDK |
| `libfoobar2000_SDK_helpers.a` | `helpers/build/Release/` | Helper utilities |
| `libfoobar2000_component_client.a` | `foobar2000_component_client/build/Release/` | Component loader |
| `libshared.a` | `shared/build/Release/` | Shared utilities |
| `libpfc-Mac.a` | `pfc/build/Release/` | Platform foundation |

### 2.2 Library Search Path Configuration

```ruby
def library_search_paths
  base = "$(PROJECT_DIR)/#{SDK_PATH}/foobar2000"
  [
    "$(inherited)",
    "\"#{base}/SDK/build/Release\"",
    "\"#{base}/helpers/build/Release\"",
    "\"#{base}/foobar2000_component_client/build/Release\"",
    "\"#{base}/shared/build/Release\"",
    "\"$(PROJECT_DIR)/#{SDK_PATH}/pfc/build/Release\""
  ].join(",\n\t\t\t\t\t")
end
```

### 2.3 Library Linking Script

```ruby
#!/usr/bin/env ruby
# update_project_libraries.rb

LIBRARIES = [
  { name: "libfoobar2000_SDK.a", path: "SDK/build/Release" },
  { name: "libfoobar2000_SDK_helpers.a", path: "helpers/build/Release" },
  { name: "libfoobar2000_component_client.a", path: "foobar2000_component_client/build/Release" },
  { name: "libshared.a", path: "shared/build/Release" },
  { name: "libpfc-Mac.a", path: "../pfc/build/Release" }
]

def generate_library_references
  LIBRARIES.map do |lib|
    full_path = "#{SDK_PATH}/foobar2000/#{lib[:path]}/#{lib[:name]}"
    <<~REF
      #{uuid} /* #{lib[:name]} */ = {
        isa = PBXFileReference;
        lastKnownFileType = archive.ar;
        name = "#{lib[:name]}";
        path = "#{full_path}";
        sourceTree = "<group>";
      };
    REF
  end.join("\n")
end
```

## 3. Header Search Paths

### 3.1 Required Paths

```ruby
def header_search_paths
  [
    "$(inherited)",
    "\"$(PROJECT_DIR)/#{SDK_PATH}\"",
    "\"$(PROJECT_DIR)/#{SDK_PATH}/foobar2000\"",
    "\"$(PROJECT_DIR)/#{SDK_PATH}/pfc\""
  ].join(",\n\t\t\t\t\t")
end
```

### 3.2 Build Settings Section

```ruby
def generate_build_settings(config)
  <<~SETTINGS
    #{config[:uuid]} /* #{config[:name]} */ = {
      isa = XCBuildConfiguration;
      buildSettings = {
        ALWAYS_SEARCH_USER_PATHS = NO;
        CLANG_CXX_LANGUAGE_STANDARD = "gnu++17";
        CLANG_ENABLE_MODULES = YES;
        CLANG_ENABLE_OBJC_ARC = YES;
        CODE_SIGN_STYLE = Automatic;
        COMBINE_HIDPI_IMAGES = YES;
        DEAD_CODE_STRIPPING = YES;
        GCC_OPTIMIZATION_LEVEL = #{config[:name] == "Release" ? "s" : "0"};
        HEADER_SEARCH_PATHS = (
          #{header_search_paths}
        );
        INFOPLIST_FILE = Resources/Info.plist;
        LIBRARY_SEARCH_PATHS = (
          #{library_search_paths}
        );
        MACOSX_DEPLOYMENT_TARGET = #{DEPLOYMENT_TARGET};
        OTHER_LDFLAGS = (
          "-lfoobar2000_SDK",
          "-lfoobar2000_SDK_helpers",
          "-lfoobar2000_component_client",
          "-lshared",
          "-lpfc-Mac"
        );
        PRODUCT_BUNDLE_IDENTIFIER = "#{BUNDLE_ID}";
        PRODUCT_NAME = "$(TARGET_NAME)";
        SKIP_INSTALL = YES;
        WRAPPER_EXTENSION = component;
      };
      name = #{config[:name]};
    };
  SETTINGS
end
```

## 4. Build Phases

### 4.1 Sources Phase

```ruby
def generate_sources_build_phase
  source_refs = @sources.map { |s| "#{s[:build_uuid]} /* #{s[:name]} */," }.join("\n\t\t\t\t")

  <<~PHASE
    #{@sources_phase_uuid} /* Sources */ = {
      isa = PBXSourcesBuildPhase;
      buildActionMask = 2147483647;
      files = (
        #{source_refs}
      );
      runOnlyForDeploymentPostprocessing = 0;
    };
  PHASE
end
```

### 4.2 Frameworks Phase

```ruby
def generate_frameworks_build_phase
  <<~PHASE
    #{@frameworks_phase_uuid} /* Frameworks */ = {
      isa = PBXFrameworksBuildPhase;
      buildActionMask = 2147483647;
      files = (
        #{@cocoa_framework_build_uuid} /* Cocoa.framework */,
        #{@sdk_lib_build_uuid} /* libfoobar2000_SDK.a */,
        #{@helpers_lib_build_uuid} /* libfoobar2000_SDK_helpers.a */,
        #{@client_lib_build_uuid} /* libfoobar2000_component_client.a */,
        #{@shared_lib_build_uuid} /* libshared.a */,
        #{@pfc_lib_build_uuid} /* libpfc-Mac.a */,
      );
      runOnlyForDeploymentPostprocessing = 0;
    };
  PHASE
end
```

### 4.3 Resources Phase

```ruby
def generate_resources_build_phase
  resource_refs = @resources
    .reject { |r| r[:name] == "Info.plist" }  # Info.plist handled separately
    .map { |r| "#{r[:build_uuid]} /* #{r[:name]} */," }
    .join("\n\t\t\t\t")

  <<~PHASE
    #{@resources_phase_uuid} /* Resources */ = {
      isa = PBXResourcesBuildPhase;
      buildActionMask = 2147483647;
      files = (
        #{resource_refs}
      );
      runOnlyForDeploymentPostprocessing = 0;
    };
  PHASE
end
```

## 5. Debug vs Release Configurations

### 5.1 Debug Settings

```ruby
DEBUG_SETTINGS = {
  "DEBUG_INFORMATION_FORMAT" => "dwarf",
  "ENABLE_TESTABILITY" => "YES",
  "GCC_DYNAMIC_NO_PIC" => "NO",
  "GCC_OPTIMIZATION_LEVEL" => "0",
  "GCC_PREPROCESSOR_DEFINITIONS" => '("DEBUG=1", "$(inherited)")',
  "MTL_ENABLE_DEBUG_INFO" => "INCLUDE_SOURCE",
  "ONLY_ACTIVE_ARCH" => "YES"
}
```

### 5.2 Release Settings

```ruby
RELEASE_SETTINGS = {
  "COPY_PHASE_STRIP" => "NO",
  "DEBUG_INFORMATION_FORMAT" => '"dwarf-with-dsym"',
  "ENABLE_NS_ASSERTIONS" => "NO",
  "GCC_OPTIMIZATION_LEVEL" => "s",
  "MTL_ENABLE_DEBUG_INFO" => "NO",
  "VALIDATE_PRODUCT" => "YES"
}
```

## 6. Build Script

### 6.1 Complete Build Script

```bash
#!/bin/bash
# build.sh

set -e

PROJECT_NAME="foo_mycomponent"
SDK_PATH="../SDK-2025-03-07"

echo "=== Building foobar2000 Component: $PROJECT_NAME ==="

# Step 1: Check SDK libraries
echo "Checking SDK libraries..."
REQUIRED_LIBS=(
    "$SDK_PATH/foobar2000/SDK/build/Release/libfoobar2000_SDK.a"
    "$SDK_PATH/foobar2000/helpers/build/Release/libfoobar2000_SDK_helpers.a"
    "$SDK_PATH/foobar2000/foobar2000_component_client/build/Release/libfoobar2000_component_client.a"
    "$SDK_PATH/foobar2000/shared/build/Release/libshared.a"
    "$SDK_PATH/pfc/build/Release/libpfc-Mac.a"
)

MISSING_LIBS=()
for lib in "${REQUIRED_LIBS[@]}"; do
    if [ ! -f "$lib" ]; then
        MISSING_LIBS+=("$lib")
    fi
done

if [ ${#MISSING_LIBS[@]} -gt 0 ]; then
    echo "ERROR: Missing SDK libraries:"
    for lib in "${MISSING_LIBS[@]}"; do
        echo "  - $lib"
    done
    echo ""
    echo "Build SDK libraries first:"
    echo "  cd $SDK_PATH"
    echo "  ./build_all.sh"
    exit 1
fi

# Step 2: Generate Xcode project
echo "Generating Xcode project..."
ruby Scripts/generate_xcode_project.rb

# Step 3: Build
echo "Building..."
xcodebuild -project "$PROJECT_NAME.xcodeproj" \
           -configuration Release \
           -arch arm64 -arch x86_64 \
           ONLY_ACTIVE_ARCH=NO \
           | xcpretty || xcodebuild -project "$PROJECT_NAME.xcodeproj" \
                                    -configuration Release \
                                    -arch arm64 -arch x86_64 \
                                    ONLY_ACTIVE_ARCH=NO

# Step 4: Verify output
if [ ! -d "build/Release/$PROJECT_NAME.component" ]; then
    echo "ERROR: Build failed - component not created"
    exit 1
fi

echo "Build successful: build/Release/$PROJECT_NAME.component"

# Step 5: Optional install
if [ "$1" == "--install" ]; then
    DEST=~/Library/Application\ Support/foobar2000/user-components
    mkdir -p "$DEST"
    rm -rf "$DEST/$PROJECT_NAME.component"
    cp -r "build/Release/$PROJECT_NAME.component" "$DEST/"
    echo "Installed to: $DEST/$PROJECT_NAME.component"
fi
```

### 6.2 SDK Build Script

```bash
#!/bin/bash
# build_sdk.sh - Run from SDK directory

set -e

echo "Building foobar2000 SDK libraries..."

# Build order matters due to dependencies
PROJECTS=(
    "pfc/pfc.xcodeproj"
    "foobar2000/shared/shared.xcodeproj"
    "foobar2000/SDK/foobar2000_SDK.xcodeproj"
    "foobar2000/helpers/foobar2000_SDK_helpers.xcodeproj"
    "foobar2000/foobar2000_component_client/foobar2000_component_client.xcodeproj"
)

for project in "${PROJECTS[@]}"; do
    echo "Building $project..."
    xcodebuild -project "$project" \
               -configuration Release \
               -arch arm64 -arch x86_64 \
               ONLY_ACTIVE_ARCH=NO \
               -quiet
done

echo "SDK build complete!"
```

## 7. Complete Project Generator

### 7.1 Full Ruby Script Template

```ruby
#!/usr/bin/env ruby
# generate_xcode_project.rb

require 'securerandom'
require 'fileutils'

#
# Configuration
#
PROJECT_NAME = "foo_mycomponent"
BUNDLE_ID = "com.yourname.foo_mycomponent"
SDK_PATH = "../SDK-2025-03-07"
DEPLOYMENT_TARGET = "10.13"
CPP_STANDARD = "gnu++17"

#
# UUID Generation
#
def uuid
  SecureRandom.uuid.gsub('-', '').upcase[0, 24]
end

#
# File Collection
#
class ProjectFile
  attr_accessor :path, :name, :uuid, :build_uuid, :type

  def initialize(path)
    @path = path
    @name = File.basename(path)
    @uuid = uuid
    @build_uuid = uuid
    @type = file_type(path)
  end

  def file_type(path)
    case File.extname(path).downcase
    when '.cpp' then 'sourcecode.cpp.cpp'
    when '.mm' then 'sourcecode.cpp.objcpp'
    when '.m' then 'sourcecode.c.objc'
    when '.c' then 'sourcecode.c.c'
    when '.h', '.hpp' then 'sourcecode.c.h'
    when '.plist' then 'text.plist.xml'
    when '.xib' then 'file.xib'
    when '.xcassets' then 'folder.assetcatalog'
    else 'file'
    end
  end

  def self.uuid
    SecureRandom.uuid.gsub('-', '').upcase[0, 24]
  end
end

def collect_files(dir, extensions)
  return [] unless File.directory?(dir)

  Dir.glob("#{dir}/**/*")
     .select { |p| extensions.include?(File.extname(p).downcase) }
     .map { |p| ProjectFile.new(p) }
end

#
# Project Generation
#
class XcodeProject
  def initialize
    @sources = collect_files("src", [".cpp", ".mm", ".m", ".c"])
    @headers = collect_files("src", [".h", ".hpp"])
    @resources = collect_files("Resources", [".xib", ".plist", ".xcassets"])

    # Generate UUIDs for project structure
    @project_uuid = uuid
    @main_group_uuid = uuid
    @products_group_uuid = uuid
    @sources_group_uuid = uuid
    @resources_group_uuid = uuid
    @frameworks_group_uuid = uuid

    @target_uuid = uuid
    @product_uuid = uuid

    @sources_phase_uuid = uuid
    @frameworks_phase_uuid = uuid
    @resources_phase_uuid = uuid

    @config_list_uuid = uuid
    @target_config_list_uuid = uuid
    @debug_config_uuid = uuid
    @release_config_uuid = uuid
    @target_debug_config_uuid = uuid
    @target_release_config_uuid = uuid

    # Framework and library UUIDs
    @cocoa_framework_uuid = uuid
    @cocoa_framework_build_uuid = uuid

    @libraries = generate_library_uuids
  end

  def generate_library_uuids
    libs = [
      { name: "libfoobar2000_SDK.a", path: "SDK/build/Release" },
      { name: "libfoobar2000_SDK_helpers.a", path: "helpers/build/Release" },
      { name: "libfoobar2000_component_client.a", path: "foobar2000_component_client/build/Release" },
      { name: "libshared.a", path: "shared/build/Release" },
      { name: "libpfc-Mac.a", path: "../pfc/build/Release" }
    ]

    libs.map do |lib|
      lib[:uuid] = uuid
      lib[:build_uuid] = uuid
      lib[:full_path] = "#{SDK_PATH}/foobar2000/#{lib[:path]}/#{lib[:name]}"
      lib
    end
  end

  def generate
    FileUtils.mkdir_p("#{PROJECT_NAME}.xcodeproj")

    content = <<~PBXPROJ
      // !$*UTF8*$!
      {
        archiveVersion = 1;
        classes = {
        };
        objectVersion = 56;
        objects = {
      #{generate_file_references}
      #{generate_groups}
      #{generate_build_files}
      #{generate_native_target}
      #{generate_project}
      #{generate_build_phases}
      #{generate_configurations}
        };
        rootObject = #{@project_uuid} /* Project object */;
      }
    PBXPROJ

    File.write("#{PROJECT_NAME}.xcodeproj/project.pbxproj", content)
    puts "Generated #{PROJECT_NAME}.xcodeproj"
  end

  # ... (remaining methods for each section)

  private

  def uuid
    SecureRandom.uuid.gsub('-', '').upcase[0, 24]
  end
end

# Main
XcodeProject.new.generate
```

## 8. Continuous Integration

### 8.1 GitHub Actions Workflow

```yaml
# .github/workflows/build.yml
name: Build Component

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  build:
    runs-on: macos-latest

    steps:
    - uses: actions/checkout@v4

    - name: Setup Ruby
      uses: ruby/setup-ruby@v1
      with:
        ruby-version: '3.2'

    - name: Cache SDK
      uses: actions/cache@v3
      with:
        path: ../SDK-2025-03-07
        key: sdk-2025-03-07

    - name: Download SDK
      run: |
        if [ ! -d "../SDK-2025-03-07" ]; then
          # Download and extract SDK
          curl -L "https://example.com/sdk.zip" -o sdk.zip
          unzip sdk.zip -d ..
        fi

    - name: Build SDK
      run: |
        cd ../SDK-2025-03-07
        ./build_all.sh

    - name: Generate Project
      run: ruby Scripts/generate_xcode_project.rb

    - name: Build Component
      run: |
        xcodebuild -project foo_mycomponent.xcodeproj \
                   -configuration Release \
                   -arch arm64 -arch x86_64

    - name: Upload Artifact
      uses: actions/upload-artifact@v3
      with:
        name: foo_mycomponent.component
        path: build/Release/foo_mycomponent.component
```

## 9. Troubleshooting

### 9.1 Common Build Errors

| Error | Solution |
|-------|----------|
| "No such file or directory: SDK/..." | Check SDK_PATH in generate script |
| "Undefined symbols for architecture..." | Verify all 5 libraries are linked |
| "Could not build module 'Cocoa'" | Check MACOSX_DEPLOYMENT_TARGET |
| "No matching function for call..." | Verify C++ standard is gnu++17 or higher |

### 9.2 Verification Checklist

```bash
# Check project was generated
ls -la foo_mycomponent.xcodeproj/project.pbxproj

# Check all sources are included
grep -c "PBXBuildFile" foo_mycomponent.xcodeproj/project.pbxproj

# Verify library paths exist
for lib in ../SDK-2025-03-07/foobar2000/*/build/Release/*.a; do
    echo "Found: $lib"
done

# Build and check output
xcodebuild -project foo_mycomponent.xcodeproj -configuration Release
ls -la build/Release/
```

## Best Practices

1. **Always regenerate** project after adding/removing files
2. **Version the generator script**, not the generated project
3. **Use relative SDK paths** for portability
4. **Build SDK once**, cache for subsequent builds
5. **Test both Debug and Release** configurations
6. **Universal binaries** - build for both arm64 and x86_64

## 10. Standard Scripts Set

Every foobar2000 macOS component project should include these scripts in a `Scripts/` folder:

### 10.1 Required Scripts

| Script | Purpose |
|--------|---------|
| `generate_xcode_project.rb` | Generate Xcode project without external gem dependencies |
| `build.sh` | Build the component with options (--debug, --release, --clean, --install) |
| `install.sh` | Install built component to foobar2000 user-components folder |
| `clean.sh` | Clean build artifacts (--all to also remove xcodeproj) |
| `test_install.sh` | Convenience script: clean + build + install in one command |

### 10.2 Script Template Pattern

All scripts should follow this pattern:
- Use `set -e` for fail-fast behavior
- Parse command-line arguments with a `while` loop
- Support `--help` option
- Use colored output for status messages
- Auto-detect project directory from script location

```bash
#!/bin/bash
PROJECT_NAME="foo_mycomponent"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
```

### 10.3 foobar2000 v2 Component Path

Components must be installed to the correct path structure:

```
~/Library/foobar2000-v2/user-components/<component_name>/<component_name>.component
```

Example for `foo_simplaylist`:
```
~/Library/foobar2000-v2/user-components/foo_simplaylist/foo_simplaylist.component
```

### 10.4 Usage Examples

```bash
# Quick test cycle
./Scripts/test_install.sh

# Debug build with install
./Scripts/build.sh --debug --install

# Clean everything including generated project
./Scripts/clean.sh --all

# Regenerate project after adding files
./Scripts/build.sh --regenerate
```
