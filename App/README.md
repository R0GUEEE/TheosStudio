# The app

A SwiftUI shell over `TheosStudioCore`. Everything that decides what a build
means lives in the package at the repository root; this target is screens, a
process runner, and the syntax colouring the editor needs.

```
App/
├── project.yml               XcodeGen spec (the .xcodeproj is generated, not committed)
├── TheosStudio.entitlements  platform entitlements, applied on device by ldid
├── Resources/Info.plist      written out by hand: the bundle is built unsigned
└── Sources/
    ├── Model/                store, build runner, installer
    ├── Support/              posix_spawn, filesystem, syntax colours
    └── Views/                the screens
```

## Building and packaging

The way CI does it:

```sh
xcodegen generate --spec App/project.yml --project App
xcodebuild -project App/TheosStudio.xcodeproj -scheme TheosStudio \
           -configuration Release -sdk iphoneos \
           -derivedDataPath build \
           CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
           build

sh Packaging/build-deb.sh --rootless --output dist   # or --rootful
```

`build-deb.sh` copies the bundle into the right `Applications/` directory,
signs the binary with `ldid -S App/TheosStudio.entitlements`, sets the
permissions dpkg expects, and builds the package with `dpkg-deb`. It never builds
the app itself.

## Why it has to be a .deb and not an IPA

The app runs `make`, `clang`, `ldid`, `dpkg-deb` and `dpkg`, and it has to see
files outside its container — `/var/jb`, `/opt/theos`, the device's own
`/var/lib/dpkg`. Those are platform entitlements (`App/TheosStudio.entitlements`),
which Apple's signing service will never grant to a certificate. So the app ships
unsigned inside a package that `ldid` signs on a jailbroken device, which is also
the only kind of device where a tweak can be installed at all.

## The pieces worth knowing

- **`Support/Shell.swift`** spawns with `posix_spawn` and streams the merged
  stdout/stderr line by line. `Foundation.Process` does not exist on iOS, and
  `posix_spawn_file_actions_addchdir_np` is unavailable there, so the working
  directory is never changed — the engine passes `make -C <project>` instead.
- **`Views/CodeEditorView.swift`** wraps a `UITextView` because SwiftUI's
  `TextEditor` cannot colour ranges, and colouring ranges is most of what makes
  Logos readable. The token ranges come from the engine.
- **`Model/BuildRunner.swift`** asks the engine for a plan (an argument vector
  and an environment), runs it, and splits the log into a console and a
  diagnostics list. It makes no decisions about Theos itself.
