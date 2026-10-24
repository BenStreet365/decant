# Security model

How decant protects the Mac while it runs as root. For what this means day to day, see
[Things to know](../README.md#things-to-know) in the README.

## Installing an app

- The image is attached with `diskutil image attach --readOnly --nobrowse --noMount`, and each volume is then mounted with `diskutil mount readOnly nobrowse -mountOptions nosuid,nodev` in a private (`0700`) folder with a random name. decant checks that each volume really is mounted there read-only, `nosuid` and `nodev`; otherwise the image is refused. Nothing can prompt: decant reads encryption from `hdiutil isencrypted` and licence agreements from the image's own trailer before attaching, and only answers a licence prompt when `AcceptLicenseAgreements` allows it.
- If the image is already open somewhere else (for example the user opened it in Finder), decant refuses it (exit 20) rather than use or eject that copy. Images that an earlier decant left mounted in its own temporary folder, because it was killed, are ejected first. Installs hold the install lock while mounting, so such a mount can't belong to a run that is still going.
- The image is mounted, so the kernel parses its file system, before the app's signature can be checked. That's why the Intune script uses HTTPS and requires a Team ID.
- Before the signature is checked, the app's `Info.plist` is read without following any symlink inside the bundle, only if it is a regular file of at most 4 MB, so a FIFO or a link to `/dev/zero` or a root-only file can't hang the install or make root read outside the image. Names, bundle IDs and versions with control characters are refused (exit 21).
- After the signature is checked, the bundle ID and version are read again from the staged copy, whose `Info.plist` the signature seals, and only those are used.
- The app is copied to a **root-owned staging directory** on the destination volume. All verification (signature, Team ID, Gatekeeper) runs on that staged copy, so what is verified is exactly what gets installed. Every folder above the staging directory must be root-owned and not writable by others; otherwise (possible when the home folder is on another volume) the install fails with exit 50.
- Team IDs are only trusted when an Apple-issued leaf certificate carries them, or Apple signed the app itself.
- As root, decant first checks that nobody but root can replace it: its binary and every folder above it (following symlinks) must be root-owned and not writable by group or others, except a sticky folder or one writable only by the `wheel` or `admin` group. Otherwise it exits 1 without doing anything, because the update daemon runs it as root every hour. This happens if `/usr/local/bin` belongs to a user, as old Homebrew installs left it; the package's postinstall script warns about it.
- `~/Applications` and any existing app are inspected with `lstat`, and symlinks are refused.
- When running as root, the existing app's contents (`Info.plist`, signature) are read by a helper process that has switched to the user (the same binary, with the hidden `_inspect-bundle` command). It has a 5-minute limit. A booby-trapped bundle, such as a FIFO in place of `Info.plist` or a symlink to a root-only file, can't hang the install or reveal anything to the user.
- The final move uses `renameatx_np` (`RENAME_SWAP` / `RENAME_EXCL`) through a directory fd opened with `O_NOFOLLOW`. A user cannot redirect root's write elsewhere by swapping in symlinks.
- File permissions:
  - The copy drops the vendor's ACLs (`ditto --noacl`).
  - The bundle is `chown -R -h` to the user and made owner-writable, so in-app updaters keep working.
  - Nothing is left group- or world-writable, and setuid/setgid bits are removed (`chmod -R u+rwX,go-w,ug-s`). File modes aren't part of the code signature, so this doesn't invalidate it.
  - If `~/Applications` is root-owned or not owner-writable, for example because an older tool created it, it is handed back to the user. This goes through an `O_NOFOLLOW` descriptor.
- The previous copy goes into staging when it is swapped out. It is then moved back next to the new copy under a hidden name and deleted by a helper running as the user (`_remove`). Root never deletes a folder the user controls, which would allow the classic `rm -rf` symlink race.
- A real different app is never overwritten (exit 42).
- Installs are serialised with a lock file. A run that can't get the lock within 30 minutes exits 43 rather than waiting forever.

## Configuration profiles

Settings are read from `/Library/Managed Preferences/uk.street365.decant.plist` (device profile) and
`/Library/Managed Preferences/<user>/uk.street365.decant.plist` (user profile). A file is only trusted if it is root-owned and not group/world-writable. Root may also pass
`--config file.plist` for testing. Non-root users may not, so they cannot switch off the signature or
Gatekeeper checks. `AllowUserOption` is ignored, with a warning, in a user profile, because
`--user` loads the named user's profile.

## Running without root

Non-root use isn't blocked by default. A user who runs `decant install` themselves can only install
into their own `~/Applications`, which they could do with Finder anyway, and every check still
applies. `--user` for another account, `--all-users` and `--config` stay root-only.

Set `AllowUserInstalls` to `false` to block it: `install` without root, dry runs included, then
fails with exit 10 and "Installing apps with Decant has been disabled by your administrator".
Root is unaffected, so an MDM script running as root still installs for the console user.
Read-only commands (`check-app`, `show-config`, `update --check`, `version`) keep working. Users
with admin rights can still run decant with `sudo`, and anyone can still copy apps with Finder.

## Logging

Everything is logged to `/Library/Logs/decant.log` when run as root (otherwise
`~/Library/Logs/decant.log`, or `LogFilePath`) and to the unified log (subsystem `uk.street365.decant`). The log file is
kept under 10 MB: when it grows past that, the oldest lines are dropped and the newest 5 MB kept.
It must be a regular file with one link, owned by the account decant runs as; otherwise, for
example a symlink or a hard link to another file, file logging is skipped. Control characters in
messages (such as a newline in an app's name) are written as escapes like `\n`, in the log and on
the `RESULT` line, so a disk image cannot add lines of its own.

## Updates to decant

Before installing a new version of itself, `decant update` checks that the package:

- matches the `.sha256` published with it,
- is signed with a Developer ID Installer certificate from the same team as the running `decant`,
- is accepted by Gatekeeper as notarized, and
- contains the version its release is tagged with.

Users can ask for the newest release now (Check for Updates in Decant.app, or `decant update
--latest` without root). The request goes over XPC to `uk.street365.decant.update-service`, a
LaunchDaemon that launchd starts as root on demand. Any local process can send one, so it carries
nothing the service acts on: the service only installs the newest GitHub release, with every
check above, and skips just the user's own deferral and the idle wait. A profile's
`AutomaticUpdates` set to `false` or `UpdateDeferralDays` still applies. It handles one request at
a time, asks GitHub at most once a minute however often it is asked, and exits after a minute
without requests.

A copy of decant that is not Developer ID signed (a local build) never updates itself, and with
Gatekeeper disabled nothing is installed. Downgrades never happen, even if an old package is
published under a newer tag. GitHub is queried with a conditional request at most once a day,
and drafts and pre-releases are ignored.
