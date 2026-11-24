# Troubleshooting

### `meth: Error: Meth agent is not reachable` (exit 3)

- Open Meth.app once. It registers the background controller.
- Check **System Settings › General › Login Items › Allow in the Background**: *Meth* must be on.
- Only one copy of Meth.app should exist. Delete old copies (Downloads, the DMG volume), then relaunch.
- Inspect: `launchctl print gui/$(id -u)/io.github.kroekkarawit.Meth.Agent`. If it shows
  `last exit reason = OS_REASON_CODESIGNING`, quit and relaunch Meth.app. The app re-registers the agent automatically.

### Overdose says the helper needs approval

Enable *Meth* in **System Settings › General › Login Items**, then choose Overdose again.
macOS requires this approval for any root helper. Meth cannot (and won't try to) bypass it.

### `overdose_not_allowed` from the CLI

On purpose. Enable **Meth Settings → Allow Overdose from Command Line** in the app.

### `overdose_unsupported`

This Mac did not accept `disablesleep` (the value didn't change after writing it). Use High instead.

### My Mac slept anyway

- With the lid closed on battery power, macOS sleeps regardless of Bump/High. Only Overdose prevents that.
- Thermal and low-battery emergency sleep cannot be prevented by any app.
- Check what is active: `pmset -g assertions | grep Meth:` and `meth status`.

### Sleep is still disabled after Overdose

Meth restores only what it changed. If `pmset -g | grep SleepDisabled` still shows `1`:

- It was already `1` before Overdose started (Meth leaves it as it found it), or
- the helper hasn't run yet (it restores within the deadline or lease, and at the next boot).

Manual reset: `sudo pmset -a disablesleep 0`.

### Remove Meth completely

1. Choose **Sober**. Then **Meth Settings → Enable/Remove Overdose Helper…** to remove the helper.
2. Quit Meth and delete `/Applications/Meth.app`.
3. Optional cleanup: `~/Library/Application Support/Meth`, `~/.local/bin/meth`,
   `/usr/local/bin/meth`, `/Library/Application Support/Meth` (root).

### Logs

```bash
log show --last 1h --predicate 'subsystem BEGINSWITH "io.github.kroekkarawit.Meth"'
```
