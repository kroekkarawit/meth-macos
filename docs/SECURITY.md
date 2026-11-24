# Security model

## Assets

1. The system-wide `disablesleep` setting (requires root).
2. The user's sleep behaviour (Bump/High: unprivileged IOKit assertions).
3. The update channel (code that will run on the user's Mac).

## Privilege boundaries

| Component | Runs as | Can do |
|---|---|---|
| Meth.app | user | UI; talks to the agent |
| `meth` CLI | user | Talks to the agent |
| MethAgent | user | IOKit power assertions; talks to the helper |
| MethHelper | **root** | `pmset -a disablesleep 0|1`, restore only |

Nothing else runs as root. There is no sudo, no `AuthorizationExecuteWithPrivileges`, no stored passwords, and no shell
in the privileged path. `pmset` is executed with a fixed `argv` and a fixed `PATH`.

## Threats and mitigations

| Threat | Mitigation |
|---|---|
| Another local process drives the helper | XPC code-signing requirement on the listener: same Developer ID team **and** the agent's identifier. Unsigned or ad-hoc helpers refuse every connection. |
| Another process impersonates the app to grant CLI Overdose | The caller role comes from its code signature (audit token → `SecTask`). The envelope's self-declared source is ignored. |
| Malformed or oversized helper messages | Versioned JSON, ≤ 4 KB, exhaustive `Codable` enums, range checks (deadline 1 s–24 h, lease 1 s–1 h). |
| Sleep left disabled after a crash, kill, logout, reboot or uninstall | Original value persisted before the change; helper-owned deadline/lease timers; restore on SIGTERM; restore at boot (`RunAtLoad`); boot-session check. |
| Clobbering the user's own power settings | Only `disablesleep` is touched. A value that was already `1` is left alone, and an external reset to `0` is detected and not overwritten. Bump/High never change persistent settings. |
| AI agent escalation | CLI Overdose is off by default. Only the app (human) can enable it, and it still requires `--for` ≤ 24 h. |
| Malicious update | Sparkle EdDSA signatures (public key in Info.plist, private key never in the repo or logs), HTTPS feed and downloads, Developer ID + notarization verified by Gatekeeper. |
| Network exposure | None. Mach services only; no TCP listener. The only network access is Sparkle's update check. |
| Data collection | None. No telemetry or analytics. |

## Files

| Path | Owner / mode | Content |
|---|---|---|
| `~/Library/Application Support/Meth/session.json` | user, 0600 (dir 0700) | Current session for recovery |
| `~/Library/Application Support/Meth/agent-preferences.json` | user, 0600 | `allowOverdoseFromCLI` |
| `/Library/Application Support/Meth/overdose-state.json` | root, 0600 (dir 0700) | Original `disablesleep` value, deadline |

## Known non-goals

Meth cannot override hardware- or firmware-enforced sleep (thermal or battery emergencies). A user who already has root
can of course change any setting; Meth does not defend against the machine's own administrator.
