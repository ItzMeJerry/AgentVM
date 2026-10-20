# Building AgentVM from source

AgentVM is a SwiftPM package. There is no Xcode project to open and nothing to
configure — `Scripts/build-app.sh` produces `.build/AgentVM.app`.

```sh
git clone https://github.com/ItzMeJerry/AgentVM.git
cd AgentVM
bash Scripts/doctor.sh     # check the machine first (optional; the build runs it too)
bash Scripts/build-app.sh  # → .build/AgentVM.app
open .build/AgentVM.app
```

## What you need

| | |
| --- | --- |
| **macOS 26 or later** | A host-only network — the killswitch — cannot be built on macOS 15. |
| **Apple Silicon** | `apple/container` runs Linux VMs on Virtualization.framework; there is no Intel path. |
| **Xcode** | Installed, not just the Command Line Tools. See below. |
| **Xcode's Metal toolchain** | An optional Xcode component; the terminal library compiles a Metal shader. See below. |
| **~4 GB of disk** | What a clean `.build` weighs. |
| **A working network** | The first build clones `apple/container` and its whole dependency graph. |
| **`container` 1.3.0** | Only to *run* it. The build needs no daemon. |

### The Metal toolchain

The terminal is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), which
ships a Metal shader that the build compiles — and so does AgentVM, which
builds its own copy of that shader into the app (see `TerminalShaders.metal`).
The compiler for them is an optional Xcode component. Install it once:

```sh
sudo /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -license accept
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -downloadComponent MetalToolchain
```

Xcode's `xcodebuild` is named by its full path because a plain `xcodebuild`
refuses to run while the Command Line Tools are the selected toolchain.

The scripts find it inside Xcode and put it on `PATH` for the build, so the
Command Line Tools can stay selected. `bash Scripts/doctor.sh` says whether
it is there.

### Why Xcode and not just the Command Line Tools

SwiftUI's property wrappers — `@State`, `@Binding`, `@Environment` — are macros
now, and the plugin that expands them, `libSwiftUIMacros.dylib`, ships inside
Xcode.app. The Command Line Tools don't carry it, so a CLT-only machine fails
with *"external macro implementation type could not be found"*.

You do **not** need to `xcode-select` to Xcode, and you don't need `sudo`.
`Scripts/build-app.sh` finds the plugin inside Xcode.app and passes
`-plugin-path` to the compiler. Install Xcode from the App Store, open it once
so it finishes setting itself up, and build.

## The scripts

Run them with `bash`, as every example here does; that works whether or not
your checkout marks them executable.

| | |
| --- | --- |
| `Scripts/doctor.sh` | Checks macOS, architecture, disk, toolchain, macro plugin and the daemon, and says how to fix whatever is missing. `--quiet` prints only problems. |
| `Scripts/build-app.sh [debug\|release]` | Builds the executable and wraps it in `.build/AgentVM.app`. Release by default. |
| `Scripts/test.sh` | Runs the unit tests, both targets'. Takes any `swift test` arguments. |
| `Scripts/clean.sh [--all]` | Drops compiled output. `--all` drops the checkouts too. |
| `Scripts/toolchain.sh` | Sourced by the others; finds the macro plugins and the Metal compiler. Not run directly. |

`build-app.sh` runs `doctor.sh --quiet` first, so a machine that can't build
says why in a second rather than in ten minutes. `AGENTVM_SKIP_DOCTOR=1` skips it.

## How long it takes

The first build resolves and compiles the `apple/container` package graph —
SwiftNIO, gRPC, BoringSSL, SwiftProtobuf, swift-certificates, the
containerization stack. **Budget 15–30 minutes.** After that, builds are
incremental and take about 30 seconds.

`Scripts/clean.sh` without `--all` keeps the ~650 MB of checkouts, so a clean
rebuild only recompiles rather than re-cloning.

## Running the tests

```sh
bash Scripts/test.sh
bash Scripts/test.sh --filter PortMapping     # one suite
```

The tests need no daemon, no VM and no network; `~/.config/agentvm` is never
read or written, and no container is created. The one suite that does talk to
the daemon is skipped unless you ask for it. [CONTRIBUTING.md](CONTRIBUTING.md#tests)
says what each covers and how to run that one.

## The app bundle

`.build/AgentVM.app` is a plain, **unsandboxed** macOS app, ad-hoc signed. That is
deliberate: it talks to `com.apple.container.apiserver` over XPC and bind-mounts
directories you pick, and a sandboxed app can do neither.

A release build is stripped of its symbols, which halves the app. They're kept
in `.build/release/agentvm-gui.dSYM`, which still symbolicates a crash report
from it; a debug build keeps them in place.

Ad-hoc signing is enough to run it locally. To hand it to someone else you need
your own Developer ID signature and notarization; this repo ships no signing
identity and no notarization step.

Handing it on also means handing on the licenses: [LICENSE](LICENSE) and
[NOTICE](NOTICE) from here, plus the LICENSE and NOTICE files of the packages
compiled into it, which are in their checkouts under `.build/checkouts/`.

Move `.build/AgentVM.app` wherever you like — `/Applications` works. It keeps
nothing inside its own bundle: configuration lives in `~/.config/agentvm`, and the
instances belong to the `container` daemon.

## Version pins

`Package.swift` pins three dependencies exactly, each for a reason:

- **`apple/container` 1.3.0** — the XPC routes and payloads are versioned with
  the release, so the client libraries this links and the daemon you have
  installed must agree. Upgrading the daemon means bumping this pin.
- **`apple/containerization` 0.41.0** — the version `container` 1.3.0 itself
  resolves to. Named directly so the app can use its types.
- **`SwiftTerm` 1.20.0** — its own scrolling is line-accurate on a trackpad,
  reports the wheel to programs that track the mouse, and supports Alternate
  Scroll Mode (DECSET 1007), so the app uses it instead of reimplementing it.
  It is the last release before upstream's announced breaking changes, and it
  needs the Metal toolchain above. AgentVM ships a copy of its Metal shaders
  with dark text blended the way macOS blends it, so bumping this pin means
  copying the new `Shaders.metal` over that copy and redoing the one marked
  change: `build-app.sh` stops until you do.

`Package.resolved` is committed, so a clone builds the same graph you do.

## Troubleshooting

**`external macro implementation type ... could not be found`**
The macro plugin isn't being found. Run `bash Scripts/doctor.sh`; if it reports
the SwiftUI macro plugin missing, install Xcode and open it once.

**`unable to spawn process 'metal'`**
Xcode's Metal toolchain isn't installed; see [The Metal toolchain](#the-metal-toolchain).

**`ld: warning: search path '.../Developer/Library/Frameworks' not found`**
Harmless. It comes from building against a CLT toolchain and does not affect
the result.

**The app launches but every instance action fails**
The daemon isn't running. `container system start`, then use **Refresh Now** in the
app's sidebar menu. The status light in the sidebar reflects
`ClientHealthCheck.ping`.

**The app builds but the daemon refuses its calls**
Your `container` daemon is a different version from the 1.3.0 the client
libraries are pinned to. `container --version` to check; `Scripts/doctor.sh`
warns about a mismatch.

**The first build sits on "Fetching *&lt;something&gt;*" and never moves**
The package graph is ~35 repositories and some of them are large; a slow or
stalled connection to GitHub can leave `git` waiting indefinitely rather than
failing. Tell git to give up on a stalled transfer instead:

```sh
git config --global http.lowSpeedLimit 1000   # bytes/second
git config --global http.lowSpeedTime 60      # ...sustained for this long
```

SwiftPM retries a failed clone once without its cache, so a single bad transfer
usually recovers by itself. `git ls-remote https://github.com/apple/swift-protobuf.git`
is a quick way to tell a dead network from one slow connection.

**A build fails halfway through the dependency graph**
Usually a network hiccup during the first resolve. `bash Scripts/clean.sh --all`
and build again.
