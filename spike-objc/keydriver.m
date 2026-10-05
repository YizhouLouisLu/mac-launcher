// keydriver — posts synthetic input so the spike can be verified without a human.
// Steps are given as arguments, executed in order:
//     hotkey                  post Option+Space
//     hotkey-ctrl             post Control+Option+Space
//     text:<string>           type <string>
//     key:return | key:esc    post that key
//     sleep:<milliseconds>    pause
//     activate:<bundle-id>    bring that app to the front
//     copy:<string>           put <string> on the general pasteboard
//
// Example:
//   ./keydriver activate:com.luyizhou.sink sleep:700 hotkey sleep:800 return

#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <ApplicationServices/ApplicationServices.h>

static void postKey(CGKeyCode keyCode, CGEventFlags flags) {
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    CGEventRef down = CGEventCreateKeyboardEvent(source, keyCode, true);
    CGEventRef up = CGEventCreateKeyboardEvent(source, keyCode, false);
    CGEventSetFlags(down, flags);
    CGEventSetFlags(up, flags);
    CGEventPost(kCGHIDEventTap, down);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(down);
    CFRelease(up);
    CFRelease(source);
}

static void postText(NSString *text) {
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    for (NSUInteger index = 0; index < text.length; index++) {
        UniChar character = [text characterAtIndex:index];
        CGEventRef down = CGEventCreateKeyboardEvent(source, 0, true);
        CGEventKeyboardSetUnicodeString(down, 1, &character);
        CGEventPost(kCGHIDEventTap, down);
        CGEventRef up = CGEventCreateKeyboardEvent(source, 0, false);
        CGEventKeyboardSetUnicodeString(up, 1, &character);
        CGEventPost(kCGHIDEventTap, up);
        CFRelease(down);
        CFRelease(up);
        usleep(12000);
    }
    CFRelease(source);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        fprintf(stderr, "keydriver: AXIsProcessTrusted=%d, steps=%d\n", AXIsProcessTrusted(), argc - 1);
        for (int index = 1; index < argc; index++) {
            NSString *step = [NSString stringWithUTF8String:argv[index]];
            fprintf(stderr, "  step: %s\n", step.UTF8String);

            if ([step isEqualToString:@"hotkey"]) {
                postKey((CGKeyCode)kVK_Space, kCGEventFlagMaskAlternate);
            } else if ([step isEqualToString:@"hotkey-ctrl"]) {
                postKey((CGKeyCode)kVK_Space, kCGEventFlagMaskAlternate | kCGEventFlagMaskControl);
            } else if ([step isEqualToString:@"return"]) {
                postKey((CGKeyCode)kVK_Return, 0);
            } else if ([step isEqualToString:@"esc"]) {
                postKey((CGKeyCode)kVK_Escape, 0);
            } else if ([step hasPrefix:@"text:"]) {
                postText([step substringFromIndex:5]);
            } else if ([step hasPrefix:@"sleep:"]) {
                usleep((useconds_t)([[step substringFromIndex:6] doubleValue] * 1000.0));
            } else if ([step hasPrefix:@"activate:"]) {
                NSString *bundleID = [step substringFromIndex:9];
                NSArray<NSRunningApplication *> *apps =
                    [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID];
                if (apps.count == 0) {
                    fprintf(stderr, "    no running app with bundle id %s\n", bundleID.UTF8String);
                } else {
                    BOOL ok = [apps.firstObject activateWithOptions:NSApplicationActivateIgnoringOtherApps];
                    fprintf(stderr, "    activate %s -> %d\n", bundleID.UTF8String, ok);
                }
            } else if ([step hasPrefix:@"copy:"]) {
                NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
                [pasteboard clearContents];
                [pasteboard setString:[step substringFromIndex:5] forType:NSPasteboardTypeString];
            } else {
                fprintf(stderr, "    unknown step: %s\n", step.UTF8String);
            }
            usleep(120000);
        }
        fprintf(stderr, "keydriver: done\n");
    }
    return 0;
}
