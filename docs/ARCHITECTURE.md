# Architecture

Meth is four executables in one app bundle, sharing a static library (`MethCore`).

```text
Meth.app/Contents/
├── MacOS/Meth                   menu bar UI (LSUIElement, AppKit + SwiftUI)
├── MacOS/MethAgent              per-user session controller (LaunchAgent, on demand)
├── MacOS/MethHelper             root helper for Overdose only (LaunchDaemon)
├── Helpers/meth                 CLI
├── Library/LaunchAgents/…Agent.plist
├── Library/LaunchDaemons/…Helper.plist
└── Frameworks/Sparkle.framework
```

```text
 Meth.app ─┐                       ┌─ IOPMAssertion (Bump/High/Overdose)
           ├─ XPC ─► MethAgent ────┤
 meth CLI ─┘   (user)              └─ XPC ─► MethHelper (root) ─► /usr/bin/pmset -a disablesleep 0|1
```

## Why a separate agent?

IOKit power assertions belong to the process that created them. If the menu bar app owned them,
the CLI could not work while the app was closed, and two processes could compete. Instead
**`MethAgent` is the single authoritative owner** (`SessionController`, a Swift actor). The app
and the CLI are thin clients:

- The CLI works with the app closed. launchd starts the agent on demand through its Mach service.
- The app shows exactly what the agent reports. A mode is never shown as active until its
  power operation has succeeded.
- State changes are pushed to the app over the same XPC connection, so a CLI change shows up immediately.
- When nothing is active and no client is connected, the agent exits after 30 s (idle CPU and memory: zero).

The agent is registered with `SMAppService.agent` (no admin rights) and has `RunAtLoad`, so a timed
session can resume after a restart. It has `KeepAlive.SuccessfulExit = false`, so launchd relaunches
it after a crash.

## Transitions

All requests pass through a FIFO async gate inside the actor, so rapid clicks, concurrent CLI calls
and a timer firing mid-switch are applied one at a time. For each switch:

1. Validate (duration bounds, Overdose policy, caller identity).
2. Acquire the new mode's assertions (all or none).
3. For Overdose, ask the helper; if that fails, roll back step 2 and keep the old mode.
   When leaving Overdose, ask the helper to restore.
4. Release the old assertions. Then persist, schedule the expiry, and notify clients.

Re-selecting a mode (or changing the duration while active) restarts the countdown from now.

## Time

- Deadlines are tracked on the **continuous clock** (`CLOCK_MONOTONIC` = `mach_continuous_time`):
  it counts during sleep and ignores wall-clock changes. A deadline that passes during sleep fires right after wake.
- The persisted record also stores the wall-clock `expiresAt` and the boot session UUID. Within the same
  boot the continuous deadline is authoritative; after a reboot the wall-clock deadline is used.
- There is no polling. One timer per session (plus the Overdose lease timer). The popover's
  per-second label runs only while it is visible; the menu bar label updates once a minute.

## Recovery rules

| Event | Bump / High | Overdose |
|---|---|---|
| App quits or crashes | Unaffected (the agent owns the session) | Unaffected |
| Agent crashes | launchd relaunches it; the session resumes | Resumes only if the helper still holds that exact session |
| Logout / SIGTERM | Assertions released; a timed record is kept | Restored immediately |
| Restart | A timed session with time left resumes; an indefinite one does not | **Never resumes.** The helper restores at boot |
| Timer expires during sleep | Ends on wake | Ends on wake; the helper enforces its own deadline too |
| Update installed | The old agent keeps running the session; the new app replaces it once idle | Same |

## Overdose and the privileged helper

`MethHelper` is a LaunchDaemon registered through `SMAppService.daemon`. The user must approve it in
System Settings › General › Login Items. Registering does **not** grant root by itself; macOS asks.

Its interface (`HelperRequest`) is four JSON messages: `status`, `begin(session, deadline | lease)`,
`renew(session)`, `end(session)`. There is no generic command execution. `pmset` is invoked with a fixed
argument vector, without a shell.

- **Caller validation.** XPC enforces the code requirement
  `anchor apple generic and certificate leaf[subject.OU] = "<TEAM>" and identifier "…Meth.Agent"` before
  any message is delivered. An ad-hoc-signed helper refuses every connection (fail closed).
- **Argument validation.** Exactly one of deadline (1 s – 24 h) or lease (1 s – 1 h). Payloads are limited to 4 KB and must carry the expected protocol version.
- **Original value.** `SleepDisabled` is read first and the record is persisted to
  `/Library/Application Support/Meth/overdose-state.json` (root-only, 0600) **before** `pmset` runs.
  After writing, the value is read back; if the Mac ignored it, the change is reverted and Overdose reports `overdose_unsupported`.
- **Restore.** The original value is written back only if Meth changed it and it is still `1`.
  If it was already `1`, it is left alone. If someone already set it back to `0`, Meth doesn't write anything.
- **Bounded lifetime.** The helper has its own deadline timer. Indefinite Overdose uses a 10-minute lease that
  the agent renews every 3 minutes, so if the agent dies, sleep is restored within 10 minutes. On SIGTERM
  (shutdown, or the user removing the login item) the helper restores immediately. `RunAtLoad` restores any record left from a previous boot.

`disablesleep` is a single global setting (shown as `SleepDisabled` in `pmset -g`); unlike `sleep` or `displaysleep`
it is not stored per power source, so restoring one value covers AC and battery.

## IPC security

- Mach services in the user's launchd domain (agent) and the system domain (helper). There is no TCP and no files acting as sockets.
- `NSXPCListener.setConnectionCodeSigningRequirement`: the agent accepts only Meth.app and the `meth` CLI.
  With Developer ID builds, both must be signed by the same team.
- The caller's role (app vs CLI) comes from its **code signature** (kernel audit token → `SecTask`), never from the message.
  Only the app may change preferences such as *Allow Overdose from Command Line*.
- Clients verify the server too (`NSXPCConnection.setCodeSigningRequirement`).

## Updates

Sparkle 2 (`SPUStandardUpdaterController`), EdDSA-signed archives, HTTPS appcast on GitHub Pages,
archives on GitHub Releases. `sparkle:version` = `CFBundleVersion`, which only ever increases.
After an update the app sees that the agent's version differs and sends `restartIfIdle`, so the new agent binary takes over
without interrupting a session.

## Localization

The app uses a String Catalog (`Meth/Resources/Localizable.xcstrings`, generated from
`Scripts/i18n/translations.py`) for en, th and zh-Hans. The in-app language picker sets the per-app `AppleLanguages`
(the same mechanism as System Settings). The CLI carries its own small string table (`CLIStrings`) because it has no
resource bundle; it reads the app's language choice. Mode names stay in English everywhere.
`./Scripts/test.sh` fails if a UI string has no translation.
