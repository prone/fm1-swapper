# FM-1 Swapper

An iPhone and iPad app for the M-VAVE FM-1 pocket synth and its many community firmwares:

- **Swap firmware** over a USB cable: back up the current firmware's work, install the new one, then restore that firmware's own saved settings. Interrupted installs can be resumed.
- **Library and history**: every firmware you've downloaded, with a description, your notes, rating and try status, and a log of what you installed when.
- **Get firmware**: the featured firmwares, M-VAVE's official releases, and the community catalog (github.com/2bbb/fm1-firmware-collection), sortable by stars.
- **Try it**: play any firmware in the [fm1-emu](https://github.com/joakimeriksson/fm1-emu) emulator before installing it, with saves, restore and reset.
- **Tutorials**: guided tours of a firmware over the emulator: spotlights, "Show me" demos and "Your turn" steps.
- **SMC-PAD and SMC-PAD Pocket**: play the FM-1 or the emulator from the pads, with layouts per model and per firmware, Learn, pad lights, and Bluetooth pairing.
- **Slice sampler**: import or record a sample, slice it at its hits, and play the slices from the pads.
- **Check-ins** (optional): your installs can see which firmware each one has, through a small server on your Mac.

Not affiliated with or endorsed by M-VAVE. M-VAVE, FM-1 and SMC-PAD are trademarks of their owners. Installing firmware is at your own risk; keep a copy of M-VAVE's official firmware so you can always go back.

## Layout

- `Packages/FM1Kit` — a reusable Swift package (iOS and macOS) for talking to the FM-1 and SMC-PAD:
  - `FirmwarePackage`: `.fwsc` parsing (identity such as `FM-1_918`, SHA-256, the image the device reads); recognises the official V15/V16 files by digest.
  - `OTAUpdater`: the update protocol shared by every FM-1 firmware (handshake, verify, write, reboot, resume). Swift port of Felucca's installer.
  - `FeluccaArchive`, `FM1OpenArchive`, `DeviceArchive`: backup and restore for the firmwares that expose their data over MIDI; imported backups are fully validated before anything is written.
  - `WorkbenchExtractor`: reads the FM1 Open and original V15 packages from M-VAVE's Workbench release.
  - `Controller` (`ControllerModel`, `ControllerMapping`, `MappingEngine`, `ControllerRouter`): pad/knob mapping and routing; `SMCPad`: the SMC-PAD service protocol (identity, light session over Bluetooth or USB).
  - `SliceDetector`: transient and equal slicing, waveform peaks. `SysExCoding`, `MIDITransport`: codecs and the CoreMIDI transport.
- `App/` — the SwiftUI app: Device, Library, Pads, Sampler and History tabs; SwiftData models.
- `Tutorials/` — tutorial data (JSON), format in `Tutorials/README.md`.
- `tools/` — `checkin_server.py` (+ `install-checkin-agent.sh`), `validate_tutorials.py`, `tutorial-check.sh`.
- `.claude/commands/draft-tutorial.md` — how tutorials are drafted with Claude Code from a firmware's docs (they are then checked in the emulator and reviewed).

## Build

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate                 # after editing project.yml
cp Config/Local.example.xcconfig Config/Local.xcconfig   # your Team ID and bundle id prefix (git-ignored)
open FM1Swapper.xcodeproj
cd Packages/FM1Kit && swift test
python3 tools/validate_tutorials.py
```

Optional real-file tests: `FM1_TEST_FWSC=felucca-1.8.2.fwsc FM1_TEST_WORKBENCH=FM1-Open-V14-Workbench.html swift test`.

**iCloud sync** is off by default (`FM1_CLOUD_SYNC: "NO"` in project.yml). To turn it on, set it to `YES`, add `CODE_SIGN_ENTITLEMENTS: App/FM1Swapper-iCloud.entitlements` with your own container id, and build with `-allowProvisioningUpdates`.

**Simulator testing** (Debug builds only): `SIMCTL_CHILD_FM1_DEMO_EMULATOR=/path/x.fwsc` opens the emulator on launch; `FM1_DEMO_AUTOSTART`, `FM1_DEMO_TUTORIAL=<id>`, `FM1_DEMO_TAB`, `FM1_DEMO_SAMPLE`, `FM1_DEMO_PADS` drive the other test paths. `tools/tutorial-check.sh <id> <package.fwsc>` plays a tutorial in the simulator and screenshots every step.

## How the pieces work

**Emulator.** The app loads fm1-emu's hosted page (`joakimeriksson.github.io/fm1-emu/?embed=1`) in a WKWebView — the emulator compiles firmware code to WebAssembly on the fly, which iOS only allows in a web view. A small injected bridge hands the page the package through its own "Open .fwsc…" input, stands in for Web MIDI (forwarding CoreMIDI), drives its save/import/reset controls, and draws tutorial spotlights. Navigation is restricted to the emulator page; it needs an internet connection.

**SMC-PAD.** Defaults are the stock layout measured on a full-size pad (pads notes 36–51 on channel 10, encoders CC 30–37, edge buttons CC 25–29; PAD BANK B = notes 52–67). The pad's lights don't follow MIDI: the app opens the pad's own light session (as M-VAVE's MIDI Suite does) after checking the device identifies as an SMC-PAD, and writes colours into preset 1. The Pocket's layout and lights are unconfirmed.

**Check-ins.** Optional and off by default in release builds. When on, each install reports its FM-1 firmware and library to `tools/checkin_server.py` on your Mac (found over Bonjour, same Wi-Fi) and shows your other installs. Each install's first report registers a private key so no other device can overwrite it; reports are validated and `checkins/SUMMARY.md` shows them as inert data. Run it at login with `tools/install-checkin-agent.sh` (`--remove` to undo).

**Permissions** the app asks for: Bluetooth (SMC-PAD pairing and lights), microphone (recording samples), local network (check-ins), and background audio (the pads keep playing the sampler when you switch apps).

## Licence and credits

GPL-3.0-only (see `LICENSE`). FM1Kit contains a Swift port of parts of [Felucca](https://github.com/hugelton/Felucca) (GPL-3.0-only), so the whole project is GPL-3.0-only. Other credits — FM1 Open, smc-pad (Apache-2.0), open-smc-pad and fm1-emu (MIT), the community catalog — are in `THIRD_PARTY.md`. No firmware binaries are included; official firmware is downloaded from M-VAVE.

See `CONTRIBUTING.md` and `SECURITY.md`.
