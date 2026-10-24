# Development

The project requires Swift 6.4 and the macOS 27 SDK, targets macOS 26 and later, and builds for
arm64 only.

## Build

```bash
Scripts/build.sh                       # ad-hoc signed
Scripts/build.sh --sign "Developer ID Application: …" --pkg-sign "Developer ID Installer: …"
Scripts/build.sh --sign "…" --pkg-sign "…" --notarize <notarytool-keychain-profile>
swift test                             # unit tests
```

The build produces `.build/dist/decant` (arm64 only; Intel Macs are not supported),
`.build/dist/Decant.app` and two packages:

- `.build/dist/decant-full-<version>.pkg` installs the tool to `/usr/local/bin/decant`, the app to
  `/Applications/Decant.app` and the update daemon to
  `/Library/LaunchDaemons/uk.street365.decant.update.plist`, with the on-demand update service
  `uk.street365.decant.update-service.plist` beside it (see [Updates to decant](../README.md#updates-to-decant)).
- `.build/dist/decant-cli-<version>.pkg` installs the tool and the update daemon, without the app.

Both have the package identifier `uk.street365.decant`.
`--notarize` submits the signed packages with `notarytool` and staples them. MDMs install packages
without Gatekeeper, so this is optional, but a notarized package can also be opened by hand.

The bundle identifier `uk.street365.decant` and the version live in `Support/Info.plist`.
`Support/App-Info.plist` is the app's Info.plist (bundle identifier `uk.street365.decant.app`);
the build copies the version into it.
That file is embedded in the binary's `__TEXT,__info_plist` section and is also used as the
code-signing identifier, the package identifier and the managed preferences domain.

Releases are built, signed, notarized and published by GitHub Actions when a `v<version>` tag is
pushed.

## Testing

`swift test` runs the unit tests: configuration trust and precedence, the app's managed settings, uninstall's per-user clean-up, update release selection and deferral, package signature parsing, layout
classification, version ordering, how existing copies are judged, and real installs (without root)
into a temporary home folder. The root-only paths, where helpers drop to the user,
`--all-users` and `uninstall` run, need the VM tests. `Tests/Integration/build-fixtures.sh` builds the disk images used
for end-to-end testing in a VM:

- signed v1/v2 apps
- unsigned and tampered apps
- pkg, installer, multi-app and extra-folder layouts
- a bundle-ID conflict
- an encrypted image
- a notarized Developer ID app copied from the host

The test apps are ad-hoc signed. To install them, use a `--config` file with
`AllowAdHocSignatures` set to true and `RequireGatekeeperAssessment` set to false.
As root, decant refuses to run from a folder a user owns, so install the package (or copy the
binary to a root-owned folder) rather than running `sudo .build/debug/decant`.

To test updates without GitHub, root can run `decant update --feed <folder>/releases.json`,
where `releases.json` is in the format of GitHub's
[releases API](https://docs.github.com/en/rest/releases/releases#list-releases) and each
`browser_download_url` is a `file://` URL of a `decant-full-<version>.pkg`, `decant-cli-<version>.pkg`
or their `.sha256` in that folder. Add `--allow-unsigned` to install an ad-hoc build. The deferral, idle and checksum checks
still apply. The outcome is saved to `Update.json`, but the test releases are not. The daemon never passes these options.

That last fixture uses `/Applications/Caffeine.app` from the build machine. Swap in another
notarized app if you don't have it.

## Website

`site/` is the static site for [decant.street365.uk](https://decant.street365.uk), hosted on Cloudflare
Pages. Connect the repository with no build command and `site` as the output directory, then
add `decant.street365.uk` as a custom domain. If `street365.uk` is a Cloudflare zone, the
`CNAME` record is created for you. Otherwise point a `CNAME` for `decant` at the project's
`pages.dev` address. `site/_headers` sets the security headers. To preview locally, run
`python3 -m http.server --directory site`.
