#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include "_cgo_export.h"

// A tiny native menu bar host. Go sends the whole menu as JSON (see menubar.go);
// clicks are reported back with the item's id.

static const CGFloat kGraphWidth = 84, kGraphHeight = 22, kLabelWidth = 44;

static NSColor *namedColor(NSString *name) {
	if ([name isEqualToString:@"green"]) return NSColor.systemGreenColor;
	if ([name isEqualToString:@"orange"]) return NSColor.systemOrangeColor;
	if ([name isEqualToString:@"red"]) return NSColor.systemRedColor;
	if ([name isEqualToString:@"blue"]) return NSColor.systemBlueColor;
	if ([name isEqualToString:@"secondary"]) return NSColor.secondaryLabelColor;
	return nil;
}

static NSImage *symbolImage(NSString *name, NSString *color, CGFloat size) {
	if (name.length == 0) return nil;
	NSImage *img = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
	NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:size weight:NSFontWeightRegular];
	NSColor *c = namedColor(color);
	if (c) cfg = [cfg configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:c]];
	return [img imageWithSymbolConfiguration:cfg];
}

// Area chart of CPU usage with paused periods shaded, followed by the current value.
static NSImage *graphImage(NSDictionary *g) {
	NSArray<NSNumber *> *values = g[@"values"];
	NSArray<NSNumber *> *paused = g[@"paused"];
	NSString *label = g[@"label"] ?: @"";
	BOOL warn = [g[@"warn"] boolValue];
	NSSize size = NSMakeSize(kGraphWidth + kLabelWidth, kGraphHeight + 4);
	return [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect dst) {
		NSRect plot = NSMakeRect(0, 2, kGraphWidth, kGraphHeight);
		NSBezierPath *frame = [NSBezierPath bezierPathWithRoundedRect:plot xRadius:4 yRadius:4];
		[[NSColor.labelColor colorWithAlphaComponent:0.07] setFill];
		[frame fill];
		[NSGraphicsContext saveGraphicsState];
		[frame addClip];

		NSInteger capacity = [g[@"capacity"] integerValue];
		if (capacity < 2) capacity = 2;
		CGFloat step = kGraphWidth / (capacity - 1);
		CGFloat x0 = kGraphWidth - step * (values.count - 1);
		double top = 50; // keep idle noise flat, but make a few % visible
		for (NSNumber *v in values) top = MAX(top, v.doubleValue);

		for (NSUInteger i = 0; i < paused.count; i++) {
			if (!paused[i].boolValue) continue;
			[[NSColor.systemOrangeColor colorWithAlphaComponent:0.18] setFill];
			NSRectFill(NSMakeRect(x0 + step * i - step / 2, plot.origin.y, step, kGraphHeight));
		}

		if (values.count > 1) {
			NSColor *color = warn ? NSColor.systemOrangeColor : NSColor.controlAccentColor;
			NSBezierPath *line = [NSBezierPath bezierPath];
			for (NSUInteger i = 0; i < values.count; i++) {
				NSPoint p = NSMakePoint(x0 + step * i, plot.origin.y + 1 + (kGraphHeight - 3) * values[i].doubleValue / top);
				if (i == 0) [line moveToPoint:p]; else [line lineToPoint:p];
			}
			NSBezierPath *area = [line copy];
			[area lineToPoint:NSMakePoint(kGraphWidth, plot.origin.y)];
			[area lineToPoint:NSMakePoint(x0, plot.origin.y)];
			[area closePath];
			[[color colorWithAlphaComponent:0.25] setFill];
			[area fill];
			[color setStroke];
			line.lineWidth = 1.25;
			line.lineJoinStyle = NSLineJoinStyleRound;
			[line stroke];
		}
		[NSGraphicsContext restoreGraphicsState];

		NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
		ps.alignment = NSTextAlignmentRight;
		NSDictionary *attrs = @{
			NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium],
			NSForegroundColorAttributeName: warn ? NSColor.systemOrangeColor : NSColor.labelColor,
			NSParagraphStyleAttributeName: ps,
		};
		[label drawInRect:NSMakeRect(kGraphWidth, 6, kLabelWidth, 16) withAttributes:attrs];
		return YES;
	}];
}

static NSAttributedString *itemTitle(NSDictionary *d) {
	NSString *title = d[@"title"] ?: @"";
	NSString *subtitle = d[@"subtitle"];
	NSFont *font = [d[@"mono"] boolValue] ? [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular]
	                                      : [NSFont menuFontOfSize:0];
	if ([d[@"bold"] boolValue]) font = [NSFont boldSystemFontOfSize:13];
	NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:title
		attributes:@{NSFontAttributeName: font}];
	if (subtitle.length) {
		[s appendAttributedString:[[NSAttributedString alloc] initWithString:[@"\n" stringByAppendingString:subtitle]
			attributes:@{
				NSFontAttributeName: [NSFont systemFontOfSize:11],
				NSForegroundColorAttributeName: NSColor.secondaryLabelColor,
			}]];
	}
	return s;
}

@interface Controller : NSObject <NSMenuDelegate>
@property(strong) NSStatusItem *statusItem;
@property(strong) NSMenu *menu;
@property(strong) NSString *structure;
@property(strong) NSDictionary *pending; // model whose structure changed while the menu was open
@property BOOL open;
@end

@implementation Controller

- (void)clicked:(NSMenuItem *)item {
	menuClicked((char *)[item.representedObject UTF8String]);
}

- (void)menuWillOpen:(NSMenu *)menu {
	if (menu != self.menu) return;
	self.open = YES;
	menuOpened();
}

- (void)menuDidClose:(NSMenu *)menu {
	if (menu != self.menu) return;
	self.open = NO;
	self.statusItem.menu = nil;
	menuClosed();
	if (self.pending) {
		NSDictionary *model = self.pending;
		self.pending = nil;
		[self apply:model];
	}
}

// Ids and kinds of all items; when unchanged, items are updated in place so an
// open menu refreshes live instead of being rebuilt.
static NSString *structureOf(NSArray *items) {
	NSMutableString *s = [NSMutableString string];
	for (NSDictionary *d in items) {
		[s appendFormat:@"%@/%@[%@]", d[@"kind"] ?: @"", d[@"id"] ?: @"", structureOf(d[@"children"] ?: @[])];
	}
	return s;
}

// Only assigns properties that changed: touching an item whose submenu is
// open makes AppKit close and reopen that submenu.
- (void)configure:(NSMenuItem *)item with:(NSDictionary *)d {
	BOOL hidden = [d[@"hidden"] boolValue];
	if (item.hidden != hidden) item.hidden = hidden;
	NSString *kind = d[@"kind"] ?: @"";
	if ([kind isEqualToString:@"separator"]) return;
	if ([kind isEqualToString:@"section"]) {
		if (![item.title isEqualToString:d[@"title"] ?: @""]) item.title = d[@"title"] ?: @"";
		return;
	}
	NSAttributedString *title = itemTitle(d);
	if (![item.attributedTitle isEqualToAttributedString:title]) item.attributedTitle = title;

	NSDictionary *graph = d[@"graph"];
	NSString *imageKey = graph ? [NSString stringWithFormat:@"%@", graph]
	                           : [NSString stringWithFormat:@"%@|%@", d[@"symbol"] ?: @"", d[@"color"] ?: @""];
	if (![item.identifier isEqualToString:imageKey]) {
		item.identifier = imageKey;
		item.image = graph ? graphImage(graph) : symbolImage(d[@"symbol"], d[@"color"], 14);
	}

	NSControlStateValue state = [d[@"checked"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
	if (item.state != state) item.state = state;
	BOOL enabled = ![d[@"disabled"] boolValue];
	if (item.enabled != enabled) item.enabled = enabled;
	NSString *ident = d[@"id"];
	if (![item.representedObject isEqual:ident]) {
		item.representedObject = ident;
		item.target = self;
		item.action = ident.length ? @selector(clicked:) : nil;
	}
	NSString *tooltip = d[@"tooltip"];
	if (item.toolTip != tooltip && ![item.toolTip isEqualToString:tooltip]) item.toolTip = tooltip;
}

- (NSMenuItem *)build:(NSDictionary *)d {
	NSString *kind = d[@"kind"] ?: @"";
	if ([kind isEqualToString:@"separator"]) {
		NSMenuItem *sep = [NSMenuItem separatorItem];
		sep.hidden = [d[@"hidden"] boolValue];
		return sep;
	}
	NSMenuItem *item = [kind isEqualToString:@"section"] ? [NSMenuItem sectionHeaderWithTitle:d[@"title"] ?: @""]
	                                                      : [[NSMenuItem alloc] init];
	[self configure:item with:d];
	NSArray *children = d[@"children"];
	if (children.count) {
		NSMenu *sub = [[NSMenu alloc] init];
		sub.autoenablesItems = NO;
		for (NSDictionary *c in children) [sub addItem:[self build:c]];
		item.submenu = sub;
	}
	return item;
}

- (void)update:(NSMenu *)menu with:(NSArray *)items {
	for (NSUInteger i = 0; i < items.count && i < menu.numberOfItems; i++) {
		NSMenuItem *item = [menu itemAtIndex:i];
		[self configure:item with:items[i]];
		if (item.submenu) [self update:item.submenu with:items[i][@"children"] ?: @[]];
	}
}

- (void)apply:(NSDictionary *)model {
	NSStatusBarButton *button = self.statusItem.button;
	NSImage *icon = symbolImage(model[@"icon"], nil, 15);
	icon.template = YES;
	button.image = icon;
	button.contentTintColor = namedColor(model[@"iconColor"]);
	button.title = model[@"buttonTitle"] ?: @"";
	button.imagePosition = button.title.length ? NSImageLeading : NSImageOnly;

	NSArray *items = model[@"items"] ?: @[];
	NSString *structure = structureOf(items);
	if ([structure isEqualToString:self.structure]) {
		[self update:self.menu with:items];
		return;
	}
	if (self.open) {
		self.pending = model;
		return;
	}
	self.structure = structure;
	[self.menu removeAllItems];
	for (NSDictionary *d in items) [self.menu addItem:[self build:d]];
}
@end

static Controller *controller;

// Web views (popover and settings window) talk to Go through a script message
// handler: no local HTTP server, so nothing else on the machine can call into them.
@interface WebBridge : NSObject <WKScriptMessageHandler, NSWindowDelegate, NSPopoverDelegate>
@property(copy) NSString *name;
@end

static NSPopover *popover;
static WKWebView *popoverView, *settingsView;
static NSWindow *settingsWindow;
static WebBridge *popoverBridge, *settingsBridge;
static NSString *popoverHTML;

@implementation WebBridge
- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)message {
	if (![message.body isKindOfClass:NSString.class]) return;
	NSString *body = message.body;
	NSDictionary *msg = [NSJSONSerialization JSONObjectWithData:[body dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
	if ([msg[@"action"] isEqualToString:@"resize"] && popover) {
		NSScreen *screen = controller.statusItem.button.window.screen ?: NSScreen.mainScreen;
		CGFloat h = MIN(MAX([msg[@"h"] doubleValue], 200), NSHeight(screen.visibleFrame) - 40);
		if (fabs(popover.contentSize.height - h) > 0.5) popover.contentSize = NSMakeSize(380, h);
		return;
	}
	webMessage((char *)body.UTF8String);
}
- (void)windowWillClose:(NSNotification *)notification { webVisibility((char *)self.name.UTF8String, 0); }
- (void)popoverDidShow:(NSNotification *)notification { webVisibility((char *)self.name.UTF8String, 1); }
- (void)popoverDidClose:(NSNotification *)notification { webVisibility((char *)self.name.UTF8String, 0); }
@end

static WKWebView *makeWebView(WebBridge *bridge, NSRect frame) {
	WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
	[cfg.userContentController addScriptMessageHandler:bridge name:@"aipause"];
	WKWebView *view = [[WKWebView alloc] initWithFrame:frame configuration:cfg];
	[view setValue:@NO forKey:@"drawsBackground"];
	return view;
}

@implementation Controller (Popover)
- (void)statusClicked:(NSStatusBarButton *)sender {
	NSEvent *event = NSApp.currentEvent;
	BOOL secondary = event.type == NSEventTypeRightMouseUp || (event.modifierFlags & NSEventModifierFlagControl);
	if (secondary) {
		// The classic menu stays available on right-click.
		[popover performClose:nil];
		self.statusItem.menu = self.menu;
		[sender performClick:nil];
		return;
	}
	if (popover.shown) {
		[popover performClose:nil];
		return;
	}
	if (!popover) {
		popoverBridge = [WebBridge new];
		popoverBridge.name = @"popover";
		popoverView = makeWebView(popoverBridge, NSMakeRect(0, 0, 380, 560));
		[popoverView loadHTMLString:popoverHTML baseURL:nil];
		NSViewController *vc = [NSViewController new];
		vc.view = popoverView;
		popover = [NSPopover new];
		popover.contentViewController = vc;
		popover.contentSize = NSMakeSize(380, 560);
		popover.behavior = NSPopoverBehaviorTransient;
		popover.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
		popover.delegate = popoverBridge;
	}
	[NSApp activateIgnoringOtherApps:YES];
	[popover showRelativeToRect:sender.bounds ofView:sender preferredEdge:NSRectEdgeMinY];
}
@end

void setPopoverHTML(char *html, int length) {
	popoverHTML = [[NSString alloc] initWithBytes:html length:length encoding:NSUTF8StringEncoding];
}

void closePopover(void) {
	dispatch_async(dispatch_get_main_queue(), ^{ [popover performClose:nil]; });
}

void openSettings(char *html, int length) {
	NSString *page = [[NSString alloc] initWithBytes:html length:length encoding:NSUTF8StringEncoding];
	dispatch_async(dispatch_get_main_queue(), ^{
		[popover performClose:nil];
		if (!settingsWindow) {
			settingsBridge = [WebBridge new];
			settingsBridge.name = @"settings";
			settingsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 640)
				styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
				backing:NSBackingStoreBuffered defer:NO];
			settingsWindow.title = @"AI Pause Settings";
			settingsWindow.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
			settingsWindow.backgroundColor = [NSColor colorWithSRGBRed:0.078 green:0.078 blue:0.086 alpha:1];
			settingsWindow.releasedWhenClosed = NO;
			settingsWindow.delegate = settingsBridge;
			settingsWindow.minSize = NSMakeSize(520, 400);
			settingsWindow.frameAutosaveName = @"settings";
			settingsView = makeWebView(settingsBridge, settingsWindow.contentView.bounds);
			settingsView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
			settingsWindow.contentView = settingsView;
			[settingsView loadHTMLString:page baseURL:nil];
			if (![settingsWindow setFrameUsingName:@"settings"]) [settingsWindow center];
		}
		[NSApp activateIgnoringOtherApps:YES];
		[settingsWindow makeKeyAndOrderFront:nil];
		webVisibility("settings", 1);
	});
}

void pushWeb(char *json, int length) {
	NSString *data = [[NSString alloc] initWithBytes:json length:length encoding:NSUTF8StringEncoding];
	dispatch_async(dispatch_get_main_queue(), ^{
		NSString *js = [NSString stringWithFormat:@"window.aipauseUpdate && window.aipauseUpdate(%@)", data];
		if (popover.shown) [popoverView evaluateJavaScript:js completionHandler:nil];
		if (settingsWindow.visible) [settingsView evaluateJavaScript:js completionHandler:nil];
	});
}

// Accessory apps have no visible menu bar, but key equivalents (copy/paste in
// the settings form, ⌘W) still go through the main menu.
static void installMainMenu(void) {
	NSMenu *main = [NSMenu new];
	NSMenuItem *appItem = [main addItemWithTitle:@"" action:nil keyEquivalent:@""];
	NSMenu *app = [NSMenu new];
	[app addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];
	appItem.submenu = app;
	NSMenuItem *editItem = [main addItemWithTitle:@"Edit" action:nil keyEquivalent:@""];
	NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
	[edit addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
	[edit addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
	[edit addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
	[edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
	[edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
	[edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
	editItem.submenu = edit;
	NSApp.mainMenu = main;
}

void runApp(void) {
	@autoreleasepool {
		[NSApplication sharedApplication];
		[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
		installMainMenu();
		controller = [Controller new];
		controller.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
		controller.menu = [[NSMenu alloc] init];
		controller.menu.autoenablesItems = NO;
		controller.menu.delegate = controller;
		NSStatusBarButton *button = controller.statusItem.button;
		button.target = controller;
		button.action = @selector(statusClicked:);
		[button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];
		menuReady();
		[NSApp run];
	}
}

void setModel(char *json, int length) {
	NSData *data = [NSData dataWithBytes:json length:length];
	dispatch_async(dispatch_get_main_queue(), ^{
		NSDictionary *model = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
		if (model) [controller apply:model];
	});
}
