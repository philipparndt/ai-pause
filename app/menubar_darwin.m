#import <Cocoa/Cocoa.h>
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

// A symbol's alignment rect is its cap-height band, which the status bar
// centers instead of the glyph, so the icon sat higher than the system ones.
// Redrawn, the alignment rect is the whole image and the glyph is centered.
static NSImage *statusIcon(NSImage *symbol) {
	if (!symbol) return nil;
	NSImage *img = [NSImage imageWithSize:symbol.size flipped:NO drawingHandler:^BOOL(NSRect dst) {
		[symbol drawInRect:dst];
		return YES;
	}];
	img.template = YES;
	return img;
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
	NSImage *icon = statusIcon(symbolImage(model[@"icon"], nil, 15));
	button.image = icon;
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

// The popover and settings window are SwiftUI (ui/*.swift).
void aipause_ui_init(void);
void aipause_ui_toggle_popover(void *button);
void aipause_ui_close_popover(void);

@implementation Controller (Popover)
- (void)statusClicked:(NSStatusBarButton *)sender {
	NSEvent *event = NSApp.currentEvent;
	BOOL secondary = event.type == NSEventTypeRightMouseUp || (event.modifierFlags & NSEventModifierFlagControl);
	if (secondary) {
		// The classic menu stays available on right-click.
		aipause_ui_close_popover();
		self.statusItem.menu = self.menu;
		[sender performClick:nil];
		return;
	}
	aipause_ui_toggle_popover((__bridge void *)sender);
}
@end

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
		aipause_ui_init();
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
