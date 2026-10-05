// LaunchSpike (Objective-C port) — verifies three design assumptions:
//   A1: a .nonactivatingPanel NSPanel takes real keyboard focus
//   A2: CGEvent Cmd+V injects into the restored frontmost app
//   A3: Option+Space registers as a global hotkey
//
// Ported from the Swift version because this machine's Command Line Tools are
// inconsistent (duplicate swift/bridging.modulemap redefines module
// 'SwiftBridging'), which makes every Swift compile fail. The APIs under test
// are AppKit/Carbon/CoreGraphics and identical in both languages.

#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <ApplicationServices/ApplicationServices.h>

// MARK: - logging

static NSString *LogDirectory(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/LaunchSpike"];
}
static NSString *LogFilePath(void) {
    return [LogDirectory() stringByAppendingPathComponent:@"spike.log"];
}

static void SPIKE_LOG(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [formatter stringFromDate:[NSDate date]], message];

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:LogDirectory()]) {
        [fm createDirectoryAtPath:LogDirectory() withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if ([fm fileExistsAtPath:LogFilePath()]) {
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:LogFilePath()];
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
    } else {
        [data writeToFile:LogFilePath() atomically:YES];
    }
    fputs(line.UTF8String, stderr);
}

static NSString *DescribeApp(NSRunningApplication *app) {
    if (!app) return @"nil";
    return [NSString stringWithFormat:@"%@ [%@] pid=%d",
            app.localizedName ?: @"?", app.bundleIdentifier ?: @"?", app.processIdentifier];
}
static NSString *DescribeFrontmost(void) {
    return DescribeApp([[NSWorkspace sharedWorkspace] frontmostApplication]);
}

// MARK: - classes

static OSStatus HotKeyHandler(EventHandlerCallRef nextHandler, EventRef event, void *userData);

@interface KeyPanel : NSPanel @end
@implementation KeyPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSTextFieldDelegate>
@property (nonatomic, strong) KeyPanel *panel;
@property (nonatomic, strong) NSTextField *field;
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSRunningApplication *previousApp;
@property (nonatomic, assign) BOOL didPromptForAccessibility;
@property (nonatomic, copy) NSString *pendingInjectText;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    SPIKE_LOG(@"=================== LAUNCH ===================");
    SPIKE_LOG(@"bundleID=%@", [[NSBundle mainBundle] bundleIdentifier] ?: @"nil");
    SPIKE_LOG(@"executable=%@", [[NSBundle mainBundle] executablePath] ?: @"?");
    SPIKE_LOG(@"AXIsProcessTrusted=%d", AXIsProcessTrusted());
    SPIKE_LOG(@"activationPolicy=%ld (0=regular,1=accessory,2=prohibited)", (long)[NSApp activationPolicy]);
    SPIKE_LOG(@"frontmost at launch=%@", DescribeFrontmost());

    [self buildPanel];
    [self installStatusItem];
    [self registerHotKeys];
    [self requestAccessibilityIfNeeded];

    SPIKE_LOG(@"READY: Option+Space = nonactivating path, Control+Option+Space = activating path");
}

- (void)requestAccessibilityIfNeeded {
    if (AXIsProcessTrusted()) {
        SPIKE_LOG(@"accessibility: ALREADY TRUSTED (inherited from the launching process)");
        return;
    }
    NSDictionary *options = @{ (__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES };
    BOOL trustedNow = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    SPIKE_LOG(@"accessibility: prompt requested, trustedNow=%d", trustedNow);
}

// MARK: panel

- (void)buildPanel {
    NSSize size = NSMakeSize(640, 64);
    self.panel = [[KeyPanel alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
                                             styleMask:(NSWindowStyleMaskNonactivatingPanel | NSWindowStyleMaskBorderless)
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    self.panel.level = NSFloatingWindowLevel;
    self.panel.floatingPanel = YES;
    self.panel.hidesOnDeactivate = NO;
    self.panel.becomesKeyOnlyIfNeeded = NO;
    self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.panel.backgroundColor = [NSColor windowBackgroundColor];
    self.panel.opaque = YES;
    self.panel.hasShadow = YES;
    self.panel.movable = NO;

    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    self.field = [[NSTextField alloc] initWithFrame:NSMakeRect(18, 20, size.width - 36, 24)];
    self.field.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin | NSViewMaxYMargin;
    self.field.font = [NSFont systemFontOfSize:18];
    self.field.bordered = NO;
    self.field.drawsBackground = NO;
    self.field.focusRingType = NSFocusRingTypeNone;
    self.field.placeholderString = @"spike: type, Enter = inject snippet, Esc = cancel";
    self.field.target = self;
    self.field.action = @selector(performPaste);
    self.field.delegate = self;
    [container addSubview:self.field];
    self.panel.contentView = container;

    NSScreen *screen = [NSScreen mainScreen];
    if (screen) {
        NSRect visible = screen.visibleFrame;
        [self.panel setFrameOrigin:NSMakePoint(NSMidX(visible) - size.width / 2,
                                               NSMaxY(visible) - size.height - 140)];
    }
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector {
    if (commandSelector == @selector(cancelOperation:)) {
        SPIKE_LOG(@"escape pressed -> hide");
        [self hidePanel];
        return YES;
    }
    return NO;
}

- (void)installStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"SPIKE";
    NSMenu *menu = [[NSMenu alloc] init];
    NSMenuItem *showItem = [[NSMenuItem alloc] initWithTitle:@"Show panel" action:@selector(menuShow) keyEquivalent:@""];
    showItem.target = self;
    [menu addItem:showItem];
    [menu addItem:[[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"]];
    self.statusItem.menu = menu;
}

- (void)menuShow { [self showPanelActivating:NO]; }

- (void)handleHotKey:(UInt32)identifier {
    if (identifier == 1) {
        [self showPanelActivating:NO];
    } else if (identifier == 2) {
        [self showPanelActivating:YES];
    } else {
        SPIKE_LOG(@"unknown hotkey id=%u", (unsigned)identifier);
    }
}

- (void)showPanelActivating:(BOOL)activating {
    NSRunningApplication *current = [[NSWorkspace sharedWorkspace] frontmostApplication];
    if (current && ![current.bundleIdentifier isEqualToString:[[NSBundle mainBundle] bundleIdentifier]]) {
        self.previousApp = current;
    }
    SPIKE_LOG(@"showPanel activating=%d previousApp=%@", activating, DescribeApp(self.previousApp));
    self.field.stringValue = @"";
    if (activating) {
        // A/B: does the panel keep focus while staying an accessory app (no Dock
        // icon, no menu-bar takeover), or is a temporary .regular policy required?
        BOOL useRegularPolicy = [[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/use_regular_policy.txt"];
        if (useRegularPolicy) {
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        }
        SPIKE_LOG(@"  useRegularPolicy=%d", useRegularPolicy);
        [NSApp activateIgnoringOtherApps:YES];
    }
    [self.panel makeKeyAndOrderFront:nil];
    [self.panel makeFirstResponder:self.field];
    SPIKE_LOG(@"  +0ms: NSApp.isActive=%d panel.isKeyWindow=%d frontmost=%@",
              [NSApp isActive], [self.panel isKeyWindow], DescribeFrontmost());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SPIKE_LOG(@"  +150ms: NSApp.isActive=%d panel.isKeyWindow=%d frontmost=%@",
                  [NSApp isActive], [self.panel isKeyWindow], DescribeFrontmost());
    });
}

- (void)hidePanel {
    [self.panel orderOut:nil];
    if ([NSApp activationPolicy] == NSApplicationActivationPolicyRegular) {
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    }
    SPIKE_LOG(@"hidden: frontmost=%@", DescribeFrontmost());
}

// MARK: injection

- (void)performPaste {
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    NSString *text = [NSString stringWithFormat:@"LaunchSpike-OK %@", [formatter stringFromDate:[NSDate date]]];
    SPIKE_LOG(@"action Enter: injectedText=\"%@\" typedIntoPanel=\"%@\"", text, self.field.stringValue);
    self.pendingInjectText = text;
    SPIKE_LOG(@"  pre-hide: frontmost=%@ AXtrusted=%d", DescribeFrontmost(), AXIsProcessTrusted());

    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    NSString *savedClipboard = [pasteboard stringForType:NSPasteboardTypeString];
    [pasteboard clearContents];
    [pasteboard setString:text forType:NSPasteboardTypeString];

    NSRunningApplication *target = self.previousApp;
    [self.panel orderOut:nil];
    if ([NSApp activationPolicy] == NSApplicationActivationPolicyRegular) {
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    }

    if (target && !target.terminated) {
        BOOL ok = [target activateWithOptions:NSApplicationActivateIgnoringOtherApps];
        SPIKE_LOG(@"  activate target %@ ok=%d", DescribeApp(target), ok);
    } else {
        SPIKE_LOG(@"  WARNING: no valid target app recorded; injecting into whatever is frontmost");
    }

    NSString *mode = [[NSString stringWithContentsOfFile:@"/tmp/inject_mode.txt" encoding:NSUTF8StringEncoding error:NULL]
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (mode.length == 0) mode = @"hid";
    NSString *delayText = [NSString stringWithContentsOfFile:@"/tmp/inject_delay_ms.txt" encoding:NSUTF8StringEncoding error:NULL];
    double delayMs = delayText.length ? [delayText doubleValue] : 400.0;
    SPIKE_LOG(@"  injectMode=%@ injectDelayMs=%.0f", mode, delayMs);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayMs / 1000.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SPIKE_LOG(@"  +%.0fms: frontmost=%@ targetIsActive=%d", delayMs, DescribeFrontmost(), target.isActive);
        BOOL posted = [self postCommandVWithMode:mode];
        SPIKE_LOG(@"  posted Cmd+V mode=%@ ok=%d", mode, posted);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [pasteboard clearContents];
            if (savedClipboard) {
                [pasteboard setString:savedClipboard forType:NSPasteboardTypeString];
                SPIKE_LOG(@"  clipboard restored");
            } else {
                SPIKE_LOG(@"  clipboard cleared (no previous content)");
            }
        });
    });
}

- (BOOL)postCommandVWithMode:(NSString *)mode {
    if (!AXIsProcessTrusted()) {
        SPIKE_LOG(@"  postCommandV: REFUSED, process is not AX-trusted");
        return NO;
    }
    NSRunningApplication *target = self.previousApp;

    if ([mode isEqualToString:@"type"]) {
        NSString *text = self.pendingInjectText ?: @"";
        CGEventSourceRef typeSource = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
        for (NSUInteger index = 0; index < text.length; index++) {
            UniChar character = [text characterAtIndex:index];
            CGEventRef down = CGEventCreateKeyboardEvent(typeSource, 0, true);
            CGEventKeyboardSetUnicodeString(down, 1, &character);
            CGEventPost(kCGHIDEventTap, down);
            CFRelease(down);
            CGEventRef up = CGEventCreateKeyboardEvent(typeSource, 0, false);
            CGEventKeyboardSetUnicodeString(up, 1, &character);
            CGEventPost(kCGHIDEventTap, up);
            CFRelease(up);
            usleep(12000);
        }
        CFRelease(typeSource);
        SPIKE_LOG(@"  -> typed %lu characters via unicode key events", (unsigned long)text.length);
        return YES;
    }

    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    if (!source) {
        SPIKE_LOG(@"  postCommandV: CGEventSourceCreate failed");
        return NO;
    }
    CGEventRef keyDown = CGEventCreateKeyboardEvent(source, (CGKeyCode)kVK_ANSI_V, true);
    CGEventRef keyUp = CGEventCreateKeyboardEvent(source, (CGKeyCode)kVK_ANSI_V, false);
    if (!keyDown || !keyUp) {
        SPIKE_LOG(@"  postCommandV: CGEventCreateKeyboardEvent failed");
        if (keyDown) CFRelease(keyDown);
        if (keyUp) CFRelease(keyUp);
        CFRelease(source);
        return NO;
    }
    CGEventSetFlags(keyDown, kCGEventFlagMaskCommand);
    CGEventSetFlags(keyUp, kCGEventFlagMaskCommand);

    BOOL wantPID = ([mode isEqualToString:@"pid"] || [mode isEqualToString:@"both"]) && target && !target.terminated;
    BOOL wantHID = [mode isEqualToString:@"hid"] || [mode isEqualToString:@"both"];

    if (wantPID) {
        CGEventPostToPid(target.processIdentifier, keyDown);
        CGEventPostToPid(target.processIdentifier, keyUp);
        SPIKE_LOG(@"  -> CGEventPostToPid(%d) target=%@", target.processIdentifier, DescribeApp(target));
    }
    if (wantHID) {
        CGEventPost(kCGHIDEventTap, keyDown);
        CGEventPost(kCGHIDEventTap, keyUp);
        SPIKE_LOG(@"  -> CGEventPost(kCGHIDEventTap)");
    }

    CFRelease(keyDown);
    CFRelease(keyUp);
    CFRelease(source);
    return wantPID || wantHID;
}

// MARK: hotkeys (A3)

- (void)registerHotKeys {
    EventTypeSpec eventType = { kEventClassKeyboard, kEventHotKeyPressed };
    OSStatus installStatus = InstallEventHandler(GetApplicationEventTarget(), HotKeyHandler, 1, &eventType, NULL, NULL);
    SPIKE_LOG(@"InstallEventHandler status=%d", (int)installStatus);

    [self registerHotKeyWithKeyCode:kVK_Space modifiers:optionKey identifier:1 label:@"Option+Space"];
    [self registerHotKeyWithKeyCode:kVK_Space modifiers:(optionKey | controlKey) identifier:2 label:@"Control+Option+Space"];
}

- (void)registerHotKeyWithKeyCode:(UInt32)keyCode
                        modifiers:(UInt32)modifiers
                       identifier:(UInt32)identifier
                            label:(NSString *)label {
    EventHotKeyRef ref = NULL;
    EventHotKeyID hotKeyID = { .signature = 'LSPK', .id = identifier };
    OSStatus status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref);
    NSString *meaning;
    if (status == noErr) {
        meaning = @"OK";
    } else if (status == eventHotKeyExistsErr) {
        meaning = @"FAILED - already registered by another process (hotkey conflict)";
    } else {
        meaning = [NSString stringWithFormat:@"FAILED rawStatus=%d", (int)status];
    }
    SPIKE_LOG(@"RegisterEventHotKey %@ (id=%u) -> %@", label, (unsigned)identifier, meaning);
}

@end

static OSStatus HotKeyHandler(EventHandlerCallRef nextHandler, EventRef event, void *userData) {
    EventHotKeyID hotKeyID = { 0, 0 };
    OSStatus err = GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID,
                                     NULL, sizeof(hotKeyID), NULL, &hotKeyID);
    if (err != noErr) {
        SPIKE_LOG(@"hotkey fired but GetEventParameter failed err=%d", (int)err);
        return noErr;
    }
    SPIKE_LOG(@">>> hotkey fired id=%u", (unsigned)hotKeyID.id);
    [(AppDelegate *)[NSApp delegate] handleHotKey:hotKeyID.id];
    return noErr;
}

// MARK: - entry point

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        application.delegate = delegate;
        [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [application run];
    }
    return 0;
}
