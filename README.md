# FM-1 Swapper

An iPhone and iPad app for swapping firmware on the M-VAVE FM-1. It keeps a library of firmware packages and backs up each firmware's settings before an install. Afterwards it restores that firmware's own saved settings and logs what you've tried and when. The library syncs between devices through iCloud (SwiftData + CloudKit private database).

## Layout

- `Packages/FM1Kit`: a reusable Swift package for talking to the FM-1 over USB-MIDI SysEx. Use it in future FM-1 apps (editors, librarians, and so on).
  - `FirmwarePackage`: parses `.fwsc` files (identity such as `FM-1_918`, SHA-256, and the "logical image" the device reads) and recognises the stock V15/V16 files by their pinned digests.
  - `OTAUpdater`: the update protocol shared by every FM-1 firmware: handshake, step 1 (the running firmware checks the package and starts the loader), step 2 (the loader writes it), reboot and verify. Also resumes an interrupted write. Ported from Felucca's `tools/fm1_install.py` and `web/fm1ota.js`.
  - `FeluccaArchive`: Felucca's archive protocol (current music, settings, saved music, FM6 banks, samples). It reads and writes Felucca's own backup JSON.
  - `FM1OpenArchive`: FM1 Open's transfer protocol (`app/transfer.c`): the current project, the 8 track timbres, DX7 library groups A–D (exported as standard 32-voice `.syx`), slot names, and the sample bank.
  - `WorkbenchExtractor`: pulls the FM1 Open and original V15 packages out of M-VAVE's Workbench HTML release and checks their digests.
  - `CoreMIDIProvider`: CoreMIDI transport (UMP SysEx7) for iOS and macOS.
- `App/`: the SwiftUI app (Device, Library, History tabs, plus a "Get firmware" browser for the featured firmwares and the community catalog at github.com/2bbb/fm1-firmware-collection).

## Try it (emulator)

Each firmware page, and every package in "Get firmware", has a **Try** button. It plays the package on [fm1-emu](https://github.com/joakimeriksson/fm1-emu) (MIT, Joakim Eriksson), which emulates the FM-1's processor, panel and audio, so firmwares run unchanged. The app opens the hosted page `joakimeriksson.github.io/fm1-emu/?embed=1` in a WKWebView. It runs there rather than compiled into the app because the emulator compiles firmware code to WebAssembly on the fly, and iOS only allows that inside a web view. `App/Views/EmulatorView.swift`:
- hands the package to the page's own "Open .fwsc…" input with a `DataTransfer`. Official packages are named `FM-1.fwsc` so the page treats them as M-VAVE's firmware.
- stands in for Web MIDI, which Safari doesn't have, forwarding every CoreMIDI source via `FM1Kit.MIDIInputMonitor`.
- needs an internet connection to load. Saves made inside the emulator stay in the web view's storage.

Simulator test: `SIMCTL_CHILD_FM1_DEMO_EMULATOR=/path/x.fwsc SIMCTL_CHILD_FM1_DEMO_AUTOSTART=1 xcrun simctl launch <sim> com.example.fm1swapper` (Debug builds only).

## Build

```sh
xcodegen generate            # after editing project.yml
open FM1Swapper.xcodeproj    # pick your iPhone/iPad, Run (team YOURTEAMID, automatic signing)
cd Packages/FM1Kit && swift test
# optional real-file tests:
FM1_TEST_FWSC=felucca-1.8.2.fwsc FM1_TEST_WORKBENCH=FM1-Open-V14-Workbench.html swift test
```

**iCloud sync is currently OFF** (installed 2026-11-15 without it, because Xcode's Apple ID login had expired, so the iCloud container couldn't be provisioned). To turn it on:
1. Sign in again in Xcode → Settings → Accounts.
2. In `project.yml`, set `FM1_CLOUD_SYNC: "YES"` and add `CODE_SIGN_ENTITLEMENTS: App/FM1Swapper-iCloud.entitlements` to the target's settings.
3. `xcodegen generate`, then build with `-allowProvisioningUpdates`. The data already on each device should then upload to CloudKit.

Unsigned or simulator builds have to leave sync off, or CloudKit traps at launch.

## Backups by firmware

| Firmware | Identity | Backup over MIDI |
|---|---|---|
| M-VAVE official V15/V16 | `FM-1_015`, `FM-1_016` | none (no protocol): use notes and attachments |
| FM1 Open | `FM-1_80000xx` | project, timbres, DX7 library, samples |
| Felucca and forks with archive support | `FM-1_9xy` | complete archive |
| Other community firmware | anything else | the app tries Felucca's protocol, otherwise notes and attachments |

## Caveats

- All of this was tested against a simulated FM-1, not real hardware (the real one arrives 2026-11-16). Do the first install with the official V15 file in the library, so you can always go back.
- iOS stops MIDI when the app is in the background. Keep the app open during an install. The app turns off auto-lock while it works.
- M-VAVE marks FM1 Open V14 as not hardware-validated.
