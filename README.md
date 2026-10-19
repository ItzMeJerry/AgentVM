# AgentVM

Disposable Linux VMs for running agents, on `apple/container`. A native macOS app that
speaks to the container daemon through its own Swift API — no CLI, no subprocesses, no
output parsing.

```
Instances          ┌──────────────────────────────────────────────┐
● coder            │ coder            running   killswitch        │
  ubuntu:24.04     │ ubuntu:24.04 · instance · none · 4 CPU · 1 GB │
○ build-x86        ├──────────────────────────────────────────────┤
  fedora:41        │ Sessions │ Logs │ Inspect                     │
                   ├──────────────────────────────────────────────┤
                   │ 1. sh  2. sh  +                              │
                   │ # ls /work                                   │
                   │ Makefile  src  tests                         │
                   └──────────────────────────────────────────────┘
```

Boot an instance, mount one directory into it, open as many shell sessions as you like,
and stop it when you're done. The decisions that are hard to undo — what it can reach,
what it can see — are visible while you make them.

## Install

```sh
brew install apple/tap/container    # macOS 26+, Apple Silicon
container system start

git clone https://github.com/ItzMeJerry/AgentVM.git && cd AgentVM
bash Scripts/doctor.sh              # can this machine build it?
bash Scripts/build-app.sh           # builds .build/AgentVM.app
open .build/AgentVM.app
```

The first build resolves and compiles the `apple/container` package graph, which is large;
budget 15–30 minutes, ~4 GB of disk and a working network. After that, builds are
incremental (~30 s).

Xcode has to be installed, not just the Command Line Tools: SwiftUI's property wrappers are
macros now, and the plugin that expands them ships inside Xcode. `Scripts/build-app.sh`
finds it and passes it to the compiler — no `xcode-select`, no `sudo`. The terminal library
also compiles a Metal shader, which needs Xcode's optional Metal toolchain; install it once
with `xcodebuild -downloadComponent MetalToolchain` (BUILDING.md has the exact commands).
`Scripts/doctor.sh` checks for all of this up front and says how to fix whatever is missing.

**[BUILDING.md](BUILDING.md)** has the full story: prerequisites, what each script does,
why the three dependencies are pinned exactly, and what to do when a build goes wrong.

## Gestures and shortcuts

| | |
| --- | --- |
| Two-finger scroll in a session | scrollback, following your fingers line by line; in `less`, `man` or `vim` it scrolls the program, not the scrollback |
| Pinch, or ⌘+ ⌘− ⌘0 | terminal text size, applied to every session and remembered |
| Two-finger double tap | toggle between normal and large text |
| Three-finger swipe, or ⇧⌘] ⇧⌘[ | next / previous session (the swipe needs "Swipe between pages" set to three fingers) |
| ⌘T, ⌘1…⌘9 | new session, jump to a session |
| Drag a session's tab onto the terminal | snap it into a split: an edge gives it that half of the pane, the middle swaps or shows it there |
| Snap Layouts (beside +) | arrange sessions in a ready-made layout, Windows-style: click the zone the focused session goes in |
| Drag the line between panes | resize them; it snaps to halves, thirds and quarters unless Dividers is set to Free. Double-click to even out |
| Drag a pane's header onto the tab bar, or click its × | take it out of the split; the session stays a tab |
| Right click in a session | Copy, Paste, Select All, Clear Scrollback, text size |
| Swipe an instance in the sidebar | right to start or stop it, left to delete it |
| Double-click an instance | open a shell in it, starting it first if it's stopped |
| Drop folders on Mounts | add them as mounts in New Instance |
| Logs | scroll up to pause following, scroll back to the end to resume; ⌘F to search |

## How it talks to the daemon

The app links `apple/container`'s own client libraries and calls them directly:

| What the app does | What it calls |
| --- | --- |
| list, create, start, stop, delete | `ContainerClient` (XPC to `com.apple.container.apiserver`) |
| the killswitch network | `NetworkClient.create/get/delete` |
| image fetch, unpack, kernel, init image | `Utility.containerConfigFromFlags` — the same code path `container run` takes |
| a shell session | `ContainerClient.createProcess` with a guest pty, stdio over pipes |
| the Logs tab | `ContainerClient.logs`, the daemon's own log file handles |
| the status light | `ClientHealthCheck.ping` |

`AgentVMKit` is the whole engine and has no UI dependency; `AgentVMApp` is SwiftUI plus
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for the terminal. The package pins
`container` **1.3.0**: the XPC routes are versioned with the release, so the client and the
daemon you have installed must agree. Upgrade the daemon, bump the pin.

## Instances and tasks

A **run with no command** is an *instance*: its main process is a keepalive loop, so it runs
until **you** stop it. Shell sessions are independent exec processes — open several, close
them in any order, and the container never notices.

A **run with a command** is a *task*: the command is the main process. When it finishes the
container stops and stays in `stopped` (VM torn down, no CPU or RAM) until you delete it.
*One-shot* removes it automatically when the command exits.

The mode is recorded on the container as the `agentvm.mode` label, so the app always knows
which lifetime rules apply — and so does `container inspect`, if you want to look from
outside.

## What it guarantees

**Open is open: direct IP both ways.** The default posture puts the instance on the daemon's
built-in bridge network — vmnet, `192.168.64.0/24`, the host holds the gateway — so it gets
an address reachable **from** the host, and it can reach the host and the internet (NAT) in
return. No port mapping needed. **Killswitch** is the other posture: a dedicated host-only
network created per instance, with DNS switched off — no route off the host, no resolver.
The posture is written to the `agentvm.net` label at creation and is fixed there; nothing inside
the guest can change it, and Start restores exactly the posture the instance was created
with, never more.

**Only the directories you name.** `apple/container` grants no ambient host access, so the
guest sees exactly what the Mounts list passes and nothing else. `/` and your home folder
are refused outright; each mount can be made read-only.

**You control the lifetime.** An instance's keepalive never exits, so no disconnected
session can stop it — only Stop and Delete do. Stop tears the VM down: no IP, no route, no
resolver until Start. Delete removes the container together with its killswitch network;
your mounted directories are your data and are left alone.

**Its own OS.** One Linux kernel per instance, on Virtualization.framework. Instances share
no kernel with each other or with the host. Not namespaces, not Seatbelt.

**Names are namespaced.** Everything is created under the configured prefix (`agentvm-` by
default), and the app only ever lists, deletes or prunes names carrying it. Your other
containers keep their names and stay out of its way.

**A shared env registry.** `~/.config/agentvm/env`, mode 0600, injected into every instance
created from then on. Per-instance variables override it. A running instance keeps the
environment baked in at creation — the app flags instances whose environment predates the
current registry rather than pretending they picked it up.

## Ports

**Ports…** (toolbar, the sidebar's menu, ⌥⌘P) forwards ports on this Mac into an instance:
`8080` → guest `80`, TCP or UDP, ranges allowed. With no address a port listens on
`127.0.0.1` only; name `0.0.0.0` to open it to your network. A killswitch instance can
publish ports too: they let this Mac connect in, and give the guest no route out.

`container` fixes ports at creation and has no API to change them. But its runtime reads
them from the container's bundle every time the VM boots, so AgentVM changes them **while the
instance is stopped** by rewriting `config.json` and `runtime-configuration.json` in
`<app-root>/containers/<name>/`:

- It refuses unless the daemon reports the instance stopped *and* launchd no longer holds
  its runtime helper (checked by Mach service lookup, not `launchctl`).
- It applies the daemon's own rules first: the port parser `container run -p` uses, at most
  64 mappings, no host port used twice.
- It writes with the daemon's own types and encoder, then reads the files back the way the
  daemon will. This matters because a container whose configuration fails to decode is
  deleted when the daemon boots.
- It backs up the originals to `~/.config/agentvm/backups/<name>/` (last 10 kept) and puts them
  back if any step fails.

The daemon keeps an in-memory copy of each configuration, so `container inspect` shows the
old ports until it restarts. The app reads the bundle and shows the ports that apply.

## Configuration

`~/.config/agentvm/config` — the same plain `KEY=VALUE` file as before, editable in Settings or
by hand, re-read on launch. A pre-1.3 `~/.sbx` is moved there automatically.

```
NET=open                  # open = direct IP both ways + internet; none = killswitch
RM=no                     # persist: stays 'stopped' after exit (yes = one-shot)
CPUS=                     # empty = daemon default, 4
MEMORY=                   # empty = daemon default, 1GiB
ENV_FILE=~/.config/agentvm/env # env registry path (mode 0600)
NAME_PREFIX=agentvm-      # the app only touches names with this prefix
```

## Limits

- **macOS 26+ required.** A host-only network — the killswitch — cannot be built on macOS 15.
- **Even the killswitch leaves the host reachable.** A host-only network is still host-only,
  so a compromised agent can reach host services bound to `0.0.0.0`. Bind them to `127.0.0.1`.
- **The registry is a plaintext file.** 0600 in your home directory, never inside a mount.
  If that isn't good enough, keep secrets out of it and pass them per instance.
- **Budget 1–2 GB per instance.** Roughly 8–12 concurrent on a 32 GB machine.
- **N CPUs means the guest sees N+1.** The VM runtime adds an overhead core.
- **arm64 by default; x86 images need Rosetta.** The image's `arm64` variant runs natively.
  An x86-only image needs the Rosetta toggle *and* the Rosetta runtime on the Mac
  (`sudo softwareupdate --install-rosetta`). Don't enable it for arm64 images.
- Images that declare `VOLUME` can leave anonymous volumes behind; Prune deliberately does
  not touch volumes. `container volume list` to check.

## Layout

```
Package.swift              container 1.3.0, containerization 0.41.0, SwiftTerm 1.20.0
Sources/AgentVMKit/            the engine — config, env registry, and every daemon call
Sources/AgentVMLayout/         split panes as plain values: snapping, templates, dividers
Sources/AgentVMApp/            SwiftUI app, terminal sessions
Tests/AgentVMKitTests/         the suite; no daemon, no VM, no network
Tests/AgentVMLayoutTests/      every split-pane rule, plus thousands of random operations
Scripts/                   doctor, build, test, clean
BUILDING.md                building from source, and what to do when it fails
CONTRIBUTING.md            the one rule, the layout, and how to test a change
LICENSE, NOTICE            Apache 2.0, and the credit anything built on AgentVM carries
```

`Scripts/test.sh` runs the tests. They cover the logic that decides what reaches the
system — port specs, the config file, the env registry, mount refusals, name rules —
against temporary directories only: nothing in `~/.config/agentvm` is read or written, and no
container is created.

## License

[Apache License 2.0](LICENSE): use it, change it, and build products on it, commercial
ones included.

**Whatever you ship credits AgentVM.** Anything you distribute that contains AgentVM or is built
from it — the app, `AgentVMKit`, or files taken from either — has to go out with a copy of the
license and the attribution in [NOTICE](NOTICE), which links back to this repository. The
attribution can sit in a NOTICE file shipped with your product, in its source or
documentation, or wherever it shows third-party notices, such as an About or
Acknowledgements window (section 4(d)). Source files you copy keep their copyright header,
and the ones you change say that you changed them (4(b), 4(c)).
