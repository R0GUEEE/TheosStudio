import Foundation

/// A piece of code worth not typing again.
public struct Snippet: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var summary: String
    /// What the snippet is written in, so the app can colour it and pick a file name.
    public var language: SyntaxLanguage
    public var suggestedFileName: String
    public var body: String

    public init(
        id: String,
        title: String,
        summary: String,
        language: SyntaxLanguage,
        suggestedFileName: String,
        body: String
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.language = language
        self.suggestedFileName = suggestedFileName
        self.body = body
    }
}

/// The Logos and Theos patterns that are easy to get subtly wrong.
///
/// Every one of these is here because of a mistake it prevents: a hook whose
/// class is guessed, a preference read that ignores the settings bundle's
/// notification, a `%property` that collides with an existing member, a
/// preference bundle not wired into `SUBPROJECTS`.
public enum SnippetLibrary {

    public static let all: [Snippet] = [
        Snippet(
            id: "logos.hook",
            title: "Hook a method",
            summary: "The basic shape: replace a method, call the original first, keep the result.",
            language: .code,
            suggestedFileName: "Hooks.x",
            body: """
            // Declare only what you use: a hook for a class or selector that does
            // not exist on this iOS version does not fail, it silently never fires.
            @interface SBIconView : UIView
            @end

            %hook SBIconView

            - (void)didMoveToWindow {
                %orig;   // call the original first when only observing
                NSLog(@"[MyTweak] didMoveToWindow");
            }

            // A hook with a return value has to return something.
            - (BOOL)isHighlighted {
                BOOL original = %orig;
                return original;
            }

            // Change an argument before the original runs.
            - (void)setFrame:(CGRect)frame {
                %orig(frame);
            }

            %end
            """
        ),
        Snippet(
            id: "logos.group",
            title: "Version-specific hooks with %group",
            summary: "Hooks for classes that only exist on some iOS versions, isolated so a missing one cannot break the rest.",
            language: .code,
            suggestedFileName: "VersionHooks.x",
            body: """
            %group iOS16
            %hook SBSomeNewClass
            - (void)newMethod {
                %orig;
            }
            %end
            %end

            %group iOS15
            %hook SBSomeOldClass
            - (void)oldMethod {
                %orig;
            }
            %end
            %end

            %ctor {
                // A missing class in one group cannot break the other groups.
                if (@available(iOS 16.0, *)) {
                    %init(iOS16);
                } else {
                    %init(iOS15);
                }
            }
            """
        ),
        Snippet(
            id: "logos.property",
            title: "Add a property or method",
            summary: "%property and %new, with the name prefixed so it cannot collide.",
            language: .code,
            suggestedFileName: "Extras.x",
            body: """
            %hook SBIconView

            // Associated-object backed, and prefixed: an unprefixed name can
            // collide with a private member Apple already has.
            %property (nonatomic, assign) BOOL mytweak_configured;

            %new
            - (void)mytweak_configure {
                self.mytweak_configured = YES;
            }

            %end
            """
        ),
        Snippet(
            id: "logos.hookf",
            title: "Hook a C function",
            summary: "%hookf for a symbol that has no Objective-C method behind it.",
            language: .code,
            suggestedFileName: "Functions.x",
            body: """
            #import <notify.h>

            // Variadic functions need the variadic form of the arguments; a
            // variadic hook that ignores the mode argument is a common crash.
            %hookf(int, open, const char *path, int flags, ...) {
                if (path != NULL) {
                    NSLog(@"[MyTweak] open(%s)", path);
                }
                return %orig;
            }

            %hookf(uint32_t, notify_post, const char *name) {
                return %orig;
            }
            """
        ),
        Snippet(
            id: "prefs.read",
            title: "Read preferences and reload on change",
            summary: "The tweak side: read your own domain, and re-read when the settings bundle says so.",
            language: .code,
            suggestedFileName: "Preferences.x",
            body: """
            static BOOL enabled = YES;

            static void mytweak_loadPreferences(void) {
                // The domain is the package identifier, the same one the
                // preference bundle's specifiers use.
                CFPreferencesAppSynchronize(CFSTR("com.example.mytweak"));
                CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("enabled"), CFSTR("com.example.mytweak"));
                enabled = value ? [(__bridge id)value boolValue] : YES;   // default when unset
                if (value) CFRelease(value);
            }

            static void mytweak_preferencesChanged(CFNotificationCenterRef center, void *observer,
                                                   CFNotificationName name, const void *object,
                                                   CFDictionaryRef userInfo) {
                mytweak_loadPreferences();
            }

            %ctor {
                mytweak_loadPreferences();
                // The settings bundle posts this, so a toggle takes effect without
                // a respring.
                CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                    mytweak_preferencesChanged, CFSTR("com.example.mytweak/ReloadPrefs"), NULL,
                    CFNotificationSuspensionBehaviorCoalesce);
            }
            """
        ),
        Snippet(
            id: "prefs.specifiers",
            title: "Preference bundle specifiers",
            summary: "Root.plist for a settings panel: a group, a switch, and the notification that reloads the tweak.",
            language: .plist,
            suggestedFileName: "Root.plist",
            body: """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            	<key>title</key>
            	<string>MyTweak</string>
            	<key>items</key>
            	<array>
            		<dict>
            			<key>cell</key>
            			<string>PSGroupCell</string>
            			<key>label</key>
            			<string>MyTweak</string>
            		</dict>
            		<dict>
            			<key>cell</key>
            			<string>PSSwitchCell</string>
            			<key>label</key>
            			<string>Enable tweak</string>
            			<key>key</key>
            			<string>enabled</string>
            			<key>defaults</key>
            			<string>com.example.mytweak</string>
            			<key>default</key>
            			<true/>
            			<!-- This is what makes a toggle take effect immediately. -->
            			<key>PostNotification</key>
            			<string>com.example.mytweak/ReloadPrefs</string>
            		</dict>
            	</array>
            </dict>
            </plist>
            """
        ),
        Snippet(
            id: "makefile.prefs",
            title: "Wire a preference bundle into the build",
            summary: "The two lines that turn a prefs folder into part of the .deb.",
            language: .makefile,
            suggestedFileName: "Makefile",
            body: """
            # In the tweak's Makefile: build the bundle as a subproject, so
            # `make package` produces one .deb containing both.
            SUBPROJECTS += prefs

            include $(THEOS_MAKE_PATH)/tweak.mk
            include $(THEOS_MAKE_PATH)/aggregate.mk

            # prefs/Makefile
            BUNDLE_NAME = MyTweakPrefs
            MyTweakPrefs_FILES = MyTweakPrefsRootListController.m
            MyTweakPrefs_INSTALL_PATH = /Library/PreferenceBundles
            MyTweakPrefs_FRAMEWORKS = UIKit
            MyTweakPrefs_PRIVATE_FRAMEWORKS = Preferences
            MyTweakPrefs_CFLAGS = -fobjc-arc

            include $(THEOS)/makefiles/common.mk
            include $(THEOS_MAKE_PATH)/bundle.mk
            """
        ),
        Snippet(
            id: "paths.runtime",
            title: "Runtime paths that work on every scheme",
            summary: "Never hardcode /Library: rootful, rootless and roothide put it in different places.",
            language: .code,
            suggestedFileName: "Paths.h",
            body: """
            #import <Foundation/Foundation.h>

            // Theos rewrites the paths in `layout/` for the packaging scheme, but
            // it cannot rewrite paths your code builds at runtime.
            static inline NSString *MyTweakPath(NSString *suffix) {
            #if THEOS_PACKAGE_SCHEME_ROOTLESS
                return [@"/var/jb" stringByAppendingString:suffix];
            #elif THEOS_PACKAGE_SCHEME_ROOTHIDE
                // roothide resolves its prefix per boot.
                extern NSString *jbroot(NSString *path);
                return jbroot(suffix);
            #else
                return suffix;
            #endif
            }
            """
        ),
        Snippet(
            id: "control.depends",
            title: "Control fields a tweak needs",
            summary: "The dependency that makes a tweak load, and the fields package managers show.",
            language: .controlFile,
            suggestedFileName: "control",
            body: """
            Package: com.example.mytweak
            Name: MyTweak
            Version: 0.0.1
            Architecture: iphoneos-arm64
            Description: One line that says what the tweak does
            Maintainer: Your Name <you@example.com>
            Author: Your Name <you@example.com>
            Section: Tweaks
            # Without a hooking library the package installs and does nothing.
            # ElleKit provides mobilesubstrate, so this one line covers both.
            Depends: mobilesubstrate
            """
        ),
    ]

    public static func snippet(id: String) -> Snippet? {
        all.first { $0.id == id }
    }
}
