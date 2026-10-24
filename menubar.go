package main

/*
#cgo CFLAGS: -x objective-c -fobjc-arc -mmacosx-version-min=14.0
#cgo LDFLAGS: -framework Cocoa -framework WebKit
void runApp(void);
void setModel(char *json, int length);
*/
import "C"

import (
	"encoding/json"
	"runtime"
	"unsafe"
)

func init() {
	// Cocoa must run on the main thread, which is the one main() starts on.
	runtime.LockOSThread()
}

type Graph struct {
	Values   []float64 `json:"values"`
	Paused   []bool    `json:"paused"`
	Capacity int       `json:"capacity"`
	Label    string    `json:"label"`
	Warn     bool      `json:"warn,omitempty"`
}

type MenuItem struct {
	ID       string     `json:"id,omitempty"`
	Kind     string     `json:"kind,omitempty"` // "", "separator", "section"
	Title    string     `json:"title,omitempty"`
	Subtitle string     `json:"subtitle,omitempty"`
	Tooltip  string     `json:"tooltip,omitempty"`
	Symbol   string     `json:"symbol,omitempty"` // SF Symbol name
	Color    string     `json:"color,omitempty"`  // green, orange, red, blue, secondary
	Bold     bool       `json:"bold,omitempty"`
	Mono     bool       `json:"mono,omitempty"`
	Checked  bool       `json:"checked,omitempty"`
	Disabled bool       `json:"disabled,omitempty"`
	Hidden   bool       `json:"hidden,omitempty"`
	Graph    *Graph     `json:"graph,omitempty"`
	Children []MenuItem `json:"children,omitempty"`
}

type MenuModel struct {
	Icon        string     `json:"icon"`
	IconColor   string     `json:"iconColor,omitempty"`
	ButtonTitle string     `json:"buttonTitle,omitempty"`
	Items       []MenuItem `json:"items"`
}

func separator() MenuItem           { return MenuItem{Kind: "separator"} }
func section(title string) MenuItem { return MenuItem{Kind: "section", Title: title} }

var (
	onMenuReady  func()
	onMenuClick  func(id string)
	onMenuOpened func()
	onMenuClosed func()
)

// runMenuBar blocks running the Cocoa event loop.
func runMenuBar(ready func(), click func(id string), opened, closed func()) {
	onMenuReady, onMenuClick, onMenuOpened, onMenuClosed = ready, click, opened, closed
	C.runApp()
}

func setMenuModel(m MenuModel) {
	data, err := json.Marshal(m)
	if err != nil {
		return
	}
	C.setModel((*C.char)(unsafe.Pointer(&data[0])), C.int(len(data)))
}

//export menuReady
func menuReady() { go onMenuReady() }

//export menuClicked
func menuClicked(id *C.char) {
	s := C.GoString(id)
	go onMenuClick(s)
}

//export menuOpened
func menuOpened() { go onMenuOpened() }

//export menuClosed
func menuClosed() { go onMenuClosed() }
