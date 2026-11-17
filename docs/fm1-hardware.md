# FM-1 hardware facts (measured)

Phase 0 of docs/roadmap-music.md (F3). Measured on a real FM-1 on 2026-11-16, connected to a Mac (macOS) over
USB-C. Firmware: official V15 (identifies as `FM-1_015`). Flash chip: not yet read (see docs/flash-chips.md).

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

## What this means for the roadmap

- The USB audio recorder (feature 2) works with stock firmware: stereo at 44.1 kHz.
- Tempo sync (feature 1) can't drive stock V15's arpeggiator or sequencer; it's only for firmwares whose profile
  says they follow clock.
- MIDI capture (feature 7) gets notes from stock firmware, but no knob movements.
