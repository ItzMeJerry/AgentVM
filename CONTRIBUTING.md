# Contributing

Start with [BUILDING.md](BUILDING.md) — it covers the toolchain, the scripts
and the version pins.

```sh
bash Scripts/doctor.sh     # is this machine able to build?
bash Scripts/build-app.sh  # → .build/AgentVM.app
bash Scripts/test.sh       # the AgentVMKit suite
```

## The one rule

**The app never shells out.** No `Process`, no `NSTask`, no `system()`, no
`container` CLI, no `launchctl`. Everything goes through `apple/container`'s own
Swift client libraries — `ContainerClient`, `NetworkClient`, `Utility`,
`ClientHealthCheck` — over XPC to `com.apple.container.apiserver`.

Where there is no API for something, the answer is to use the daemon's own types
against its own files, not to spawn its CLI. `AgentVMEngine+Ports.swift` is the
worked example: `container` 1.3.0 fixes published ports at creation, so AgentVM
rewrites the container bundle while the VM is down, using the daemon's own
`Codable` types and encoder, and checks whether launchd still holds the runtime
helper with a Mach `bootstrap_look_up` rather than by running `launchctl`.

The shell scripts in `Scripts/` are build tooling, not the app. They can do what
shell scripts do.

## Layout

```
Package.swift              container 1.3.0, containerization 0.41.0, SwiftTerm 1.11.2
Sources/AgentVMKit/            the engine — config, env registry, every daemon call.
                           No UI dependency; it builds and tests on its own.
Sources/AgentVMApp/            SwiftUI app, terminal sessions
Tests/AgentVMKitTests/         the suite Scripts/test.sh runs
Scripts/                   doctor, build, test, clean
```

`AgentVMKit` must not import SwiftUI or AppKit. That separation is what lets the
engine be tested without a window, and it is worth keeping.

## Tests

Anything that decides what reaches the system belongs under test: port specs,
config parsing, the env registry, mount refusals, name rules. Those tests run
against temporary directories — no daemon, no VM, no network, and nothing in
`~/.config/agentvm` read or written.

Two habits worth keeping:

- **Test the refusals by name.** "Only the directories you name" is a promise
  the README makes, and it held only because `MountSpec.validated()` refuses `/`
  and `$HOME`. A test that asserted the refusal in every spelling is what caught
  that `$HOME` had stopped being refused at all — Foundation returns a directory
  URL's path with a trailing slash, and the comparison silently stopped matching.
- **Give a test a sentence, not a name.** `@Test("A different address does not
  make a host port free again")` says what the system promises. Read as a list,
  the suite is the specification.

Code that talks to the daemon has a suite of its own, skipped by default:

```sh
AGENTVM_INTEGRATION=1 bash Scripts/test.sh --filter Integration
```

It boots real VMs, so it is slow and needs `container system start`. Everything
it creates is named under the `agentvmit-` prefix, never `agentvm-`, and is deleted
again even when a test fails. Run it before a pull request that touches
`AgentVMEngine`, and say in the pull request which daemon version you ran it
against.

## Style

Match the file you're in. Across the codebase:

- Comments say **why**, not what. A comment that restates the line below it is
  noise; one that records which daemon behaviour forced a decision is the reason
  the next person doesn't undo it.
- Each file opens with a short header saying what it is for, and ends it with
  the license lines: the AgentVM URL, a copyright line and
  `SPDX-License-Identifier: Apache-2.0`.
- Error messages name the thing that went wrong and, in `AgentVMError`'s `hint`,
  what to do about it. They are shown to people, not logged.
- UI strings are plain: "Stop the instance to change them", not "Operation not
  permitted in current state".

`swift-format` ships with the toolchain if you want it; there is no enforced
configuration and no formatting CI.

## Pull requests

Say what you changed, and what you ran to check it. If it touches anything that
talks to the daemon, say which daemon version you tested against.

## License

AgentVM is licensed under Apache-2.0, and a pull request is a contribution under
the same terms (section 5 of [LICENSE](LICENSE)). There is nothing else to sign.
