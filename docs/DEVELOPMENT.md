# Development

## Requirements

- macOS 14+ and Xcode 16 or newer (Swift 6 language mode). Built and tested with Xcode 27 / Swift 6.4.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`. `project.yml` is the source of truth; `Meth.xcodeproj` is generated (and committed for convenience).
- Python 3 (localization catalog, DMG layout via `dmgbuild` in a local venv).

## Layout

| Path | Contents |
|---|---|
| `MethCore/` | Shared logic: modes, durations, session controller, Overdose engine, IPC, CLI parsing/strings |
| `Meth/` | Menu bar app (App, UI, Services, Updates, Resources, Assets) |
| `MethAgent/` | Per-user controller (LaunchAgent) |
| `MethHelper/` | Root helper (LaunchDaemon), Overdose only |
| `MethCLI/` | `meth` executable |
| `MethTests/`, `MethUITests/` | Tests |
| `Scripts/` | Build, test, sign, package, notarize, release |
| `Config/` | xcconfigs; `Version.xcconfig` holds the version |

## Everyday commands

```bash
xcodegen generate                  # after editing project.yml or adding files
./Scripts/build.sh Debug           # or open Meth.xcodeproj and run the "Meth" scheme
./Scripts/build.sh                 # universal Release → dist/Meth.app
./Scripts/test.sh                  # unit tests + translation coverage
./Scripts/test.sh --ui             # + UI tests (grant Accessibility to Xcode/Terminal)
./Scripts/generate-assets.sh       # re-render icon, logo, DMG background from SyringeGlyph
```

Expected outputs:

```text
dist/
├── Meth.app
├── Meth-0.1.0.dmg        (package-dmg.sh)
├── Meth-0.1.0.zip        (Sparkle archive)
├── checksums.txt
└── appcast.xml           (release.sh)
```

## Running a local build

Local builds are **ad-hoc signed**. That works for Bump, High and the CLI. The Overdose helper refuses all
connections unless it is Developer ID signed (fail closed), so test Overdose with
`./Scripts/build.sh && ./Scripts/sign.sh`.

Only keep **one** copy of Meth.app registered at a time. launchd resolves the agent by bundle identifier,
so a stale copy elsewhere (for example in DerivedData) can be launched instead. If `meth` reports
`agent_unavailable`, quit Meth, delete other copies, and relaunch. The app re-registers its agent automatically when it can't reach it.

Useful commands:

```bash
launchctl print gui/$(id -u)/io.github.kroekkarawit.Meth.Agent   # agent state
pmset -g assertions | grep Meth:                                 # live assertions
log stream --predicate 'subsystem BEGINSWITH "io.github.kroekkarawit.Meth"'
```

## Tests

- Unit tests (`MethTests`) cover duration and CLI parsing, JSON schema, exit codes, state transitions,
  expiry, wall-clock changes, crash/reboot recovery, concurrency, Overdose restore/conflict logic and persistence. They use
  mocked clocks, schedulers, assertions and a fake `pmset`. **No test touches real system settings.**
- UI tests (`MethUITests`) launch the app with `--show-popover` and drive the real popover.
- If the test runner times out "while preparing to run tests" on an external volume, point
  `-derivedDataPath` at the internal disk.

## Localization

Add or change UI text in Swift, then add the Thai and Chinese strings to `Scripts/i18n/translations.py` and run
`python3 Scripts/i18n/build-catalog.py`. `./Scripts/test.sh` fails on missing translations. CLI strings live in
`MethCore/CLIStrings.swift`.

## Style

Swift 6 strict concurrency, no third-party dependencies besides Sparkle, no telemetry, no network access except Sparkle.
