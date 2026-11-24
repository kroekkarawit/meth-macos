# Changelog

All notable changes to Meth are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-11-25

### Added
- Menu bar app with Bump, High, Overdose and Sober modes, and a 30m / 1h / 4h / ∞ duration selector.
- Menu bar icon that shows the active mode, plus an optional time-left label.
- `meth` command-line tool with a stable JSON schema and documented exit codes.
- Per-user session controller shared by the app and the CLI, with crash and restart recovery.
- Overdose through a narrow, code-signature-validated privileged helper that restores the original setting.
- English, Thai and Simplified Chinese in both the app and the CLI.
- Sparkle 2 automatic updates with EdDSA signatures.
