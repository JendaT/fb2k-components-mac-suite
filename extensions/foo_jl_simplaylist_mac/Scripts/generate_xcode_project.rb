#!/usr/bin/env ruby
# Generate Xcode project for foo_simplaylist_mac

require 'fileutils'
require 'securerandom'
require_relative '../../../shared/sdk_config'

# Generate UUID for Xcode (24 character hex string)
def generate_uuid
  SecureRandom.hex(12).upcase
end

# Project configuration
PROJECT_NAME = "foo_jl_simplaylist"
BUNDLE_ID = "com.foobar2000.foo-jl-simplaylist"
SDK_PATH = Fb2kSdk.path

# Generate all the UUIDs we'll need
uuid_project = generate_uuid
uuid_main_group = generate_uuid
uuid_products_group = generate_uuid
uuid_target = generate_uuid
uuid_native_target = generate_uuid
uuid_build_config_list_project = generate_uuid
uuid_build_config_list_target = generate_uuid
uuid_debug_config_project = generate_uuid
uuid_release_config_project = generate_uuid
uuid_debug_config_target = generate_uuid
uuid_release_config_target = generate_uuid
uuid_sources_build_phase = generate_uuid
uuid_frameworks_build_phase = generate_uuid
uuid_resources_build_phase = generate_uuid
uuid_product = generate_uuid

# Source file groups
uuid_src_group = generate_uuid
uuid_core_group = generate_uuid
uuid_ui_group = generate_uuid
uuid_integration_group = generate_uuid
uuid_resources_group = generate_uuid

# Framework references
uuid_cocoa_framework = generate_uuid
uuid_cocoa_framework_ref = generate_uuid
uuid_quartz_framework = generate_uuid
uuid_quartz_framework_ref = generate_uuid
uuid_security_framework = generate_uuid
uuid_security_framework_ref = generate_uuid
uuid_sqlite_lib = generate_uuid
uuid_sqlite_lib_ref = generate_uuid
uuid_compression_lib = generate_uuid
uuid_compression_lib_ref = generate_uuid
uuid_zlib = generate_uuid
uuid_zlib_ref = generate_uuid
uuid_frameworks_group = generate_uuid

# SDK libraries
uuid_sdk_lib = generate_uuid
uuid_sdk_lib_ref = generate_uuid
uuid_helpers_lib = generate_uuid
uuid_helpers_lib_ref = generate_uuid
uuid_component_client_lib = generate_uuid
uuid_component_client_lib_ref = generate_uuid
uuid_shared_lib = generate_uuid
uuid_shared_lib_ref = generate_uuid
uuid_pfc_lib = generate_uuid
uuid_pfc_lib_ref = generate_uuid

# Collect source files
core_files = Dir.glob("src/Core/*.{cpp,h,mm}").map { |f| File.basename(f) }
ui_files = Dir.glob("src/UI/*.{cpp,h,mm}").map { |f| File.basename(f) }
integration_files = Dir.glob("src/Integration/*.{cpp,h,mm}").map { |f| File.basename(f) }

# Collect resource files (XIB, etc.)
resource_files = Dir.glob("Resources/*.xib").map { |f| File.basename(f) }

# Generate UUIDs for all source files
file_uuids = {}
file_ref_uuids = {}

[core_files, ui_files, integration_files].flatten.each do |file|
  file_uuids[file] = generate_uuid
  file_ref_uuids[file] = generate_uuid
end

# Generate UUIDs for resource files
resource_files.each do |file|
  file_uuids[file] = generate_uuid
  file_ref_uuids[file] = generate_uuid
end

# Info.plist UUID
uuid_infoplist = generate_uuid

# Prefix header UUID
uuid_prefix_header = generate_uuid
uuid_sdk_header = generate_uuid

puts "Generating Xcode project structure..."
puts "  Core files: #{core_files.join(', ')}"
puts "  UI files: #{ui_files.join(', ')}"
puts "  Integration files: #{integration_files.join(', ')}"
puts "  Resource files: #{resource_files.join(', ')}"

# Create the .xcodeproj bundle
FileUtils.mkdir_p("#{PROJECT_NAME}.xcodeproj")

# Generate project.pbxproj file
pbxproj_content = <<~PBXPROJ
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 56;
	objects = {

/* Begin PBXBuildFile section */
PBXPROJ

# Add build file entries for source files
[['Core', core_files], ['UI', ui_files], ['Integration', integration_files]].each do |group, files|
  files.each do |file|
    next if file.end_with?('.h')  # Don't compile headers
    pbxproj_content += "\t\t#{file_uuids[file]} /* #{file} in Sources */ = {isa = PBXBuildFile; fileRef = #{file_ref_uuids[file]} /* #{file} */; };\n"
  end
end

# Add XIB files as resources
resource_files.each do |file|
  pbxproj_content += "\t\t#{file_uuids[file]} /* #{file} in Resources */ = {isa = PBXBuildFile; fileRef = #{file_ref_uuids[file]} /* #{file} */; };\n"
end

# Add frameworks
pbxproj_content += "\t\t#{uuid_cocoa_framework} /* Cocoa.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = #{uuid_cocoa_framework_ref} /* Cocoa.framework */; };\n"
pbxproj_content += "\t\t#{uuid_quartz_framework} /* QuartzCore.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = #{uuid_quartz_framework_ref} /* QuartzCore.framework */; };\n"
pbxproj_content += "\t\t#{uuid_security_framework} /* Security.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = #{uuid_security_framework_ref} /* Security.framework */; };\n"
pbxproj_content += "\t\t#{uuid_sqlite_lib} /* libsqlite3.tbd in Frameworks */ = {isa = PBXBuildFile; fileRef = #{uuid_sqlite_lib_ref} /* libsqlite3.tbd */; };\n"
pbxproj_content += "\t\t#{uuid_compression_lib} /* libcompression.tbd in Frameworks */ = {isa = PBXBuildFile; fileRef = #{uuid_compression_lib_ref} /* libcompression.tbd */; };\n"
pbxproj_content += "\t\t#{uuid_zlib} /* libz.tbd in Frameworks */ = {isa = PBXBuildFile; fileRef = #{uuid_zlib_ref} /* libz.tbd */; };\n"

# Add SDK libraries
pbxproj_content += "\t\t#{uuid_sdk_lib} /* libfoobar2000_SDK.a in Frameworks */ = {isa = PBXBuildFile; fileRef = #{uuid_sdk_lib_ref} /* libfoobar2000_SDK.a */; };\n"
pbxproj_content += "\t\t#{uuid_helpers_lib} /* libfoobar2000_SDK_helpers.a in Frameworks */ = {isa = PBXBuildFile; fileRef = #{uuid_helpers_lib_ref} /* libfoobar2000_SDK_helpers.a */; };\n"
pbxproj_content += "\t\t#{uuid_component_client_lib} /* libfoobar2000_component_client.a in Frameworks */ = {isa = PBXBuildFile; fileRef = #{uuid_component_client_lib_ref} /* libfoobar2000_component_client.a */; };\n"
pbxproj_content += "\t\t#{uuid_shared_lib} /* libshared.a in Frameworks */ = {isa = PBXBuildFile; fileRef = #{uuid_shared_lib_ref} /* libshared.a */; };\n"
pbxproj_content += "\t\t#{uuid_pfc_lib} /* libpfc-Mac.a in Frameworks */ = {isa = PBXBuildFile; fileRef = #{uuid_pfc_lib_ref} /* libpfc-Mac.a */; };\n"

pbxproj_content += <<~PBXPROJ
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
PBXPROJ

# Add file references for source files
[['Core', core_files], ['UI', ui_files], ['Integration', integration_files]].each do |group, files|
  files.each do |file|
    file_type = if file.end_with?('.h')
      'sourcecode.c.h'
    elsif file.end_with?('.mm')
      'sourcecode.cpp.objcpp'
    elsif file.end_with?('.cpp')
      'sourcecode.cpp.cpp'
    else
      'text'
    end

    pbxproj_content += "\t\t#{file_ref_uuids[file]} /* #{file} */ = {isa = PBXFileReference; lastKnownFileType = #{file_type}; path = #{file}; sourceTree = \"<group>\"; };\n"
  end
end

# Add XIB file references
resource_files.each do |file|
  pbxproj_content += "\t\t#{file_ref_uuids[file]} /* #{file} */ = {isa = PBXFileReference; lastKnownFileType = file.xib; path = #{file}; sourceTree = \"<group>\"; };\n"
end

# Add product reference
pbxproj_content += "\t\t#{uuid_product} /* #{PROJECT_NAME}.component */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = #{PROJECT_NAME}.component; sourceTree = BUILT_PRODUCTS_DIR; };\n"

# Add Info.plist reference
pbxproj_content += "\t\t#{uuid_infoplist} /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; };\n"

# Add Prefix.pch and fb2k_sdk.h references
pbxproj_content += "\t\t#{uuid_prefix_header} /* Prefix.pch */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = Prefix.pch; sourceTree = \"<group>\"; };\n"
pbxproj_content += "\t\t#{uuid_sdk_header} /* fb2k_sdk.h */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = fb2k_sdk.h; sourceTree = \"<group>\"; };\n"

# Add framework references
pbxproj_content += "\t\t#{uuid_cocoa_framework_ref} /* Cocoa.framework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = Cocoa.framework; path = System/Library/Frameworks/Cocoa.framework; sourceTree = SDKROOT; };\n"
pbxproj_content += "\t\t#{uuid_quartz_framework_ref} /* QuartzCore.framework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = QuartzCore.framework; path = System/Library/Frameworks/QuartzCore.framework; sourceTree = SDKROOT; };\n"
pbxproj_content += "\t\t#{uuid_security_framework_ref} /* Security.framework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = Security.framework; path = System/Library/Frameworks/Security.framework; sourceTree = SDKROOT; };\n"
pbxproj_content += "\t\t#{uuid_sqlite_lib_ref} /* libsqlite3.tbd */ = {isa = PBXFileReference; lastKnownFileType = \"sourcecode.text-based-dylib-definition\"; name = libsqlite3.tbd; path = usr/lib/libsqlite3.tbd; sourceTree = SDKROOT; };\n"
pbxproj_content += "\t\t#{uuid_compression_lib_ref} /* libcompression.tbd */ = {isa = PBXFileReference; lastKnownFileType = \"sourcecode.text-based-dylib-definition\"; name = libcompression.tbd; path = usr/lib/libcompression.tbd; sourceTree = SDKROOT; };\n"
pbxproj_content += "\t\t#{uuid_zlib_ref} /* libz.tbd */ = {isa = PBXFileReference; lastKnownFileType = \"sourcecode.text-based-dylib-definition\"; name = libz.tbd; path = usr/lib/libz.tbd; sourceTree = SDKROOT; };\n"

# Add SDK library references
pbxproj_content += "\t\t#{uuid_sdk_lib_ref} /* libfoobar2000_SDK.a */ = {isa = PBXFileReference; lastKnownFileType = archive.ar; name = libfoobar2000_SDK.a; path = \"#{SDK_PATH}/foobar2000/SDK/build/Release/libfoobar2000_SDK.a\"; sourceTree = \"<group>\"; };\n"
pbxproj_content += "\t\t#{uuid_helpers_lib_ref} /* libfoobar2000_SDK_helpers.a */ = {isa = PBXFileReference; lastKnownFileType = archive.ar; name = libfoobar2000_SDK_helpers.a; path = \"#{SDK_PATH}/foobar2000/helpers/build/Release/libfoobar2000_SDK_helpers.a\"; sourceTree = \"<group>\"; };\n"
pbxproj_content += "\t\t#{uuid_component_client_lib_ref} /* libfoobar2000_component_client.a */ = {isa = PBXFileReference; lastKnownFileType = archive.ar; name = libfoobar2000_component_client.a; path = \"#{SDK_PATH}/foobar2000/foobar2000_component_client/build/Release/libfoobar2000_component_client.a\"; sourceTree = \"<group>\"; };\n"
pbxproj_content += "\t\t#{uuid_shared_lib_ref} /* libshared.a */ = {isa = PBXFileReference; lastKnownFileType = archive.ar; name = libshared.a; path = \"#{SDK_PATH}/foobar2000/shared/build/Release/libshared.a\"; sourceTree = \"<group>\"; };\n"
pbxproj_content += "\t\t#{uuid_pfc_lib_ref} /* libpfc-Mac.a */ = {isa = PBXFileReference; lastKnownFileType = archive.ar; name = \"libpfc-Mac.a\"; path = \"#{SDK_PATH}/pfc/build/Release/libpfc-Mac.a\"; sourceTree = \"<group>\"; };\n"

pbxproj_content += <<~PBXPROJ
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		#{uuid_frameworks_build_phase} /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				#{uuid_cocoa_framework} /* Cocoa.framework in Frameworks */,
				#{uuid_quartz_framework} /* QuartzCore.framework in Frameworks */,
				#{uuid_security_framework} /* Security.framework in Frameworks */,
				#{uuid_sqlite_lib} /* libsqlite3.tbd in Frameworks */,
				#{uuid_compression_lib} /* libcompression.tbd in Frameworks */,
				#{uuid_zlib} /* libz.tbd in Frameworks */,
				#{uuid_sdk_lib} /* libfoobar2000_SDK.a in Frameworks */,
				#{uuid_helpers_lib} /* libfoobar2000_SDK_helpers.a in Frameworks */,
				#{uuid_component_client_lib} /* libfoobar2000_component_client.a in Frameworks */,
				#{uuid_shared_lib} /* libshared.a in Frameworks */,
				#{uuid_pfc_lib} /* libpfc-Mac.a in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		#{uuid_project} = {
			isa = PBXGroup;
			children = (
				#{uuid_src_group} /* src */,
				#{uuid_resources_group} /* Resources */,
				#{uuid_frameworks_group} /* Frameworks */,
				#{uuid_products_group} /* Products */,
			);
			sourceTree = "<group>";
		};
		#{uuid_src_group} /* src */ = {
			isa = PBXGroup;
			children = (
				#{uuid_prefix_header} /* Prefix.pch */,
				#{uuid_sdk_header} /* fb2k_sdk.h */,
				#{uuid_core_group} /* Core */,
				#{uuid_ui_group} /* UI */,
				#{uuid_integration_group} /* Integration */,
			);
			path = src;
			sourceTree = "<group>";
		};
		#{uuid_core_group} /* Core */ = {
			isa = PBXGroup;
			children = (
PBXPROJ

core_files.each do |file|
  pbxproj_content += "\t\t\t\t#{file_ref_uuids[file]} /* #{file} */,\n"
end

pbxproj_content += <<~PBXPROJ
			);
			path = Core;
			sourceTree = "<group>";
		};
		#{uuid_ui_group} /* UI */ = {
			isa = PBXGroup;
			children = (
PBXPROJ

ui_files.each do |file|
  pbxproj_content += "\t\t\t\t#{file_ref_uuids[file]} /* #{file} */,\n"
end

pbxproj_content += <<~PBXPROJ
			);
			path = UI;
			sourceTree = "<group>";
		};
		#{uuid_integration_group} /* Integration */ = {
			isa = PBXGroup;
			children = (
PBXPROJ

integration_files.each do |file|
  pbxproj_content += "\t\t\t\t#{file_ref_uuids[file]} /* #{file} */,\n"
end

pbxproj_content += <<~PBXPROJ
			);
			path = Integration;
			sourceTree = "<group>";
		};
		#{uuid_resources_group} /* Resources */ = {
			isa = PBXGroup;
			children = (
				#{uuid_infoplist} /* Info.plist */,
PBXPROJ

resource_files.each do |file|
  pbxproj_content += "\t\t\t\t#{file_ref_uuids[file]} /* #{file} */,\n"
end

pbxproj_content += <<~PBXPROJ
			);
			path = Resources;
			sourceTree = "<group>";
		};
		#{uuid_frameworks_group} /* Frameworks */ = {
			isa = PBXGroup;
			children = (
				#{uuid_cocoa_framework_ref} /* Cocoa.framework */,
				#{uuid_quartz_framework_ref} /* QuartzCore.framework */,
				#{uuid_security_framework_ref} /* Security.framework */,
				#{uuid_sqlite_lib_ref} /* libsqlite3.tbd */,
				#{uuid_compression_lib_ref} /* libcompression.tbd */,
				#{uuid_zlib_ref} /* libz.tbd */,
				#{uuid_sdk_lib_ref} /* libfoobar2000_SDK.a */,
				#{uuid_helpers_lib_ref} /* libfoobar2000_SDK_helpers.a */,
				#{uuid_component_client_lib_ref} /* libfoobar2000_component_client.a */,
				#{uuid_shared_lib_ref} /* libshared.a */,
				#{uuid_pfc_lib_ref} /* libpfc-Mac.a */,
			);
			name = Frameworks;
			sourceTree = "<group>";
		};
		#{uuid_products_group} /* Products */ = {
			isa = PBXGroup;
			children = (
				#{uuid_product} /* #{PROJECT_NAME}.component */,
			);
			name = Products;
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		#{uuid_native_target} /* #{PROJECT_NAME} */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = #{uuid_build_config_list_target} /* Build configuration list for PBXNativeTarget "#{PROJECT_NAME}" */;
			buildPhases = (
				#{uuid_sources_build_phase} /* Sources */,
				#{uuid_frameworks_build_phase} /* Frameworks */,
				#{uuid_resources_build_phase} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = #{PROJECT_NAME};
			productName = #{PROJECT_NAME};
			productReference = #{uuid_product} /* #{PROJECT_NAME}.component */;
			productType = "com.apple.product-type.bundle";
		};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		#{uuid_target} /* Project object */ = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastUpgradeCheck = 1500;
				TargetAttributes = {
					#{uuid_native_target} = {
						CreatedOnToolsVersion = 15.0;
					};
				};
			};
			buildConfigurationList = #{uuid_build_config_list_project} /* Build configuration list for PBXProject "#{PROJECT_NAME}" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = #{uuid_project};
			productRefGroup = #{uuid_products_group} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				#{uuid_native_target} /* #{PROJECT_NAME} */,
			);
		};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		#{uuid_resources_build_phase} /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
PBXPROJ

# Add XIB files to resources
resource_files.each do |file|
  pbxproj_content += "\t\t\t\t#{file_uuids[file]} /* #{file} in Resources */,\n"
end

pbxproj_content += <<~PBXPROJ
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		#{uuid_sources_build_phase} /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
PBXPROJ

# Add all source files (not headers) to sources build phase
[['Core', core_files], ['UI', ui_files], ['Integration', integration_files]].each do |group, files|
  files.each do |file|
    next if file.end_with?('.h')
    pbxproj_content += "\t\t\t\t#{file_uuids[file]} /* #{file} in Sources */,\n"
  end
end

pbxproj_content += <<~PBXPROJ
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		#{uuid_debug_config_project} /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_CXX_LANGUAGE_STANDARD = "gnu++17";
				CLANG_ENABLE_OBJC_ARC = YES;
				CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
				CLANG_WARN_BOOL_CONVERSION = YES;
				CLANG_WARN_COMMA = YES;
				CLANG_WARN_CONSTANT_CONVERSION = YES;
				CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
				CLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;
				CLANG_WARN_EMPTY_BODY = YES;
				CLANG_WARN_ENUM_CONVERSION = YES;
				CLANG_WARN_INT_CONVERSION = YES;
				CLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;
				CLANG_WARN_OBJC_LITERAL_CONVERSION = YES;
				CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
				CLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
				CLANG_WARN_SUSPICIOUS_MOVE = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_TESTABILITY = YES;
				GCC_C_LANGUAGE_STANDARD = gnu11;
				GCC_DYNAMIC_NO_PIC = NO;
				GCC_NO_COMMON_BLOCKS = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				GCC_WARN_64_TO_32_BIT_CONVERSION = YES;
				GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
				GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
				GCC_WARN_UNUSED_FUNCTION = YES;
				GCC_WARN_UNUSED_VARIABLE = YES;
				MACOSX_DEPLOYMENT_TARGET = 11.0;
				MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = macosx;
			};
			name = Debug;
		};
		#{uuid_release_config_project} /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_CXX_LANGUAGE_STANDARD = "gnu++17";
				CLANG_ENABLE_OBJC_ARC = YES;
				CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
				CLANG_WARN_BOOL_CONVERSION = YES;
				CLANG_WARN_COMMA = YES;
				CLANG_WARN_CONSTANT_CONVERSION = YES;
				CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
				CLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;
				CLANG_WARN_EMPTY_BODY = YES;
				CLANG_WARN_ENUM_CONVERSION = YES;
				CLANG_WARN_INT_CONVERSION = YES;
				CLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;
				CLANG_WARN_OBJC_LITERAL_CONVERSION = YES;
				CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
				CLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
				CLANG_WARN_SUSPICIOUS_MOVE = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				GCC_C_LANGUAGE_STANDARD = gnu11;
				GCC_NO_COMMON_BLOCKS = YES;
				GCC_WARN_64_TO_32_BIT_CONVERSION = YES;
				GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
				GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
				GCC_WARN_UNUSED_FUNCTION = YES;
				GCC_WARN_UNUSED_VARIABLE = YES;
				MACOSX_DEPLOYMENT_TARGET = 11.0;
				MTL_ENABLE_DEBUG_INFO = NO;
				SDKROOT = macosx;
			};
			name = Release;
		};
		#{uuid_debug_config_target} /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = Resources/Info.plist;
				INFOPLIST_KEY_NSHumanReadableCopyright = "";
				INFOPLIST_KEY_NSPrincipalClass = "";
				INSTALL_PATH = "$(LOCAL_LIBRARY_DIR)/Bundles";
				MARKETING_VERSION = 1.0.0;
				PRODUCT_BUNDLE_IDENTIFIER = #{BUNDLE_ID};
				PRODUCT_NAME = "$(TARGET_NAME)";
				SKIP_INSTALL = YES;
				WRAPPER_EXTENSION = component;
				GCC_PREFIX_HEADER = src/Prefix.pch;
				GCC_PRECOMPILE_PREFIX_HEADER = YES;
				HEADER_SEARCH_PATHS = (
					"$(PROJECT_DIR)/#{SDK_PATH}",
					"$(PROJECT_DIR)/#{SDK_PATH}/foobar2000",
					"$(PROJECT_DIR)/#{SDK_PATH}/pfc",
				);
				LIBRARY_SEARCH_PATHS = (
					"$(PROJECT_DIR)/#{SDK_PATH}/foobar2000/SDK/build/Release",
					"$(PROJECT_DIR)/#{SDK_PATH}/foobar2000/helpers/build/Release",
					"$(PROJECT_DIR)/#{SDK_PATH}/foobar2000/foobar2000_component_client/build/Release",
					"$(PROJECT_DIR)/#{SDK_PATH}/foobar2000/shared/build/Release",
					"$(PROJECT_DIR)/#{SDK_PATH}/pfc/build/Release",
				);
			};
			name = Debug;
		};
		#{uuid_release_config_target} /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = Resources/Info.plist;
				INFOPLIST_KEY_NSHumanReadableCopyright = "";
				INFOPLIST_KEY_NSPrincipalClass = "";
				INSTALL_PATH = "$(LOCAL_LIBRARY_DIR)/Bundles";
				MARKETING_VERSION = 1.0.0;
				PRODUCT_BUNDLE_IDENTIFIER = #{BUNDLE_ID};
				PRODUCT_NAME = "$(TARGET_NAME)";
				SKIP_INSTALL = YES;
				WRAPPER_EXTENSION = component;
				GCC_PREFIX_HEADER = src/Prefix.pch;
				GCC_PRECOMPILE_PREFIX_HEADER = YES;
				HEADER_SEARCH_PATHS = (
					"$(PROJECT_DIR)/#{SDK_PATH}",
					"$(PROJECT_DIR)/#{SDK_PATH}/foobar2000",
					"$(PROJECT_DIR)/#{SDK_PATH}/pfc",
				);
				LIBRARY_SEARCH_PATHS = (
					"$(PROJECT_DIR)/#{SDK_PATH}/foobar2000/SDK/build/Release",
					"$(PROJECT_DIR)/#{SDK_PATH}/foobar2000/helpers/build/Release",
					"$(PROJECT_DIR)/#{SDK_PATH}/foobar2000/foobar2000_component_client/build/Release",
					"$(PROJECT_DIR)/#{SDK_PATH}/foobar2000/shared/build/Release",
					"$(PROJECT_DIR)/#{SDK_PATH}/pfc/build/Release",
				);
			};
			name = Release;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		#{uuid_build_config_list_project} /* Build configuration list for PBXProject "#{PROJECT_NAME}" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				#{uuid_debug_config_project} /* Debug */,
				#{uuid_release_config_project} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		#{uuid_build_config_list_target} /* Build configuration list for PBXNativeTarget "#{PROJECT_NAME}" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				#{uuid_debug_config_target} /* Debug */,
				#{uuid_release_config_target} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
/* End XCConfigurationList section */
	};
	rootObject = #{uuid_target} /* Project object */;
}
PBXPROJ

# Write the project file
File.write("#{PROJECT_NAME}.xcodeproj/project.pbxproj", pbxproj_content)

puts ""
puts "Xcode project generated successfully!"
puts "   Project: #{PROJECT_NAME}.xcodeproj"
puts "   Target: #{PROJECT_NAME}"
puts "   Product: #{PROJECT_NAME}.component"
puts ""
puts "Next steps:"
puts "   1. Build SDK libraries (if not already done)"
puts "   2. Open #{PROJECT_NAME}.xcodeproj in Xcode"
puts "   3. Build (Cmd+B)"
