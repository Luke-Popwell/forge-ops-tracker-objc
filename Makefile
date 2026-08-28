# Builds this SDK's sources and tests into a plain .xctest bundle via clang directly -- no
# .xcodeproj/xcworkspace needed. See README.md's "Running the tests" section for why: this is a
# library meant to be dropped into a host app's own Xcode project (via SwiftPM/CocoaPods/manual
# file references, README.md covers all three), not an app itself, so there's no app target to
# build here in the first place.

SDK := $(shell xcrun --sdk macosx --show-sdk-path)
PLATFORM_FRAMEWORKS := /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks
BUILD := build
BUNDLE := $(BUILD)/ForgeOpsTrackerTests.xctest

SOURCES := $(wildcard Sources/ForgeOpsTracker/*.m)
TESTS := $(wildcard Tests/*.m)

.PHONY: test clean

test: $(BUNDLE)
	xcrun xctest $(BUNDLE)

$(BUNDLE): $(SOURCES) $(TESTS)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp Tests/Info.plist $(BUNDLE)/Contents/Info.plist
	clang -dynamiclib \
		-fobjc-arc \
		-F $(PLATFORM_FRAMEWORKS) \
		-framework XCTest \
		-framework Foundation \
		-isysroot $(SDK) \
		-Wl,-rpath,$(PLATFORM_FRAMEWORKS) \
		-Wall -Wextra -Wno-unused-parameter \
		-ISources/ForgeOpsTracker \
		-ITests \
		-o $(BUNDLE)/Contents/MacOS/ForgeOpsTrackerTests \
		$(SOURCES) $(TESTS)

clean:
	rm -rf $(BUILD)
