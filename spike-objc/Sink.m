// Sink — a paste target used to verify assumption A2 end-to-end.
// Shows a text view and continuously writes its content to /tmp/sink.txt so a
// test script can confirm that injected Cmd+V actually landed in another app.
// Instrumented: every received key event, paste: dispatch and key-window change
// is logged to stderr, which localises where an injection dies.

#import <AppKit/AppKit.h>

static NSString *const kSinkPath = @"/tmp/sink.txt";
/// When set (via `--selftest "<keyword>"`), the app types that text into its own text
/// view and reports the resulting content and caret. Posting the keystrokes from the
/// process that owns the focused view removes the focus races that made cross-process
/// synthetic input unreliable.
static NSString *gSelftestText = nil;

@interface SinkTextView : NSTextView @end

@implementation SinkTextView
- (void)keyDown:(NSEvent *)event {
    fprintf(stderr, "Sink keyDown keyCode=%d flags=0x%lx chars=%s\n",
            event.keyCode, (unsigned long)event.modifierFlags,
            event.charactersIgnoringModifiers.UTF8String ?: "");
    [super keyDown:event];
}
- (void)paste:(id)sender {
    fprintf(stderr, "Sink paste: invoked (pasteboard=\"%s\")\n",
            ([[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString] ?: @"<nil>").UTF8String);
    [super paste:sender];
}
- (BOOL)becomeFirstResponder {
    BOOL result = [super becomeFirstResponder];
    fprintf(stderr, "Sink textView becomeFirstResponder -> %d\n", result);
    return result;
}
- (BOOL)resignFirstResponder {
    BOOL result = [super resignFirstResponder];
    fprintf(stderr, "Sink textView resignFirstResponder -> %d\n", result);
    return result;
}
@end

@interface SinkDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) SinkTextView *textView;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, copy) NSString *lastWritten;
@property (nonatomic, assign) BOOL lastKeyWindowState;
@end

@implementation SinkDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // A main menu is required for Cmd+V to be routed to paste: — AppKit resolves
    // command key equivalents through the main menu, so a menu-less app never
    // pastes. This is a property of the *target* app, not of the injection.
    NSMenu *mainMenu = [[NSMenu alloc] init];
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:appMenuItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"Quit Sink" action:@selector(terminate:) keyEquivalent:@"q"];
    appMenuItem.submenu = appMenu;

    NSMenuItem *editMenuItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:editMenuItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    editMenuItem.submenu = editMenu;
    [NSApp setMainMenu:mainMenu];

    NSRect frame = NSMakeRect(0, 0, 560, 220);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = @"Sink (paste target)";

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:frame];
    scrollView.hasVerticalScroller = YES;
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    self.textView = [[SinkTextView alloc] initWithFrame:frame];
    self.textView.font = [NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightRegular];
    self.textView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scrollView.documentView = self.textView;
    self.window.contentView = scrollView;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(windowDidBecomeKey:)
                   name:NSWindowDidBecomeKeyNotification object:self.window];
    [center addObserver:self selector:@selector(windowDidResignKey:)
                   name:NSWindowDidResignKeyNotification object:self.window];
    [center addObserver:self selector:@selector(appDidActivate:)
                   name:NSApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:self selector:@selector(appDidDeactivate:)
                   name:NSApplicationDidResignActiveNotification object:nil];

    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeFirstResponder:self.textView];

    [[NSFileManager defaultManager] createFileAtPath:kSinkPath contents:[NSData data] attributes:nil];
    [self writeContent]; // establish the empty baseline
    self.lastKeyWindowState = self.window.isKeyWindow;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                 target:self
                                               selector:@selector(tick)
                                               userInfo:nil
                                                repeats:YES];
    fprintf(stderr, "Sink ready, bundleID=%s pid=%d\n",
            [[[NSBundle mainBundle] bundleIdentifier] UTF8String], getpid());

    if (gSelftestText) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self typeText:gSelftestText];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                NSRange selection = self.textView.selectedRange;
                NSString *content = self.textView.string ?: @"";
                printf("SELFTEST typed=\"%s\" content=\"%s\" caret=%lu length=%lu\n",
                       gSelftestText.UTF8String,
                       content.UTF8String,
                       (unsigned long)selection.location,
                       (unsigned long)content.length);
                fflush(stdout);
                [NSApp terminate:nil];
            });
        });
    }
}

- (void)typeText:(NSString *)text {
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    for (NSUInteger index = 0; index < text.length; index++) {
        UniChar unit = [text characterAtIndex:index];
        CGEventRef down = CGEventCreateKeyboardEvent(source, 0, true);
        CGEventKeyboardSetUnicodeString(down, 1, &unit);
        CGEventPost(kCGHIDEventTap, down);
        CFRelease(down);
        CGEventRef up = CGEventCreateKeyboardEvent(source, 0, false);
        CGEventKeyboardSetUnicodeString(up, 1, &unit);
        CGEventPost(kCGHIDEventTap, up);
        CFRelease(up);
        usleep(15000);
    }
    CFRelease(source);
    fprintf(stderr, "Sink selftest typed \"%s\"\n", text.UTF8String);
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
    fprintf(stderr, "Sink windowDidBecomeKey\n");
}
- (void)windowDidResignKey:(NSNotification *)notification {
    fprintf(stderr, "Sink windowDidResignKey\n");
}
- (void)appDidActivate:(NSNotification *)notification { fprintf(stderr, "Sink appDidActivate\n"); }
- (void)appDidDeactivate:(NSNotification *)notification { fprintf(stderr, "Sink appDidDeactivate\n"); }

- (void)tick {
    BOOL keyWindow = self.window.isKeyWindow;
    if (keyWindow != self.lastKeyWindowState) {
        self.lastKeyWindowState = keyWindow;
        fprintf(stderr, "Sink state: isKeyWindow=%d isActive=%d firstResponder=%s\n",
                keyWindow, [NSApp isActive],
                NSStringFromClass([self.window.firstResponder class]).UTF8String);
    }
    [self writeContent];
}

- (void)writeContent {
    NSString *content = self.textView.string ?: @"";
    NSRange selection = self.textView.selectedRange;
    NSString *snapshot = [NSString stringWithFormat:@"caret=%lu\n--content--\n%@\n--end--\n",
                          (unsigned long)selection.location, content];
    if ([snapshot isEqualToString:self.lastWritten]) return;
    self.lastWritten = snapshot;
    // The caret is written too: it is the only way to verify snippet expansion places the
    // insertion point where Alfred's {cursor} marker asked for.
    [snapshot writeToFile:kSinkPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    fprintf(stderr, "Sink snapshot caret=%lu content=\"%s\"\n",
            (unsigned long)selection.location, content.UTF8String);
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        for (int index = 1; index < argc; index++) {
            if (strcmp(argv[index], "--selftest") == 0 && index + 1 < argc) {
                gSelftestText = [NSString stringWithUTF8String:argv[index + 1]];
            }
        }
        NSApplication *application = [NSApplication sharedApplication];
        SinkDelegate *delegate = [[SinkDelegate alloc] init];
        application.delegate = delegate;
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        [application run];
    }
    return 0;
}
