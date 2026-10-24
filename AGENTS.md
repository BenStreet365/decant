# AGENTS.md

decant is a Swift command-line tool, plus a small app (Decant.app), that installs drag-and-drop
disk images into `~/Applications` for MDM deployments. [README.md](README.md) is the admin guide; [docs/SECURITY.md](docs/SECURITY.md) has the security
model and [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) covers building and testing.

## Layout

- `Sources/DecantCore/`: installation logic, signature checks, policy and configuration.
- `Sources/decant/main.swift`: command-line entry point.
- `Sources/DecantApp/`: Decant.app (AppKit lifecycle, SwiftUI views). The SwiftPM product is
  `DecantApp`, since `Decant` would clash with `decant` on a case-insensitive disk;
  `Scripts/build.sh` bundles it as `Decant.app`. Install logic belongs in DecantCore, not here.
- `Tests/DecantCoreTests/`: unit tests. `Tests/Integration/build-fixtures.sh` builds disk
  images for end-to-end testing in a VM.
- `Support/Info.plist`: bundle identifier and version, embedded in the binary. This is the only
  place the version is set.
- `Support/App-Info.plist`: Decant.app's Info.plist. The build copies the version in.
- `Support/uk.street365.decant.update.plist` and `Support/scripts/postinstall`: the update
  LaunchDaemon and the package script that loads it. `Sources/DecantCore/Updater.swift` is what it runs.
  `Support/uk.street365.decant.update-service.plist` is the on-demand XPC service
  (`Sources/DecantCore/UpdateService.swift`) behind Check for Updates and `update --latest`.
- `Scripts/build.sh`: builds the binary, Decant.app and the installer packages (`decant-full-<version>.pkg`
  with the app, `decant-cli-<version>.pkg` without).
- `CHANGELOG.md`: release notes. Add a `## <version>` section with each version bump; the release
  workflow publishes it and fails without it.
- `Profiles/`: example configuration profile and App Management (PPPC) profile.
- `site/`: static website for decant.street365.uk (Cloudflare Pages, no build step).

## Commands

```bash
swift build
swift test
Scripts/build.sh   # ad-hoc signed app and packages in .build/dist/
```

The project requires Swift 6.4 and the macOS 27 SDK, targets macOS 26 and later, and builds for arm64 only.

## Conventions

- Run `swift test` before finishing a change. Code that runs only as root (dropping to the target
  user, `--all-users`, `uninstall`) is not covered by unit tests, nor is the app's UI. Say so when a change
  touches them.
- Exit codes and configuration keys are part of the public interface used by MDM scripts. Do not
  renumber or rename them. Document new ones in the README tables, in plain language for admins.
- Security checks fail closed. Do not relax signature, Gatekeeper or policy checks without an
  explicit configuration option.
- Never commit signing material (`.p12`, `.p8`, certificates). Releases are signed only in CI
  by `.github/workflows/release.yml`.
