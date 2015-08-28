# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Defines rules for building a fat library for distribution.
#
# The including makefile must define the variables:
#   FAT_LIB_NAME
#   FAT_LIB_SOURCES_RELATIVE
#   FAT_LIB_SOURCE_DIRS
#   FAT_LIB_COMPILE
# The including makefile may define the following optional variables:
#   FAT_LIB_PRECOMPILED_HEADER
#   FAT_LIB_OSX_FLAGS
#
# This file defines the following to be used by the including file:
#   FAT_LIB_LIBRARY
#
# The including file may specify dependencies to compilation by adding
# prerequisites to the "fat_lib_dependencies" target.
#
# Author: Keith Stanger

FAT_LIB_LIBRARY = $(ARCH_BUILD_DIR)/lib$(FAT_LIB_NAME).a

FAT_LIB_PLIST_DIR = $(BUILD_DIR)/plists
FAT_LIB_PLISTS = \
  $(foreach src,$(FAT_LIB_SOURCES_RELATIVE),$(FAT_LIB_PLIST_DIR)/$(basename $(src)).plist)

FAT_LIB_MACOSX_SDK_DIR := $(shell bash $(J2OBJC_ROOT)/scripts/sysroot_path.sh)
FAT_LIB_IPHONE_SDK_DIR := $(shell bash $(J2OBJC_ROOT)/scripts/sysroot_path.sh --iphoneos)
FAT_LIB_SIMULATOR_SDK_DIR := $(shell bash $(J2OBJC_ROOT)/scripts/sysroot_path.sh --iphonesimulator)

FAT_LIB_MACOSX_FLAGS = $(FAT_LIB_OSX_FLAGS) -DJ2OBJC_BUILD_ARCH=x86_64 \
  -isysroot $(FAT_LIB_MACOSX_SDK_DIR)
FAT_LIB_IPHONE_FLAGS = -arch armv7 -DJ2OBJC_BUILD_ARCH=armv7 -miphoneos-version-min=5.0 \
  -isysroot $(FAT_LIB_IPHONE_SDK_DIR)
FAT_LIB_IPHONE64_FLAGS = -arch arm64 -DJ2OBJC_BUILD_ARCH=arm64 -miphoneos-version-min=5.0 \
  -isysroot $(FAT_LIB_IPHONE_SDK_DIR)
FAT_LIB_IPHONEV7S_FLAGS = -arch armv7s -DJ2OBJC_BUILD_ARCH=armv7s -miphoneos-version-min=5.0 \
  -isysroot $(FAT_LIB_IPHONE_SDK_DIR)
FAT_LIB_SIMULATOR_FLAGS = -arch i386 -DJ2OBJC_BUILD_ARCH=i386 -miphoneos-version-min=5.0 \
  -isysroot $(FAT_LIB_SIMULATOR_SDK_DIR)
FAT_LIB_XCODE_FLAGS = -arch $(1) -DJ2OBJC_BUILD_ARCH=$(1) -miphoneos-version-min=5.0 \
  -isysroot $(SDKROOT)

# Command-line pattern for calling libtool and filtering the "same member name"
# errors from having object files of the same name. (but in different directory)
fat_lib_filtered_libtool = set -o pipefail && $(LIBTOOL) -static -o $1 -filelist $2 2>&1 \
  | (grep -v "same member name" || true)

ifneq ($(MAKECMDGOALS),clean)

arch_flags = $(strip \
  $(patsubst macosx,$(FAT_LIB_MACOSX_FLAGS),\
  $(patsubst iphone,$(FAT_LIB_IPHONE_FLAGS),\
  $(patsubst iphone64,$(FAT_LIB_IPHONE64_FLAGS),\
  $(patsubst iphonev7s,$(FAT_LIB_IPHONEV7S_FLAGS),\
  $(patsubst simulator,$(FAT_LIB_SIMULATOR_FLAGS),$(1)))))))

fat_lib_dependencies:
	@:

# Generates compile rule.
# Args:
#   1: output directory
#   2: input directory
#   3: compile command
#   4: precompiled header file, or empty
#   5: other compiler flags
define compile_rule
$(1)/%.o: $(2)/%.m $(4:%=$(1)/%.pch) | fat_lib_dependencies
	@mkdir -p $$(@D)
	@echo compiling '$$<'
	@$(3) $(4:%=-include $(1)/%) $(5) -MD -c '$$<' -o '$$@'

$(1)/%.o: $(2)/%.mm $(4:%=%.pch) | fat_lib_dependencies
	@mkdir -p $$(@D)
	@echo compiling '$$<'
	@$(3) -x objective-c++ $(4:%=-include %) $(5) -MD -c '$$<' -o '$$@'
endef

# Generates rule to build precompiled headers file.
# Args:
#   1: output file name
#   2: input file
#   3: compile command
#   4: other compiler flags
define compile_pch_rule
$(1): $(2) | fat_lib_dependencies
	@mkdir -p $$(@D)
	@echo compiling '$$<'
	@$(3) -x objective-c-header $(4) -MD -c $$< -o $$@
endef

# Generates analyze rule.
# Args:
#   1: source directory
#   2: compile command
define analyze_rule
$(FAT_LIB_PLIST_DIR)/%.plist: $(1)/%.m | fat_lib_dependencies
	@mkdir -p $$(@D)
	@echo compiling '$$<'
	@$(2) $(STATIC_ANALYZER_FLAGS) -c '$$<' -o '$$@'

$(FAT_LIB_PLIST_DIR)/%.plist: $(1)/%.mm | fat_lib_dependencies
	@mkdir -p $$(@D)
	@echo compiling '$$<'
	@$(2) -x objective-c++ $(STATIC_ANALYZER_FLAGS) -c '$$<' -o '$$@'
endef

# Generates compile rules.
# Args:
#   1: list of source directories
#   2: output directory
#   3: compile command
#   4: precompiled header file, or empty
#   5: compilation flags
emit_compile_rules_for_arch = $(foreach src_dir,$(1),\
  $(eval $(call compile_pch_rule,$(2)/%.pch,$(src_dir)/%,$(3),$(5)))\
  $(eval $(call compile_rule,$(2),$(src_dir),$(3),$(4),$(5)))) \
  $(if $(4),\
    $(eval .SECONDARY: $(2)/$(4).pch) \
    $(eval -include $(2)/$(4).d),)

FAT_LIB_OBJS = $(foreach file,$(FAT_LIB_SOURCES_RELATIVE),$(basename $(file)).o)

# Generate the library rule for a single architecture.
# Args:
#   1. Architecture specific output directory.
#   2. Library name.
#   3. Object file list (relative dirs).
define arch_lib_rule
-include $(3:%.o=$(1)/%.d)

$(1)/lib$(2).a: $(subst $$,$$$$,$(3:%=$(1)/%))
	@echo "Building $$(notdir $$@)"
	$$(call long_list_to_file,$(1)/fat_lib_objs_list,$$^)
	@$$(call fat_lib_filtered_libtool,$$@,$(1)/fat_lib_objs_list)
endef

# Generate the rule to create the fat library.
# Args:
#   1. Library name.
#   2. List of architecture specific libraries.
define fat_lib_rule
$(ARCH_BUILD_DIR)/lib$(1).a: $(2)
	@mkdir -p $$(@D)
	$$(LIPO) -create $$^ -output $$@
endef

ifdef TARGET_TEMP_DIR
# Targets specific to an xcode build

XCODE_ARCHS = $(ARCHS)
# Xcode seems to set ARCHS incorrectly in command-line builds when the only
# active architecture setting is on. Use NATIVE_ARCH instead.
ifeq ($(ONLY_ACTIVE_ARCH), YES)
ifdef CURRENT_ARCH
XCODE_ARCHS = $(CURRENT_ARCH)
endif
endif

emit_library_rules = $(foreach arch,$(XCODE_ARCHS),\
  $(eval $(call arch_lib_rule,$(TARGET_TEMP_DIR)/$(arch),$(1),$(2)))) \
  $(eval $(call fat_lib_rule,$(1),$(XCODE_ARCHS:%=$(TARGET_TEMP_DIR)/%/lib$(1).a)))

emit_arch_specific_compile_rules = $(foreach arch,$(XCODE_ARCHS),\
  $(call emit_compile_rules_for_arch,$(1),$(TARGET_TEMP_DIR)/$(arch),$(2),$(3),\
    $(call FAT_LIB_XCODE_FLAGS,$(arch))))

else
# Targets specific to a command-line build

emit_library_rules = $(foreach arch,$(J2OBJC_ARCHS),\
  $(eval $(call arch_lib_rule,$(BUILD_DIR)/objs-$(arch),$(1),$(2)))) \
  $(eval $(call fat_lib_rule,$(1),$(J2OBJC_ARCHS:%=$(BUILD_DIR)/objs-%/lib$(1).a)))

emit_arch_specific_compile_rules = $(foreach arch,$(J2OBJC_ARCHS),\
  $(call emit_compile_rules_for_arch,$(1),$(BUILD_DIR)/objs-$(arch),$(2),$(3),\
    $(call arch_flags,$(arch))))

endif

# Generate the compile and analyze rules for ObjC files.
# Args:
#   1. List of source directories.
#   2. Compile command.
#   3. Precompiled header file, or empty.
emit_compile_rules = $(call emit_arch_specific_compile_rules,$(1),$(2),$(3)) \
  $(foreach src_dir,$(1),$(eval $(call analyze_rule,$(src_dir),$(2))))

$(call emit_compile_rules,$(FAT_LIB_SOURCE_DIRS),$(FAT_LIB_COMPILE),$(FAT_LIB_PRECOMPILED_HEADER))

$(call emit_library_rules,$(FAT_LIB_NAME),$(FAT_LIB_OBJS))

analyze: $(FAT_LIB_PLISTS)
	@:

endif  # ifneq ($(MAKECMDGOALS),clean)
