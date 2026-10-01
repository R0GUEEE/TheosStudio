import Foundation

/// Generates the files of a new project.
///
/// These are the same shapes `nic.pl` produces, with three deliberate choices:
/// the packaging scheme is written into the Makefile instead of being left to a
/// command-line variable, every generated project gets a README that says how to
/// build and install it, and the tweak template hooks a harmless log-only method
/// so a first build can be installed on a device without any risk of a bootloop.
public enum ProjectTemplate {

    public static func files(for request: TemplateRequest) -> [TemplateFile] {
        var files: [TemplateFile] = []
        files.append(TemplateFile(path: "Makefile", contents: makefile(for: request)))
        files.append(TemplateFile(path: "control", contents: request.controlFile().serialized()))
        files.append(TemplateFile(path: "README.md", contents: readme(for: request)))

        switch request.kind {
        case .tweak:
            files.append(contentsOf: tweakSources(for: request, prefix: ""))
        case .tweakWithPreferences:
            files.append(contentsOf: tweakSources(for: request, prefix: ""))
            files.append(contentsOf: preferencesSources(for: request, directory: "prefs", installAsBUNDLE_NAME: request.name + "Prefs"))
        case .preferenceBundle:
            files.append(contentsOf: preferencesSources(for: request, directory: "", installAsBUNDLE_NAME: request.name))
        case .application:
            files.append(contentsOf: applicationSources(for: request))
        case .tool:
            files.append(contentsOf: toolSources(for: request))
        }
        return files.sorted { $0.path < $1.path }
    }

    // MARK: - Makefile

    public static func makefile(for request: TemplateRequest) -> String {
        let name = request.name
        var lines: [String] = []
        lines.append("# \(name) — Theos makefile")
        lines.append("#")
        lines.append("# Packaging scheme: \(request.scheme.displayName) — \(request.scheme.summary)")
        lines.append("#   install root:   \(request.scheme.installRootDescription)")
        lines.append("#   Architecture:   \(request.scheme.debianArchitecture)")
        lines.append("#")
        lines.append("# Build:   make package     (or tap Build in TheosStudio)")
        lines.append("# Clean:   make clean")
        lines.append("# Output:  ./packages/\(name.lowercased())_*.deb")
        lines.append("")
        if let value = request.scheme.theosVariableValue {
            lines.append("# Theos rewrites every install path for this scheme; do not")
            lines.append("# hardcode /Library or /usr in your code, build them at runtime.")
            lines.append("export THEOS_PACKAGE_SCHEME = \(value)")
        } else {
            lines.append("# Rootful: no scheme variable, everything installs under /.")
        }
        lines.append("")
        lines.append("# Minimum iOS version the tweak targets, and the SDK to build against.")
        lines.append("# `latest` means: newest SDK in $(THEOS)/sdks.")
        lines.append("TARGET := iphone:clang:latest:\(request.minimumIOSVersion)")
        lines.append("")
        lines.append("# arm64 covers every device. arm64e is required for hooks inside")
        lines.append("# system processes (SpringBoard, backboardd) on A12 and newer.")
        lines.append("ARCHS = \(request.architectures.joined(separator: " "))")
        lines.append("")
        lines.append("# Restarted after `make install`, so a rebuild is a rebuild + a respring.")
        lines.append("INSTALL_TARGET_PROCESSES = SpringBoard")
        lines.append("")
        lines.append("include $(THEOS)/makefiles/common.mk")
        lines.append("")

        switch request.kind {
        case .tweak:
            lines.append("TWEAK_NAME = \(name)")
            lines.append("\(name)_FILES = Tweak.x")
            lines.append("\(name)_CFLAGS = -fobjc-arc")
            lines.append("\(name)_FRAMEWORKS = UIKit")
            lines.append("")
            lines.append("include $(THEOS_MAKE_PATH)/tweak.mk")
        case .tweakWithPreferences:
            lines.append("TWEAK_NAME = \(name)")
            lines.append("\(name)_FILES = Tweak.x")
            lines.append("\(name)_CFLAGS = -fobjc-arc")
            lines.append("\(name)_FRAMEWORKS = UIKit")
            lines.append("")
            lines.append("# The preference bundle is a subproject: it is built by this")
            lines.append("# Makefile too, so `make package` produces one .deb with both.")
            lines.append("SUBPROJECTS += prefs")
            lines.append("")
            lines.append("include $(THEOS_MAKE_PATH)/tweak.mk")
            lines.append("include $(THEOS_MAKE_PATH)/aggregate.mk")
        case .preferenceBundle:
            lines.append("BUNDLE_NAME = \(name)")
            lines.append("\(name)_FILES = \(name)RootListController.m")
            lines.append("\(name)_INSTALL_PATH = /Library/PreferenceBundles")
            lines.append("\(name)_FRAMEWORKS = UIKit")
            lines.append("\(name)_PRIVATE_FRAMEWORKS = Preferences")
            lines.append("\(name)_CFLAGS = -fobjc-arc")
            lines.append("")
            lines.append("include $(THEOS_MAKE_PATH)/bundle.mk")
        case .application:
            lines.append("APPLICATION_NAME = \(name)")
            lines.append("\(name)_FILES = main.m \(name)AppDelegate.m \(name)RootViewController.m")
            lines.append("\(name)_FRAMEWORKS = UIKit Foundation")
            lines.append("\(name)_CFLAGS = -fobjc-arc")
            lines.append("")
            lines.append("include $(THEOS_MAKE_PATH)/application.mk")
        case .tool:
            lines.append("TOOL_NAME = \(name.lowercased())")
            lines.append("\(name.lowercased())_FILES = main.m")
            lines.append("\(name.lowercased())_INSTALL_PATH = /usr/local/bin")
            lines.append("\(name.lowercased())_CFLAGS = -fobjc-arc")
            lines.append("\(name.lowercased())_FRAMEWORKS = Foundation")
            lines.append("")
            lines.append("include $(THEOS_MAKE_PATH)/tool.mk")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: - Tweak

    static func tweakSources(for request: TemplateRequest, prefix: String) -> [TemplateFile] {
        var files: [TemplateFile] = []
        let directory = prefix.isEmpty ? "" : prefix + "/"
        files.append(TemplateFile(
            path: directory + "Tweak.x",
            contents: tweakSource(for: request)
        ))
        files.append(TemplateFile(
            path: directory + "\(request.name).plist",
            contents: injectionFilter(for: request)
        ))
        return files
    }

    public static func tweakSource(for request: TemplateRequest) -> String {
        """
        // \(request.name) — Tweak.x
        //
        // Logos turns the hook blocks below into runtime method replacement.
        // This file builds and installs as-is: the hook only logs. Replace it
        // with the hook you actually want — see README.md.

        #import <UIKit/UIKit.h>

        // Declare only what you use. A hook for a class that does not exist on
        // the device is not an error, it simply never fires — which is why the
        // first thing to do with a new tweak is confirm the class name against
        // the device (see the "Finding what to hook" section of README.md).

        @interface SBIconView : UIView
        @end

        %hook SBIconView

        - (void)didMoveToWindow {
            %orig;   // call the original first: we are only observing here
            NSLog(@"[\(request.name)] SBIconView did move to a window");
        }

        %end

        %ctor {
            NSLog(@"[\(request.name)] loaded into %@", [[NSProcessInfo processInfo] processName]);
        }
        """
    }

    public static func injectionFilter(for request: TemplateRequest) -> String {
        // A plain old-style plist, deliberately without comments: the injector
        // reads this at process start with the NeXTSTEP-format parser, and the
        // explanation belongs in the project README instead.
        //
        // The file name must be identical to TWEAK_NAME in the Makefile.
        """
        {
            Filter = {
                Bundles = ( "\(request.injectionBundle)" );
            };
        }
        """
    }

    // MARK: - Preference bundle

    static func preferencesSources(for request: TemplateRequest, directory: String, installAsBUNDLE_NAME bundleName: String) -> [TemplateFile] {
        let directoryPath = directory.isEmpty ? "" : directory + "/"
        var files: [TemplateFile] = []

        files.append(TemplateFile(path: directoryPath + "\(bundleName)RootListController.m", contents: rootListController(for: request, bundleName: bundleName)))
        files.append(TemplateFile(path: directoryPath + "Resources/Root.plist", contents: rootPlist(for: request)))
        files.append(TemplateFile(path: directoryPath + "Resources/Info.plist", contents: bundleInfoPlist(for: request, bundleName: bundleName)))
        files.append(TemplateFile(path: "layout/Library/PreferenceLoader/Preferences/\(request.name).plist", contents: preferenceLoaderEntry(for: request, bundleName: bundleName)))

        if !directory.isEmpty {
            // A subproject needs its own Makefile; a standalone bundle uses the
            // top-level one, which already carries the bundle rules.
            files.append(TemplateFile(path: directoryPath + "Makefile", contents: bundleMakefile(for: request, bundleName: bundleName)))
        }
        return files
    }

    public static func bundleMakefile(for request: TemplateRequest, bundleName: String) -> String {
        """
        # \(bundleName) — a PreferenceLoader bundle, built as a subproject of
        # \(request.name). `make package` in the parent directory builds this too.
        #
        # Install path: /Library/PreferenceBundles (\(request.scheme.installRootDescription)).

        BUNDLE_NAME = \(bundleName)
        \(bundleName)_FILES = \(bundleName)RootListController.m
        \(bundleName)_INSTALL_PATH = /Library/PreferenceBundles
        \(bundleName)_FRAMEWORKS = UIKit
        \(bundleName)_PRIVATE_FRAMEWORKS = Preferences
        \(bundleName)_CFLAGS = -fobjc-arc

        include $(THEOS)/makefiles/common.mk
        include $(THEOS_MAKE_PATH)/bundle.mk
        """
    }

    public static func rootListController(for request: TemplateRequest, bundleName: String) -> String {
        """
        // \(bundleName)RootListController.m
        //
        // The controller PreferenceLoader instantiates. Its cells come from
        // Resources/Root.plist, so most of the UI work happens in that file.

        #import <Preferences/PSListController.h>

        @interface \(bundleName)RootListController : PSListController
        @end

        @implementation \(bundleName)RootListController

        - (NSArray *)specifiers {
            if (!_specifiers) {
                _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
            }
            return _specifiers;
        }

        // Preferences changed: tell the tweak to re-read them. The tweak listens
        // for this on the Darwin notification centre, so no respring is needed.
        - (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
            [super setPreferenceValue:value specifier:specifier];
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFSTR("\(request.packageIdentifier)/ReloadPrefs"),
                NULL, NULL, YES);
        }

        @end
        """
    }

    public static func rootPlist(for request: TemplateRequest) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        	<key>title</key>
        	<string>\(request.name)</string>
        	<key>items</key>
        	<array>
        		<dict>
        			<key>cell</key>
        			<string>PSGroupCell</string>
        			<key>label</key>
        			<string>\(request.name)</string>
        			<key>footerText</key>
        			<string>Changes take effect immediately — the tweak re-reads its preferences when you toggle a switch.</string>
        		</dict>
        		<dict>
        			<key>cell</key>
        			<string>PSSwitchCell</string>
        			<key>label</key>
        			<string>Enable tweak</string>
        			<key>key</key>
        			<string>enabled</string>
        			<key>defaults</key>
        			<string>\(request.packageIdentifier)</string>
        			<key>default</key>
        			<true/>
        			<key>PostNotification</key>
        			<string>\(request.packageIdentifier)/ReloadPrefs</string>
        		</dict>
        	</array>
        </dict>
        </plist>
        """
    }

    public static func bundleInfoPlist(for request: TemplateRequest, bundleName: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        	<key>CFBundleDevelopmentRegion</key>
        	<string>en</string>
        	<key>CFBundleIdentifier</key>
        	<string>\(request.packageIdentifier).\(bundleName.lowercased())</string>
        	<key>CFBundleExecutable</key>
        	<string>\(bundleName)</string>
        	<key>CFBundleName</key>
        	<string>\(bundleName)</string>
        	<key>CFBundlePackageType</key>
        	<string>BNDL</string>
        	<key>CFBundleShortVersionString</key>
        	<string>0.0.1</string>
        	<key>CFBundleVersion</key>
        	<string>1</string>
        	<key>NSPrincipalClass</key>
        	<string>\(bundleName)RootListController</string>
        </dict>
        </plist>
        """
    }

    public static func preferenceLoaderEntry(for request: TemplateRequest, bundleName: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        	<key>entry</key>
        	<dict>
        		<key>bundle</key>
        		<string>\(bundleName)</string>
        		<key>cell</key>
        		<string>PSLinkCell</string>
        		<key>detail</key>
        		<string>\(bundleName)RootListController</string>
        		<key>isController</key>
        		<true/>
        		<key>label</key>
        		<string>\(request.name)</string>
        	</dict>
        </dict>
        </plist>
        """
    }

    // MARK: - Application

    static func applicationSources(for request: TemplateRequest) -> [TemplateFile] {
        let name = request.name
        return [
            TemplateFile(path: "main.m", contents: mainSource(for: request)),
            TemplateFile(path: "\(name)AppDelegate.h", contents: appDelegateHeader(for: request)),
            TemplateFile(path: "\(name)AppDelegate.m", contents: appDelegateSource(for: request)),
            TemplateFile(path: "\(name)RootViewController.h", contents: rootViewControllerHeader(for: request)),
            TemplateFile(path: "\(name)RootViewController.m", contents: rootViewControllerSource(for: request)),
            TemplateFile(path: "Resources/Info.plist", contents: applicationInfoPlist(for: request)),
        ]
    }

    public static func mainSource(for request: TemplateRequest) -> String {
        """
        // main.m — \(request.name)

        #import <UIKit/UIKit.h>
        #import "\(request.name)AppDelegate.h"

        int main(int argc, char *argv[]) {
            @autoreleasepool {
                return UIApplicationMain(argc, argv, nil, NSStringFromClass([\(request.name)AppDelegate class]));
            }
        }
        """
    }

    public static func appDelegateHeader(for request: TemplateRequest) -> String {
        """
        #import <UIKit/UIKit.h>

        @interface \(request.name)AppDelegate : UIResponder <UIApplicationDelegate>
        @property (nonatomic, strong) UIWindow *window;
        @end
        """
    }

    public static func appDelegateSource(for request: TemplateRequest) -> String {
        """
        #import "\(request.name)AppDelegate.h"
        #import "\(request.name)RootViewController.h"

        @implementation \(request.name)AppDelegate

        - (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
            self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            self.window.rootViewController = [[\(request.name)RootViewController alloc] init];
            [self.window makeKeyAndVisible];
            return YES;
        }

        @end
        """
    }

    public static func rootViewControllerHeader(for request: TemplateRequest) -> String {
        """
        #import <UIKit/UIKit.h>

        @interface \(request.name)RootViewController : UIViewController
        @end
        """
    }

    public static func rootViewControllerSource(for request: TemplateRequest) -> String {
        """
        #import "\(request.name)RootViewController.h"

        @implementation \(request.name)RootViewController

        - (void)viewDidLoad {
            [super viewDidLoad];

            self.view.backgroundColor = [UIColor systemBackgroundColor];
            self.title = @"\(request.name)";

            UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
            label.text = @"Hello from \(request.name)";
            label.textAlignment = NSTextAlignmentCenter;
            label.translatesAutoresizingMaskIntoConstraints = NO;
            [self.view addSubview:label];

            [NSLayoutConstraint activateConstraints:@[
                [label.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
                [label.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
            ]];
        }

        @end
        """
    }

    public static func applicationInfoPlist(for request: TemplateRequest) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        	<key>CFBundleDevelopmentRegion</key>
        	<string>en</string>
        	<key>CFBundleExecutable</key>
        	<string>\(request.name)</string>
        	<key>CFBundleIdentifier</key>
        	<string>\(request.packageIdentifier)</string>
        	<key>CFBundleInfoDictionaryVersion</key>
        	<string>6.0</string>
        	<key>CFBundleName</key>
        	<string>\(request.name)</string>
        	<key>CFBundlePackageType</key>
        	<string>APPL</string>
        	<key>CFBundleShortVersionString</key>
        	<string>0.0.1</string>
        	<key>CFBundleVersion</key>
        	<string>1</string>
        	<key>LSRequiresIPhoneOS</key>
        	<true/>
        	<key>MinimumOSVersion</key>
        	<string>\(request.minimumIOSVersion)</string>
        	<key>UIDeviceFamily</key>
        	<array>
        		<integer>1</integer>
        		<integer>2</integer>
        	</array>
        	<key>UILaunchScreen</key>
        	<dict/>
        	<key>UIRequiredDeviceCapabilities</key>
        	<array>
        		<string>arm64</string>
        	</array>
        </dict>
        </plist>
        """
    }

    // MARK: - Tool

    static func toolSources(for request: TemplateRequest) -> [TemplateFile] {
        [
            TemplateFile(path: "main.m", contents: toolSource(for: request)),
        ]
    }

    public static func toolSource(for request: TemplateRequest) -> String {
        """
        // main.m — \(request.name)
        //
        // Installed to /usr/local/bin/\(request.name.lowercased()) ("\(request.scheme.installRootDescription)" + /usr/local/bin).

        #import <Foundation/Foundation.h>

        int main(int argc, char *argv[]) {
            @autoreleasepool {
                printf("Hello from \(request.name.lowercased())\\n");
            }
            return 0;
        }
        """
    }

    // MARK: - README

    public static func readme(for request: TemplateRequest) -> String {
        var extra = ""
        switch request.kind {
        case .tweak, .tweakWithPreferences:
            extra = """

            ## Finding what to hook

            A `%hook` for a class or selector that does not exist on this iOS version
            does not fail: it simply never fires. Confirm the name before writing
            the hook:

            - `FLEX`/`FLEXing` shows the class and view hierarchy of whatever is on
              screen — the fastest way to find the class that draws the thing you
              want to change.
            - `frida-trace -U -m "-[SBIconView *]" SpringBoard` prints the selectors
              that actually fire while you use the device.
            - `%c(ClassName)` returns the class at runtime (nil when it is absent);
              `NSLog` it inside `%ctor` to check from the device itself. The build
              log in TheosStudio shows it live.
            """
        case .preferenceBundle:
            extra = """

            ## Wiring

            `layout/Library/PreferenceLoader/Preferences/\(request.name).plist` is the entry
            PreferenceLoader reads from the Settings app. It names the bundle and the
            controller class inside it, so those two strings have to match
            `Resources/Info.plist` and this Makefile.
            """
        case .application:
            extra = """

            ## Layout

            `Resources/Info.plist` becomes the app's Info.plist and the binary is
            installed to `/Applications`. On a rootless jailbreak Theos turns that
            into `/var/jb/Applications`, which is where `uicache` looks.
            """
        case .tool:
            extra = """

            ## Running it

            The binary installs to `/usr/local/bin/\(request.name.lowercased())` (under
            `\(request.scheme.installRootDescription)` on this scheme). Run it from a terminal on
            the device after installing the .deb.
            """
        }

        return """
        # \(request.name)

        \(request.summary)

        - **Kind:** \(request.kind.displayName)
        - **Packaging:** \(request.scheme.displayName) — installs under `\(request.scheme.installRootDescription)`, `Architecture: \(request.scheme.debianArchitecture)`
        - **Identifier:** `\(request.packageIdentifier)`
        - **Minimum iOS:** \(request.minimumIOSVersion)

        ## Build

        From TheosStudio: **Build package** in the project's Build tab. The console
        shows the full `make` output and the `.deb` appears under `packages/`.

        From a terminal on the device:

        ```sh
        cd "$(dirname "$0")"     # this directory
        make package             # produces packages/*.deb
        make clean               # removes .theos/ and obj/
        ```

        ## Install

        Tap **Install** on the built package inside TheosStudio, or:

        ```sh
        dpkg -i packages/*.deb
        sbreload                # or: killall -9 SpringBoard
        ```

        ## Files

        | File | What it is |
        | --- | --- |
        | `Makefile` | Theos build rules: `TARGET`, `ARCHS`, the packaging scheme, and the file list |
        | `control` | Package metadata. Theos keeps `Version:` and overwrites `Architecture:` at package time |
        \(request.kind.usesInjectionFilter ? "| `\(request.name).plist` | Injection filter — which processes load the dylib |\n" : "")| `.theos/` | Build products (generated, ignored) |
        | `packages/` | Finished `.deb` files (generated) |
        \(extra)
        """
    }
}
