APP := build/AI Pause.app
BIN := $(APP)/Contents/MacOS/ai-pause
INSTALL_DIR := $(HOME)/Applications

.PHONY: build app install clean

build:
	go build -o build/ai-pause .

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
