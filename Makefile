APP := build/AI Pause.app
BIN := $(APP)/Contents/MacOS/ai-pause
INSTALL_DIR := $(HOME)/Applications

SWIFT_SRC := $(wildcard ui/*.swift)
UI_LIB := build/libaipauseui.a
ARCH := $(shell uname -m)
SDK := $(shell xcrun --show-sdk-path)
# The SwiftUI static library pulls in the Swift runtime from the OS.
export CGO_LDFLAGS := -L$(SDK)/usr/lib/swift -L/usr/lib/swift

.PHONY: build app install clean

$(UI_LIB): $(SWIFT_SRC) ui/bridge.h
	mkdir -p build
	swiftc -emit-library -static -parse-as-library -O -swift-version 5 -module-name AIPauseUI \
		-target $(ARCH)-apple-macos14.0 -import-objc-header ui/bridge.h -o $@ $(SWIFT_SRC)

# The hash makes Go relink when only the Swift library changed.
build: $(UI_LIB)
	go build -ldflags "-X main.uiLibHash=$$(shasum $(UI_LIB) | cut -c1-12)" -o build/ai-pause .

app: build
	mkdir -p "$(APP)/Contents/MacOS"
	cp build/ai-pause "$(BIN)"
	cp Info.plist "$(APP)/Contents/Info.plist"
	codesign -s - --force "$(APP)"

# Installs the app, puts the CLI on PATH and starts it at login.
install: app
	mkdir -p "$(INSTALL_DIR)" "$(HOME)/.local/bin"
	rm -rf "$(INSTALL_DIR)/AI Pause.app"
	cp -R "$(APP)" "$(INSTALL_DIR)/"
	ln -sf "$(INSTALL_DIR)/AI Pause.app/Contents/MacOS/ai-pause" "$(HOME)/.local/bin/ai-pause"
	"$(INSTALL_DIR)/AI Pause.app/Contents/MacOS/ai-pause" install-login

clean:
	rm -rf build
