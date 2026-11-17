# FM-1 hardware facts (measured)

Phase 0 of docs/roadmap-music.md (F3). Measured on a real FM-1 on 2026-11-16, connected to a Mac (macOS) over
USB-C. Firmware: official V15 (identifies as `FM-1_015`). Flash chip: **Puya P25Q80H, JEDEC 0x856014 (the older chip)**,
1 MiB, read through m-bootloader's helper (see below and docs/flash-chips.md).

## USB

- USB device "FM-1", vendor 0x4C4A, product 0xC755, full speed (12 Mb/s).
- One USB-MIDI port pair named **FM-1**. Our port filter (`looksLikeFM1` / `fm1PortPattern`) matches it and the
  identify handshake answers `FM-1_015` (FM1Kit `OTAUpdater.identify`, checked with a read-only probe).

## Official V15

| Question | Answer | How it was checked |
|---|---|---|
| USB audio device? | **Yes**: "FM-1 Audio", 2 ch in + 2 ch out, 44.1 kHz. The synth's sound arrives on the input. | macOS System Information; recorded with ffmpeg |
| Notes out over USB MIDI? | **Yes**: keys send Note On/Off on channel 1. Fixed velocity (on 90, off 100): the keys aren't velocity sensitive. | Listen-only CoreMIDI monitor, 75 s |
| CC out from knobs? | **No**: turning every knob sent nothing. | Same monitor |
| Clock / transport out? | **No**. | Same monitor |
| Follows MIDI clock / Start / Stop in (USB)? | **No** with default settings: the arpeggiator kept its own tempo (0.93 s between notes before, during 60 BPM and 180 BPM clock, and after Stop). | Sent 24 ppq clock; measured note onsets in the USB audio |
| CC7 (volume) in? | **No effect** (output peak unchanged at -32 dB). V15's own CC map (M-VAVE's "MIDI CC Control Parameter Guide") not yet found. | Sent CC7 = 10 then 127 on channel 1 |

Still to check: Bluetooth MIDI latency/jitter, the TRS MIDI input, M-VAVE's CC map, and the same table for Felucca
1.8.2 and SLOOP 2.8.5.

## m-bootloader helper on V15 ("Check this FM-1", levels 0–1)

Run 2026-11-16 with FM1Kit (`OTAUpdater.startHelper`, `MBoot.backup`, `MBoot.restart`), the same calls the app makes:

- V15 accepted `fm1-stage.fwsc` (sha e861ad2e…): 19 read requests in step 1, then the unit came back as
  `ota-FM-1_900` on a port named **FM-1 Update**. Our filter found it and the `MBOOT` probe answered within 6 s.
- `MBOOT` answer: version 2.4, protocol 1, stage, flags 1, chip key 38927, capacity 1,048,576, JEDEC 0x856014.
  The 8-byte flash unique ID is the same as the unit's USB serial number.
- The whole 1 MB flash read in about 19 s, every 64 KB block checked against the chip's CRC-32. The image
  starts with the expected flash header (`0.01` at +4, `AC791N_STORY` at +16).
- `F0 22 24 35 7E F7` restarted it into V15 (`FM-1_015` again within 6 s).

## iPad app on real hardware

2026-11-16, iPadOS 26.1, FM-1 on the iPad's USB-C. Each result confirmed from the app's check-in report:

| Test | Result |
|---|---|
| Install V15 → Felucca v1.8.2 (`FM-1_918`) | OK |
| Felucca archive backup ("Back up now", no samples) | OK, saved |
| "Check this FM-1" on Felucca (the `listed` helper) | OK: showed 0x856014, older unit; restart back to Felucca |
| "Back to official firmware…" (downloaded V15, sha db1642…) | OK, `FM-1_015` |
| V15 → SLOOP 2.8.5 | OK |
| SLOOP → Melodee v1.6.1 **via V15** (two installs in one run) | OK, `FM-1_91061` |
| Melodee → Felucca v1.8.2 with "restore after install" (the earlier Felucca backup) | OK, restored |
| SLOOP 2.8.5: "Clear the song on the FM-1…" on an unsaved song → "Save, then clear" (2026-11-17) | OK: saved as a song, then cleared |

Found: Melodee answers `FM-1_91061` and fm1-amb `FM-1_7010302`, outside the number ranges `DeviceIdentity.family`
knows, so the app calls them unknown. Melodee is Felucca-family (m-bootloader SPEC §11.7), so it isn't offered
"Check this FM-1". To fix: recognise families by more than the number range.

## What this means for the roadmap

- The USB audio recorder (feature 2) works with stock firmware: stereo at 44.1 kHz.
- Tempo sync (feature 1) can't drive stock V15's arpeggiator or sequencer; it's only for firmwares whose profile
  says they follow clock.
- MIDI capture (feature 7) gets notes from stock firmware, but no knob movements.
