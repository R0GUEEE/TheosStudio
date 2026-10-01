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
- **Files** — create, rename and delete, and the file list in the Makefile follows
  them. A source file that is not in `X_FILES` is never compiled: the build
  succeeds and the hook does nothing, which is the single most confusing thing
  that happens to a new tweak developer. A new `.x` starts from a Logos skeleton,
  and a file that is missing from the list has a one-tap fix in its menu.
- **Find a hook** — searches the SDK headers and any folder of dumped private
  headers you point it at, classes first, and hands you the `%hook` skeleton with
  a button that creates the file and wires it into the Makefile. A hook for a
  class that does not exist silently never fires, so confirming the name is the
  first step of every tweak — and it is the one thing that cannot be done by
  guessing.
- **Snippets** — the Logos and Theos patterns that are easy to get subtly wrong,
  appended into the file you are editing: `%group` with `@available`, the
  preference read that listens for the settings bundle's notification, `%hookf`,
  `%property`, the lines that wire a preference bundle into the build.
- **Restart** — after an install, restart just the process you are testing:
  `INSTALL_TARGET_PROCESSES` from the Makefile plus the injection filter give the
  list, so a hook inside an app does not need a respring.
- **Crashes** — reads the device's crash logs (the modern `.ips` and the legacy
  `.crash`), putting the ones that mention this project's dylib first. The report
  is the only thing that says whether the tweak is actually at fault.
- **Source control** — the working tree with per-file diffs and a commit button;
  initialising a project writes a `.gitignore` that keeps `.theos/` and
  `packages/` out of the history, and an identity comes from Settings rather than
  from a "please tell me who you are" error.
- **Packages** — what is inside the built `.deb` before installing it, including
  whether it installs where this device looks. A rootful package on a rootless
  device puts a tweak into directories nothing reads, and nothing says so.
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
- **Plugins** — a first-class Plugin Center with built-in Git, package and device
  tools plus external JSON manifests. Plugins can be enabled independently, run
  against a selected project, receive the current project/package/Theos paths as
  tokens, and stream command output into the same console UI as the rest of the
  app. Manifests use argument arrays instead of shell strings, and destructive
  actions require an explicit Run tap.
- **Installing Theos** — the official installer's on-device path, split along the
  line that decides whether it works: cloning Theos and unpacking a patched SDK is
  copying files into a folder and needs no root at all, while the dependency
  packages (`clang`, `ldid`, `git`, `perl`, …) come from the package manager and
  do. When there is no way to become root the app installs the first part and
  tells you exactly what to run for the second, instead of failing at both.

## Plugins

The Plugin Center is deliberately declarative. A plugin is a JSON manifest in
`~/Documents/TheosStudio/Plugins` (or imported from Files) that describes one or
more commands. The first element is the executable and every remaining element is
an argument; TheosStudio does **not** join the array into a shell command.

```json
{
  "id": "example.project-tools",
  "name": "Example Project Tools",
  "version": "1.0.0",
  "summary": "A small project-aware plugin.",
  "systemImage": "wrench.and.screwdriver",
  "scopes": ["project"],
  "actions": [
    {
      "id": "git-log",
      "title": "Recent commits",
      "command": ["git", "-C", "{{project}}", "log", "-5", "--oneline"],
      "requiresProject": true
    }
  ],
  "snippets": [
    {
      "id": "debug-log",
      "title": "Debug log",
      "language": "code",
      "suggestedFileName": "Tweak.x",
      "body": "NSLog(@\"[MyTweak] reached hook\");"
    }
  ]
}
```

Available tokens are `{{project}}`, `{{projectName}}`, `{{identifier}}`,
`{{scheme}}`, `{{package}}`, `{{theos}}`, `{{home}}` and `{{plugin}}`.
An action can also declare `requiresPackage: true` and `destructive: true`. Package actions are disabled until the selected project has
a built `.deb`; destructive actions open their console but wait for an explicit
Run tap.

Plugins can also contribute editor snippets. Enabled plugin snippets appear beside
the built-in Logos/Theos snippets in the editor; their `language` may be
`code`, `makefile`, `controlFile`, `plist` or `plainText`.

A plugin can also be a directory containing `plugin.json`. In that form a
relative executable such as `./bin/lint` is resolved inside the plugin directory,
which makes it possible to ship a manifest together with helper scripts or
binaries installed by a jailbreak package.

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
| `read_crashes`, `git_status`, `git_diff` | none — reading the device's crash logs, the project's working tree, and the headers |
| `search_headers` | none — confirming a class or method name in the SDK headers and your own header dump |
| `write_file`, `replace_in_file`, `update_control` | **you see a diff and approve it** |
| `build` (`make package`) | approve; the compiler's errors and warnings come back as the tool result |
| `install` (`dpkg` + respring) | approve |

Three things make it more than a chat box with a file editor:

- **It reads the build's answer.** `build` returns the diagnostics, so a failing
  compile is a loop the agent can close by itself: fix, build, read, fix. With
  `read_crashes` it can also see whether the crash it is being asked about is even
  this project's, which is the difference between a guess and a diagnosis.
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

The assistant **streams**: the reply appears as it is written, and a tool call's
arguments are reassembled from the fragments the provider sends. A gateway that
ignores streaming is read as a normal response instead of looking like an empty
turn, and it can be turned off in the settings.

**Build, install and test** is one action in the project's build section: build,
install, then restart the process the tweak hooks — the loop you run twenty times
a day, in one tap.

**Configuration** (Settings → Assistant) beyond the endpoint:

| Setting | What it decides |
| --- | --- |
| **Approval** | Ask for every change (default), ask only to build or install, ask only to install, or do not ask. A looser setting never loosens the sandbox: writing outside the project, into build output, or reading the device's files stays refused. |
| **Tools** | Which tools the model is offered at all; one that is off is refused by name if it asks anyway. Turning off build and install leaves a read-and-edit assistant. |
| **Standing instructions** | Seven switches — explain first, smallest change, never assume a private API, log every hook, comment the why, say how to verify, keep the filter narrow — each one line in the system prompt. |
| **Context** | Send the project's files or only their names, how many characters per request, a reply-length cap for providers whose default truncates a tool call mid-argument, streaming on or off, and **extra request fields** as JSON for parameters only one gateway understands. |
| **AGENT.md** | A per-project briefing, written by you, sent on every request. It lives in the project, so it shows up in the file list and travels with the repository. The assistant offers to create one. |

**Setup** (Assistant tab → Set up the model, or Settings → Assistant):

> The key is kept in the iOS keychain under the provider's name. An ad-hoc signed
> app is refused by securityd unless it carries an `application-identifier` and a
> `keychain-access-group`, which this app now ships; if the keychain still refuses,
> the key is kept in a 0600 file inside the app's folder **and the setup screen
> says so** rather than pretending it saved.

1. **Pick a provider** — OpenAI, DeepSeek, OpenRouter, Anthropic, Google Gemini,
   Groq, Mistral, xAI, Together, a local Ollama or LM Studio, or a custom endpoint.
   The base URL fills itself in.
2. **Paste an API key** — stored in the keychain under that provider's name, so
   switching providers does not overwrite it, and never written to the settings
   file. Local endpoints need no key.
3. **Load the model list** — one request to `/models` fills a picker with the
   provider's own models, filtered to the ones that can hold a conversation
   (embeddings, speech and image models are not offered as coding agents). The
   endpoint and model you choose are remembered per provider.

A **Test the connection** button sends the same short request the assistant uses,
so a green result means the next thing you type will work.

**What each request sends:** the project's text files (Makefile, control, Logos
sources, plists, README), the last build's diagnostics, and the conversation.
Nothing else on the device is read or sent.

**What it cannot do:** see the device's *binaries* — a class that is not in the
SDK headers or in a dump you have given it cannot be confirmed, and it is told to
say so rather than guess. Point Settings → Header search at a dump of private
headers and that gap closes for whatever the dump covers.

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
| Fetch only an SDK into an existing Theos | no | the same download and unpack, touching nothing else |
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
