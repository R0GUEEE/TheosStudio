# TheosStudio

[![Engine](https://github.com/R0GUEEE/TheosStudio/actions/workflows/ci.yml/badge.svg)](https://github.com/R0GUEEE/TheosStudio/actions/workflows/ci.yml)
[![App Build](https://github.com/R0GUEEE/TheosStudio/actions/workflows/app-build.yml/badge.svg)](https://github.com/R0GUEEE/TheosStudio/actions/workflows/app-build.yml)

An iOS app for writing, building and installing **Theos tweaks on the device
itself** — no Mac, no SSH, no Xcode.

TheosStudio does not ship a compiler and does not pretend to. It drives the Theos
already installed on your jailbroken device (the same one Sileo installs), shows
you exactly what it is doing, and takes the `.deb` it produces and installs it.
When something is missing it says which package provides it instead of failing
with a linker error.

This repository contains:

| | |
| --- | --- |
| `Sources/TheosStudioCore` | The engine: templates, control files, toolchain discovery, build planning, log parsing, syntax tokens. Pure Swift, no UIKit. |
| `Sources/TheosStudioCLI` | `theosstudio` — the engine as a command line tool, so projects can be scaffolded and inspected from a terminal on the device. |
| `App/` | The SwiftUI app (XcodeGen project, packaged as a jailbreak `.deb`). |
| `Packaging/` | Turns the built `.app` into a rootless and a rootful `.deb`. |
| `Tests/` | The engine's test suite. |

## What the app does

- **Projects** — create a tweak, a tweak with a preference bundle, a standalone
  preference bundle, an application or a CLI tool. TheosStudio writes the same
  files `nic.pl` would, plus a README that explains the scheme it was generated
  for, and it writes the packaging scheme into the Makefile instead of leaving it
  to a command line flag.
- **Edit** — a Logos/Objective-C editor with syntax colouring, plus a form editor
  for `control` that validates the fields dpkg actually rejects. It also warns
  about the two mistakes that produce a package which installs and does nothing:
  a tweak with no hooking library in `Depends`, and a `Name:` that disagrees with
  the project name the filter plist is named after.
- **Build** — runs `make package` in the project with the environment Theos needs
  (`THEOS`, a `PATH` that finds the jailbreak's binaries) and streams the output
  into a console. Errors and warnings are lifted out of the log, with file and
  line, into a separate list so you do not have to read the whole thing.
- **Install** — `dpkg -i` the `.deb` the build produced, then respring. Packages
  can be listed and removed from the same screen.
- **Toolchain** — what this device can and cannot build with: Theos, its SDKs,
  `make`, `clang`, `ldid`, `dpkg-deb`, `perl` (Logos is a Perl script). Missing
  tools come with the `apt-get install` line that fixes them, ready to run — or
  installed from the app when it is allowed to.
- **Assistant** — an AI agent that works on one project: it reads the files, edits
  them, builds, and reads the compiler's answer, stopping for your approval before
  anything is written. Bring your own model (any OpenAI-compatible endpoint); the
  key stays in the keychain.
- **Installing Theos** — the official installer's on-device path, split along the
  line that decides whether it works: cloning Theos and unpacking a patched SDK is
  copying files into a folder and needs no root at all, while the dependency
  packages (`clang`, `ldid`, `git`, `perl`, …) come from the package manager and
  do. When there is no way to become root the app installs the first part and
  tells you exactly what to run for the second, instead of failing at both.

## Why it drives Theos instead of shipping a toolchain

A tweak needs a clang that matches the device's SDK, `ldid` to sign the dylib,
`dpkg-deb` to build the package, and Logos to turn `%hook` into method
replacement. On a jailbroken device all five already exist, are the right
versions for that device, and are already updated by the package manager. A
second copy inside an app would be a second thing to keep in sync, and it would
still have to install its output with `dpkg`.

So the app's job is the part that is actually missing on a phone: a place to
write the tweak, a build button that explains its failures, and an install button
that does not need a terminal.

## Requirements

- A **jailbroken** device on **iOS 15 or newer**, with **Theos** installed and an
  SDK in `$THEOS/sdks`. If Theos is not there yet, the app can install it: the
  Toolchain tab clones Theos and unpackes an SDK from `theos/sdks` into a folder
  it owns — no root needed — or runs the package install for `clang`, `ldid`,
  `git`, `perl` and the rest when it can.

## The assistant

An agent with a small, deliberate set of tools, scoped to one project:

| Tool | Approval |
| --- | --- |
| `list_files`, `read_file` | none — reading is free |
| `write_file`, `replace_in_file`, `update_control` | **you see a diff and approve it** |
| `build` (`make package`) | approve; the compiler's errors and warnings come back as the tool result |
| `install` (`dpkg` + respring) | approve |

Three things make it more than a chat box with a file editor:

- **It reads the build's answer.** `build` returns the diagnostics, so a failing
  compile is a loop the agent can close by itself: fix, build, read, fix.
- **Nothing is written behind your back.** Every mutating call stops and shows the
  change as a unified diff first. Denying one hands the refusal back to the model
  as the tool result, so it asks instead of repeating itself.
- **It cannot leave the project.** Paths are relative to the project root;
  absolute paths, `..` and build output (`packages/`, `.theos/`) are refused by a
  tested function, not by asking the model nicely in the prompt.

The system prompt is where the domain knowledge lives, and it is a reviewed,
tested part of the engine: `TWEAK_NAME` is what the filter plist's file name has
to match, a tweak with no hooking library in `Depends` installs and does nothing,
`%orig` calls the original, version-specific hooks belong in a `%group` behind
`@available`, a hook for a class that does not exist on the device **silently
never fires** — so a private class name is something to confirm, not to assume —
and a rootless package must never hardcode `/Library` or `/usr`.

**Setup:** Settings → Assistant. Any OpenAI-compatible `/chat/completions`
endpoint (OpenAI, a gateway, a machine on your LAN), a model name, and an API key.
The key is stored in the keychain and sent only to that endpoint.

**What each request sends:** the project's text files (Makefile, control, Logos
sources, plists, README), the last build's diagnostics, and the conversation.
Nothing else on the device is read or sent.

**What it cannot do:** confirm a private class or selector exists on your iOS
version — it has no way to inspect the device's binaries, and it is told to say
so rather than guess. Verifying a hook is still `FLEX`/`frida-trace` and a
respring.

## Permissions

An app installed from a `.deb` is launched by SpringBoard as `mobile`. That is
enough to write a project and run `make`, because everything a build writes lives
in a folder the app owns. It is **not** enough to run `apt-get` or `dpkg`: the
bootstrap's directories belong to root.

So the app asks for exactly one thing at a time, and never claims otherwise:

| Action | Needs root | What the app does |
| --- | --- | --- |
| Edit, build, package a project | no | runs `make` itself |
| Install Theos and an SDK into `~/Documents/Theos` | no | `git clone`, then the app downloads the SDK itself and unpacks it with `tar` |
| Install `clang`, `ldid`, `git`, `perl`… | yes | `sudo -n apt-get install -y …` when passwordless sudo exists |
| `dpkg -i` a built tweak | yes | `sudo -n dpkg -i …`, else hands the `.deb` to Sileo |
| Respring | yes | `sudo -n sbreload`, else `sudo -n killall -9 SpringBoard` |

`sudo -n` is deliberate: an app has no terminal, so a `sudo` that would ask for a
password is treated as no `sudo` at all. When that is the case the Toolchain tab
says so, shows the command to run from a root shell, and offers a Copy button —
and every built `.deb` has a Share button, which is the route that always works.

The app installs to `/var/jb/Applications` (rootless) or `/Applications`
(rootful) and is signed on the device with `ldid`, because the entitlements a
build tool needs — running unsigned binaries, writing outside its container —
cannot be granted by an Apple signing identity.

## Building this repository

```sh
swift build && swift test              # the engine
.build/debug/theosstudio env           # what this machine can build with
```

The app is built by CI (`.github/workflows/app-build.yml`) into an unsigned
`.app`, which `Packaging/build-deb.sh` turns into a rootless and a rootful `.deb`
with `ldid` and `dpkg-deb`.

## Using the engine without the app

```sh
theosstudio env                          # toolchain report for this device
theosstudio new tweak MyTweak            # scaffold a project
theosstudio new tool mytool --scheme rootful
theosstudio plan MyTweak --final         # the make command a build would run
theosstudio lint MyTweak                 # control file problems
```

## Licence

MIT — see [LICENSE](LICENSE).
