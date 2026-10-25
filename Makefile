# AI Pause: menu bar app (Go + SwiftUI) that pauses AI agents during calls and games.
#
#   make                  build build/ai-pause for this Mac
#   make app              build build/AI Pause.app
#   make install          install to ~/Applications, link the CLI and start it at login
#   make screenshots      regenerate docs/*.png from docs/demo.json
#
# Releasing (Developer ID signing, notarization, GitHub release, Homebrew tap):
#
#   make sign-check                      show the identity and notary profile in use
#   make release                         universal, signed, notarized build/AI-Pause-<version>.zip
#   make release-publish VERSION=0.2.0   tag, build, notarize, upload, update the tap
#   make tap VERSION=0.2.0               point the tap at an existing release again

APP_VERSION := $(shell cat VERSION)
APP         := build/AI Pause.app
INSTALL_DIR ?= $(HOME)/Applications
# UNIVERSAL=1 builds arm64 and x86_64 in one binary; releases always do.
UNIVERSAL   ?=
ARCHS        = $(if $(UNIVERSAL),arm64 x86_64,$(shell uname -m))
SDK         := $(shell xcrun --show-sdk-path)
SWIFTC      ?= xcrun swiftc
SWIFT_SRC   := $(wildcard app/ui/*.swift)
GO_SRC      := $(wildcard app/*.go app/*.m) go.mod go.sum
# Local builds are signed with the Developer ID when there is one, so macOS keeps treating
# rebuilds as the same app. Without one (or with LOCAL_IDENTITY=-) the signature is ad-hoc.
LOCAL_IDENTITY ?= $(or $(shell security find-identity -v -p codesigning 2>/dev/null \
	| grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"'),-)

goarch = $(if $(filter x86_64,$(1)),amd64,arm64)

.PHONY: all build app install screenshots release release-publish tap sign-check clean

all: build

build: build/ai-pause

# The SwiftUI views, one static library per architecture.
build/%/libaipauseui.a: $(SWIFT_SRC) app/ui/bridge.h
	@mkdir -p $(@D)
	$(SWIFTC) -emit-library -static -parse-as-library -O -swift-version 5 -module-name AIPauseUI \
		-target $*-apple-macos14.0 -import-objc-header app/ui/bridge.h -o $@ $(SWIFT_SRC)

# The hash makes Go relink when only the Swift library changed.
build/%/ai-pause: build/%/libaipauseui.a $(GO_SRC) VERSION
	CGO_ENABLED=1 GOARCH=$(call goarch,$*) CC="clang -arch $*" \
	CGO_CFLAGS="-mmacosx-version-min=14.0" \
	CGO_LDFLAGS="-L$(SDK)/usr/lib/swift -L/usr/lib/swift -L$(CURDIR)/build/$* -mmacosx-version-min=14.0" \
		go build -trimpath -ldflags "-s -w -X main.version=$(APP_VERSION) -X main.uiLibHash=$$(shasum $< | cut -c1-12)" \
		-o $@ ./app

build/ai-pause: $(foreach a,$(ARCHS),build/$(a)/ai-pause)
	lipo -create -output $@ $^

app: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS"
	cp build/ai-pause "$(APP)/Contents/MacOS/ai-pause"
	cp app/Info.plist "$(APP)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(APP_VERSION)" \
		-c "Set :CFBundleVersion $(APP_VERSION)" "$(APP)/Contents/Info.plist"
	codesign --force --timestamp=none --options runtime --sign "$(LOCAL_IDENTITY)" "$(APP)"

# Installs the app, puts the CLI on PATH and starts it at login.
install: app
	mkdir -p "$(INSTALL_DIR)" "$(HOME)/.local/bin"
	rm -rf "$(INSTALL_DIR)/AI Pause.app"
	cp -R "$(APP)" "$(INSTALL_DIR)/"
	ln -sf "$(INSTALL_DIR)/AI Pause.app/Contents/MacOS/ai-pause" "$(HOME)/.local/bin/ai-pause"
	"$(INSTALL_DIR)/AI Pause.app/Contents/MacOS/ai-pause" install-login

# Renders the SwiftUI views offscreen with made-up data.
screenshots:
	@mkdir -p build
	$(SWIFTC) -swift-version 5 -parse-as-library -module-name Screenshots \
		$(filter-out app/ui/Exports.swift,$(SWIFT_SRC)) scripts/screenshots.swift -o build/screenshots
	build/screenshots docs/demo.json docs

release:
	$(MAKE) --no-print-directory app UNIVERSAL=1
	scripts/release.sh

release-publish:
	@test -n "$(VERSION)" || { echo "usage: make release-publish VERSION=0.2.0"; exit 1; }
	scripts/publish-release.sh $(VERSION)

tap:
	@test -n "$(VERSION)" || { echo "usage: make tap VERSION=0.2.0"; exit 1; }
	scripts/update-tap.sh $(VERSION)

sign-check:
	@security find-identity -v -p codesigning | grep "Developer ID Application" \
		|| echo "no Developer ID Application certificate in the keychain"
	@xcrun notarytool history --keychain-profile $(or $(NOTARY_PROFILE),notarytool) >/dev/null 2>&1 \
		&& echo "  notary profile: $(or $(NOTARY_PROFILE),notarytool) ✓" \
		|| echo "  notary profile $(or $(NOTARY_PROFILE),notarytool) is not stored yet, see scripts/release.sh"

clean:
	rm -rf build
