# Contributing to Meth

Thanks for helping! Meth aims to stay **small, native and boring**: few features, no
dependencies beyond Sparkle, no telemetry.

## Getting started

```bash
brew install xcodegen
xcodegen generate
./Scripts/test.sh
open Meth.xcodeproj
```

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for layout and debugging tips.

## Pull requests

- One topic per PR. Explain *why* in the description.
- Add or adjust tests in `MethTests` for logic changes; tests must never touch real system power settings (use the mocks).
- New UI text needs Thai and Simplified Chinese strings in `Scripts/i18n/translations.py` (CI enforces this).
- Changes to `MethHelper`, XPC authentication or the update pipeline get extra review. Keep the helper's interface minimal.
- Follow the Apple Human Interface Guidelines: native controls, system colors, SF Symbols, no custom chrome.
- Update `CHANGELOG.md` under an `Unreleased` heading.

## Reporting bugs

Use the issue templates. Include `meth version`, `sw_vers`, your Mac model and, if relevant,
`meth status --json` and `pmset -g assertions | grep Meth:`.
Security issues: see [SECURITY.md](SECURITY.md) (please report privately).

## Code of conduct

Be kind. The app's name is a joke; the way we treat each other isn't.
