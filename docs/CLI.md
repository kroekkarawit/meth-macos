# `meth` command-line reference

`meth` is a thin client. It sends one request to Meth's per-user controller over XPC,
prints the result and exits. It never runs as root and never holds power assertions itself.

## Install

From the app: **Meth Settings → Install Command Line Tool…**

- **Install for Me** creates the symlink `~/.local/bin/meth` → `/Applications/Meth.app/Contents/Helpers/meth` (no password).
- **Install for All Users…** creates the symlink `/usr/local/bin/meth` (asks for an administrator password).

Because these are symlinks into the app bundle, Sparkle updates also update the CLI. Meth never
overwrites a `meth` file it did not create, and never edits your shell configuration. If
`~/.local/bin` is not on your `PATH`, add:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Manual alternative: `ln -s /Applications/Meth.app/Contents/Helpers/meth /usr/local/bin/meth`.

## Commands

| Command | Effect |
|---|---|
| `meth bump [--for D]` | Prevent idle system sleep (display may sleep). |
| `meth high [--for D]` | Prevent idle system and display sleep. |
| `meth overdose --for D` | High + system-wide `disablesleep`. `--for` is required, `D` ≤ 24h. Must be enabled in the app first. |
| `meth sober` / `meth stop` | Release everything, restore original settings. Idempotent. |
| `meth status` | Current mode and remaining time. |
| `meth version` / `--version` | Print version. |
| `meth help` / `--help` | Usage. |

Global options: `--json` (machine-readable output), `--lang en|th|zh`.

Behaviour rules:

- Without `--for`, Bump and High run **until `meth sober`**.
- Running a mode again (same or different) **replaces** the current session. The countdown restarts from now with the new duration.
  Switching is gap-free: the new assertions are taken before the old ones are released.
- Timed sessions expire on their own even if the app is quit. The deadline uses a clock that
  keeps counting during sleep and ignores wall-clock changes.
- If the controller isn't running yet, `meth` starts Meth.app in the background (no window) and retries for a few seconds.

## Durations

Units are mandatory: `s`, `m`, `h`, `d`, combinable in descending order.

| OK | Rejected |
|---|---|
| `45s` `15m` `90m` `2h` `1h30m` `1d` `inf` `∞` `forever` | `10` (no unit) · `0m` · `-5m` · `1.5h` · `30m1h` · `> 30d` (`> 24h` for Overdose) |

## Output

```text
$ meth status
Meth v0.1.0
Mode: High
Status: Active
Remaining: 01:42:15
```

Human output follows `--lang`, then `METH_LANG`, then the language chosen in Meth.app, then the system language.
JSON output, error codes and exit codes are **never** localized.

### JSON schema (`schemaVersion: 1`)

Every key is always present; missing values are `null`. Timestamps are ISO 8601 UTC.
Output is a single line.

```json
{
  "schemaVersion": 1,
  "app": "Meth",
  "version": "0.1.0",
  "agentVersion": "0.1.0",
  "mode": "high",
  "status": "active",
  "indefinite": false,
  "remainingSeconds": 6135,
  "durationSeconds": 7200,
  "startedAt": "2026-11-25T08:17:45Z",
  "expiresAt": "2026-11-25T10:17:45Z",
  "source": "cli",
  "allowOverdoseFromCLI": false,
  "warnings": []
}
```

| Key | Type | Notes |
|---|---|---|
| `mode` | `"sober" \| "bump" \| "high" \| "overdose"` | Stable identifiers |
| `status` | `"active" \| "inactive"` | `inactive` ⇔ `mode == "sober"` |
| `indefinite` | bool | Active with no time limit |
| `remainingSeconds`, `durationSeconds` | int or null | null when sober or indefinite |
| `startedAt`, `expiresAt` | string or null | `expiresAt` is recomputed at query time |
| `source` | `"app" \| "cli" \| "system"` or null | Who started the session |
| `warnings` | array of `{code, message}` | Non-fatal, e.g. `restore_conflict` |

Errors (with `--json`, written to **stdout**; otherwise a message on stderr):

```json
{"schemaVersion":1,"app":"Meth","error":{"code":"invalid_duration","message":"Invalid duration “10”. Use forms like 30m, 2h, 1h30m, 45s or inf."}}
```

### Exit codes

| Code | Meaning | Error codes |
|---|---|---|
| 0 | Success | — |
| 1 | Internal error | `internal` |
| 2 | Usage | `usage`, `unknown_command`, `invalid_duration`, `duration_required` |
| 3 | Meth not reachable | `agent_unavailable` |
| 4 | Overdose unavailable / not allowed | `helper_unavailable`, `helper_requires_approval`, `overdose_not_allowed`, `overdose_unsupported`, `indefinite_overdose_requires_confirmation` |
| 5 | Power operation failed | `assertion_failed`, `privileged_operation_failed`, `restore_conflict` |
| 6 | Unauthorized | `unauthorized_client` |

## Shell patterns

Keep awake for the duration of a command, then go back to sober:

```bash
meth high --for 2h
trap 'meth sober >/dev/null' EXIT
make release
```

Restore **whatever was active before** (another script or the user may have started a session):

```bash
prev="$(meth status --json)"
restore() {
  mode="$(printf '%s' "$prev" | python3 -c 'import json,sys;print(json.load(sys.stdin)["mode"])')"
  left="$(printf '%s' "$prev" | python3 -c 'import json,sys;v=json.load(sys.stdin)["remainingSeconds"];print("" if v is None else v)')"
  case "$mode" in
    sober)     meth sober >/dev/null ;;
    bump|high) if [ -n "$left" ]; then meth "$mode" --for "${left}s" >/dev/null; else meth "$mode" >/dev/null; fi ;;
    *)         meth sober >/dev/null ;;   # never re-enter Overdose automatically
  esac
}
trap restore EXIT
meth high --for 3h
./long-task.sh
```

(If you have `jq`: `jq -r .mode`.) The time the job itself took is not subtracted from `left`, so this restores slightly generously.

## AI agents

The CLI is the whole integration surface: no MCP server, no screenshots, no GUI scripting.
Paste this into `AGENTS.md`, `CLAUDE.md` or your Codex instructions:

```markdown
## Keeping the Mac awake
- Before long-running work (builds, test suites, downloads) run `meth high --for <estimate>` (e.g. `--for 2h`).
- When finished, run `meth sober`. Use `trap 'meth sober' EXIT` in scripts.
- Check state with `meth status --json` (fields: mode, status, remainingSeconds, expiresAt).
- Non-zero exit = failure; exit 3 means Meth is not installed/running — continue without it.
- Never run `meth overdose` unless the user explicitly asked for it.
```

Authorization boundaries:

- Bump and High need no privileges.
- `meth overdose` fails with `overdose_not_allowed` (exit 4) until a human enables
  **Allow Overdose from Command Line** in the app. The CLI cannot change that preference itself,
  because the controller checks the caller's code signature.
- Even when allowed, Overdose needs `--for` (≤ 24h). The root helper enforces its own deadline,
  so a crashed or killed script cannot leave sleep disabled.
