# Changelog

All notable changes to Meth are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-11-25

### Added
- Sessions tied to an app or process (popover “While an App Is Running”, CLI `--while-pid`).
- “Until a time” (`--until 18:00`), custom durations and “Add Time” (`meth extend 30m`).
- Battery safety: sessions end at a low-battery limit (default 10%) and, optionally, when unplugged.
- Automatic rules: stay awake while charging or while an external display is connected.
- Global keyboard shortcuts ⌃⌥⌘0–3.
- While you’re away: keep chat apps showing you as active, lock the screen after inactivity.
- Download site and update feed served by a Cloudflare Worker.
- Menu bar app with Bump, High, Overdose and Sober modes, and a 30m / 1h / 4h / ∞ duration selector.
- Menu bar icon that shows the active mode, plus an optional time-left label.
- `meth` command-line tool with a stable JSON schema and documented exit codes.
- Per-user session controller shared by the app and the CLI, with crash and restart recovery.
- Overdose through a narrow, code-signature-validated privileged helper that restores the original setting.
- English, Thai and Simplified Chinese in both the app and the CLI.
- Sparkle 2 automatic updates with EdDSA signatures.
