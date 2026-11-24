# Releasing Meth

A release is: universal build → Developer ID signing (inside-out, hardened runtime) → notarize
and staple the app → DMG + Sparkle zip → notarize and staple the DMG → checksums → EdDSA signature →
appcast → GitHub Release → appcast on GitHub Pages → verify the public URLs.

## One-time setup (release machine)

### Signing

A **Developer ID Application** certificate (not "Apple Development" or "Apple Distribution"):

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

If there are several, set `METH_SIGN_IDENTITY` to the SHA-1 hash.

### Notarization

Store credentials in the keychain once (app-specific password from appleid.apple.com, or an App Store Connect API key):

```bash
xcrun notarytool store-credentials meth-notary \
  --apple-id "<apple-id>" --team-id HN37P384P3 --password "<app-specific-password>"
# or
xcrun notarytool store-credentials meth-notary --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-uuid>
```

Scripts use the profile `meth-notary` by default (`NOTARY_PROFILE` to override).

### Sparkle key

The EdDSA private key lives in the login keychain under the account `meth-macos`:

```bash
build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account meth-macos -p   # print public key
build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account meth-macos -x sparkle_private.key  # export for CI
```

The public key is in `Config/Shared.xcconfig` (`SPARKLE_PUBLIC_ED_KEY`). **Never commit the private key.**
Losing it means existing installs can no longer verify updates.

## Cutting a release locally

1. Add a `## [x.y.z] - YYYY-MM-DD` section to `CHANGELOG.md` and commit it.
2. Dry run (builds, signs, notarizes, packages; publishes nothing):
   ```bash
   ./Scripts/release.sh 0.2.0
   ```
3. Ship:
   ```bash
   ./Scripts/release.sh 0.2.0 --publish
   ```
   This bumps `Config/Version.xcconfig` (the build number always increments), commits, tags `v0.2.0`,
   creates the GitHub Release with the DMG, zip and `checksums.txt`, pushes `appcast.xml` to the `gh-pages`
   branch, then runs `Scripts/verify-release.sh` (downloads, checksums, appcast entry, Gatekeeper).

## Cutting a release from CI

`.github/workflows/release.yml` runs on `v*` tags and does the same steps on a macOS runner.
It skips the tag if that release already exists (e.g. when it was published locally).

Required repository secrets:

| Secret | Value |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | `base64 -i DeveloperID.p12` (certificate + private key) |
| `DEVELOPER_ID_P12_PASSWORD` | Password of the .p12 |
| `NOTARY_KEY_P8_BASE64` | `base64 -i AuthKey_XXXX.p8` (App Store Connect API key, "Developer" role) |
| `NOTARY_KEY_ID` | API key ID |
| `NOTARY_ISSUER_ID` | API issuer UUID |
| `SPARKLE_PRIVATE_KEY` | Contents of `sparkle_private.key` exported above |

The certificate goes into a temporary keychain that is deleted at the end of the job. Secrets are only passed as files and env vars, never echoed.
Also enable GitHub Pages for the `gh-pages` branch (Settings → Pages).

## Verifying by hand

```bash
codesign --verify --deep --strict --verbose=2 dist/Meth.app
spctl --assess --type execute --verbose dist/Meth.app
xcrun stapler validate dist/Meth.app
xcrun stapler validate dist/Meth-0.2.0.dmg
spctl --assess --type open --context context:primary-signature --verbose dist/Meth-0.2.0.dmg
shasum -a 256 -c dist/checksums.txt
```

## Testing an update

1. Install the previous release into /Applications and launch it.
2. Publish the new release (appcast updated).
3. **Meth Settings → Check for Updates…**. Sparkle shows the release notes, then downloads, verifies the
   EdDSA signature, installs and relaunches.
4. `meth version` shows the new version; an active session keeps running.

Headless alternative, using Sparkle's own CLI against the installed app:

```bash
sparkle.app/Contents/MacOS/sparkle --check-immediately --verbose /Applications/Meth.app
```

## Versioning

Semantic Versioning for `CFBundleShortVersionString`. `CFBundleVersion` is a monotonically increasing integer.
`Scripts/appcast.py` refuses to publish a build number that is not newer than the published ones.
