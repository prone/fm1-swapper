# Roadmap: music production features (planned 2026-11-16)

Firmware swapping, backups, the emulator, tutorials, SMC-PAD and the slice sampler exist. This plan covers using the
FM-1 with other equipment and for making music. Every feature lands in the iOS app; the web app gets what browsers
allow (marked per feature).

What the FM-1 offers, which shapes everything below:

- **Stock:** USB-C MIDI (class compliant), Bluetooth MIDI, a 3.5 mm MIDI input (no MIDI out jack), audio out.
  V15 added CC control. **Not yet confirmed:** whether stock firmware sends audio over USB, follows MIDI clock or
  sends CC. Check on the real unit first (phase 0).
- **Community firmware** varies a lot: clock in over USB/TRS (Melodee, MAKU, Mini-Tone, Quadro…), MIDI out per track
  (Tessera, Morpheus), USB audio in stereo or multichannel (Kitten Synths 8 ch, SIDJ per voice, Melodee, Masif),
  MIDI learn, DX7 banks (sloopDX, SLOOP DX7 banks, Saadet). So most features read a **capability profile** of the
  installed firmware (F2) instead of guessing.

## Foundations (built first, used by everything)

### F1. MIDI hub
One owner for every MIDI port in each app, replacing today's SMC-PAD-specific routing (`ControllerRouter`,
`ControllerHub`) with a general one that keeps SMC-PAD as one source.
- Ports: FM-1 (USB/Bluetooth), SMC-PAD, other controllers, other apps (iOS virtual ports "FM-1 Swapper In/Out";
  web: whatever Web MIDI lists), the emulator.
- A routing graph: source → filter (channel, message type) → transform (channel remap, transpose) → destination.
  Clock and transport travel as their own messages.
- Timestamped sends: CoreMIDI timestamps on iOS, `MIDIOutput.send(data, timestamp)` on web, so clock doesn't depend
  on UI-thread timing.
- Never touches a port while an install or backup runs (the device lock that `DeviceController` already has).
- iOS: FM1Kit `MIDIHub` + tests with virtual ports. Web: `web/src/midi/hub.ts` + tests with fake ports.

### F2. Firmware capability profiles
`Profiles/<id>.json`, one per firmware, shared by both apps like `Tutorials/`. Matched like tutorials: SHA-256, repo,
identity prefix, family. Drafted by Claude Code from each firmware's docs (a `/draft-profile` command like
`/draft-tutorial`), checked on hardware or in the emulator, then marked `"reviewed": true`.

```json
{
  "format": 1, "id": "melodee", "match": { "repos": ["keremimo/melodee"] },
  "clock": { "in": ["usb", "trs"], "out": [] }, "transport": { "in": true },
  "midiOut": { "tracks": [] }, "midiIn": { "channels": "1-4 per track" },
  "usbAudio": { "out": 4, "in": 2 },
  "controls": [ { "name": "Cutoff", "cc": 74, "track": 1, "group": "Filter" } ],
  "dx7Banks": false, "screenMirror": false,
  "sources": ["https://…"], "reviewed": false
}
```

Unknown fields mean "not known", never "no". The Firmware Hub's list fills in kind and links; profiles add the
music-making facts. Validator: `tools/validate_profiles.py` (like the tutorials').

### F3. Phase 0: hardware facts (tomorrow, with the real FM-1)
Before anything is built, record in `Profiles/mvave-official.json` and `docs/fm1-hardware.md`:
1. Does stock V15/V16 appear as a USB audio device (in/out, channel count, sample rate)?
2. Does it follow MIDI clock / start / stop (USB, Bluetooth, TRS)? Does the arpeggiator or sequencer sync?
3. Does it send anything back: CC on knob moves, notes from keys, clock?
4. Bluetooth MIDI latency and jitter compared to USB (send a clock, look at the arp).
5. The same checks on Felucca 1.8.2 and SLOOP 2.8.5.

## Features

Sizes: S = a session, M = 2–3 sessions, L = a week or more. Platforms: iOS / Web.

### 1. Tempo sync hub (M) · iOS ✓ / Web ✓ (no Link)
- The app becomes the clock: tempo, tap tempo, start/stop/continue, swing for the sequencer of firmwares that take
  it, a clear count-in. Sends MIDI clock (24 ppq) and transport to the FM-1 and to any other destination in F1.
- Or follows: incoming MIDI clock from a DAW or another device, passed on to the FM-1 (for firmwares that only take
  clock on one port).
- **Ableton Link on iOS** (LinkKit, GPL-2.0+, compatible with our GPL-3.0): join a Link session (Ableton Live, Loopy
  Pro, Koala, AUM, other phones) and drive the FM-1's clock from it, with start/stop sync. Browsers can't join Link
  (no UDP multicast), so the web app does internal or follow-a-DAW clock only.
- Keeps running in the background on iOS (the app already has the audio background mode).
- Warn when the destination is Bluetooth: clock over BLE is often too jittery; prefer USB.
- SMC-PAD lights pulse on the beat (we already drive its lights).
- Tests: clock timing on virtual ports (jitter under 1 ms on iOS); Link with LinkKit's test peers.

### 2. USB audio recorder (L) · iOS ✓ / Web partial
Depends on phase 0 (stock) and profiles (per firmware channel counts).
- Record the FM-1's USB audio: the master, or separate tracks for multichannel firmware, named from the profile
  (Kitten Synths: 6 tracks + master).
- Record in time: start with the clock from feature 1, count-in, bar-length loops, and an optional punch-in.
- Takes list with waveforms; trim, normalise; export WAV stems (with tempo in the file name and an iXML/BWF tempo
  chunk) to Files, AirDrop or other apps; "send to sampler" puts a take straight into a kit.
- Monitor through the iPhone/iPad output with low latency, or not at all (the FM-1 has its own output).
- iOS: AVAudioEngine with the USB device's full channel count, recording to disk off the audio thread (as the
  sampler's recorder does). Web: `getUserMedia` with `channelCount`; Chrome often gives stereo only, so the web
  version records master/stereo and says so.

### 3. Control screen per firmware + automatic pad layouts (M) · iOS ✓ / Web ✓
- A **Control** tab built from the installed firmware's profile: knobs, faders and buttons grouped as the firmware
  groups them, sending its CCs (and NRPN where profiles say). Big touch targets; landscape on iPad.
- Values are remembered per firmware and can be stored as **snapshots** and recalled (send all CCs).
- If the firmware sends CC back, the controls follow it.
- **Automatic SMC-PAD layout:** a pad profile can be linked to a firmware; when that firmware is detected (identity
  on connect or after a swap), its layout loads. Profiles can propose a default layout (pads to notes or drum keys,
  encoders to its main CCs).
- MIDI learn on the control screen for firmwares without a profile.

### 4. MIDI router (M) · iOS ✓ / Web ✓
The user-facing side of F1.
- A routing page: every source and destination as a row, connections as toggles, per route a channel filter or
  remap and transpose. Presets ("Pad → FM-1 + Loopy", "Bluetooth keyboard → FM-1", "DAW → both FM-1s").
- **Two FM-1s:** pick channel blocks per unit (as Mini-Tone does), or one unit per port, and play both from one
  controller or DAW track.
- **Bluetooth ↔ USB bridge:** a Bluetooth keyboard or another phone reaches a USB FM-1 through the iPhone/iPad.
- MIDI monitor (a message log per port) for troubleshooting.
- iOS also publishes virtual ports so other apps (AUM, Loopy Pro, Cubasis) can send to or receive from the FM-1
  through the router.

### 5. DX7 patch librarian (M) · iOS ✓ / Web ✓
- Import 32-voice DX7 banks (`.syx`) from Files or URLs the user chooses; show voice names and the main
  parameters; search across all banks; favourites; build a bank from voices of several banks.
- Audition a voice in the emulator before sending (fm1-emu notes DX7 SysEx import works with V15).
- Send a bank or a single voice to firmware that takes DX7 data (stock V14+, sloopDX, SLOOP DX7 banks, Saadet, FM1
  Open's DX7 library); the profile says how.
- **Stock preset backup:** read all 128 presets of the official firmware with Program Change + SysEx, as FM-1
  Manager (MIT-licensed browser app) does, and store them as a backup of the official firmware, so our swap can save
  and restore stock patches too. This closes the "official firmware can't be backed up" gap.
- No patch archives bundled (their copyright is unclear); link to the well-known ones and let users import.

### 6. Setlists (S–M) · iOS ✓ / Web ✓
Built from features we have plus 1 and 3.
- A setlist is a list of songs; a song is: firmware, a saved backup or project to restore, tempo and swing, a pad
  layout, a control snapshot, notes and lyrics/cues.
- **Ready this song:** one tap swaps firmware if needed (with the V15 route and backups), restores the project,
  sets the clock and the pad layout, and sends the snapshot. Shows "ready" only after each step is confirmed.
- Next/previous song from the SMC-PAD or a foot controller (via the router).
- Rehearsal timer and per-song notes; export a setlist as a file to share with a bandmate.

### 7. MIDI capture to .mid (S) · iOS ✓ / Web ✓
- Record what a firmware sends (Tessera: every track on its own channel; Morpheus: four channels) plus the user's
  controller input, aligned to the app clock (feature 1).
- Export standard MIDI files (one track per channel, tempo map) to a DAW; or play a `.mid` back into the FM-1
  through the router.
- Pairs with the recorder: a take can have audio stems and MIDI together.

### 8a. Screen mirroring (M, firmware-dependent) · iOS ✓ / Web ✓
- Show the FM-1's screen large on iPad, a TV (AirPlay) or a stream, for teaching, live visuals and accessibility.
- Needs firmware support: SLOOP has an MIT-licensed mirroring addition offered in its issues; Felucca has an open
  idea. We'd define a small SysEx framebuffer stream, help land it upstream, and add it to profiles.
- Also a path to the screen-reader requests in Felucca and SLOOP: with the screen's text available, VoiceOver can
  read it.

### 8b. The emulator as an iPad instrument plugin (L) · iOS only
- An AUv3 instrument (and a standalone "Play" mode) running FM-1 firmware, usable in AUM, Loopy Pro, Cubasis,
  GarageBand, recording into a DAW with the real firmware's sound.
- The WebKit emulator can't run inside an audio plugin. fm1-emu's Rust core (`fm1-live`, MIT; it already ships
  VST3/AU/CLAP) would be compiled for iOS and wrapped as an AUv3. fm1-emu has an open AUv3 request, so this should be
  done with its author, not as a private fork.

### 9. FM1 Live: emulated and hardware FM-1s playing together (L) · iOS ✓ / Web ✓ (desktop best)
A feature area of its own (its own tab): sync several emulated FM-1s and one or more hardware FM-1s to one clock, and
trigger changes in any of them while playing the hardware live. (Not to be confused with `fm1-live`, the name of
fm1-emu's Rust emulator core, which this may later run on; see 8b.)
The idea (2026-11-16): find a pattern or song on the hardware, send it to the iPad, and run it in an emulated
FM-1, then do that several times. Five emulators with different firmware and patterns play together, the hardware
FM-1 stays live, and app **macros** change the emulators in time. Like owning several FM-1s.

- **Capture from hardware → emulator.** "Send to FM1 Live" takes a backup of what the FM-1 is running (the archive
  protocols we already have: Felucca family, FM1 Open; not stock) and loads it into a new FM1 Live slot running the same
  firmware package. The reverse, "send this slot to the FM-1", is a restore.
  - Finding (fm1-emu, checked 2026-11-16): the emulator takes MIDI in, including SysEx and clock (`fm1_midi` per
    byte), but has **no MIDI out** from the emulated firmware. The restore protocol needs the firmware's replies,
    so the clean route is an upstream change: expose the firmware's USB MIDI out from the worklet. That matches an
    open fm1-emu request ("Expose emulated firmware MIDI OUT to DAW hosts") and is also needed by feature 7. Propose
    it to fm1-emu's author with a patch.
  - Fallbacks: a timed "blind" restore without acknowledgements (fragile, test only), or writing the archive into
    the emulator's flash snapshot (it already saves/loads whole flash images), which needs each firmware's flash
    layout (per family).
- **Hardware units are slots too.** Each connected FM-1 (USB, through a hub, or Bluetooth) appears as a hardware
  slot next to the emulated ones: it gets the clock, mutes (by note filtering or its volume CC), macros (MIDI only:
  notes, CC, program changes; panel presses work only on emulated slots) and "send to/from" (capture or restore).
  Several FM-1s report the same identity, so slots are told apart by port and a name the user gives each unit
  ("left FM-1"). An iPhone has one USB port, so more than one wired FM-1 needs a hub (fine for playing; installs
  still go direct).
- **Slots and sets.** N slots, each with firmware, state, MIDI channel and its own route from F1 (SMC-PAD to slot 2, a
  keyboard to slot 4). A mixer per slot (level, pan, mute, solo) and a master to the device output. Each slot's
  flash is saved with the set, and a set can be saved and loaded.
- **One clock for everything.** The app clock (feature 1) drives every slot and the hardware FM-1, so patterns stay
  locked. The hardware plays through its own output, so record with latency compensation (feature 2).
- **Macros and scenes.** Buttons, or SMC-PAD pads, that run a list of actions on chosen slots, quantised to the next
  beat, bar or 4 bars: send notes/CC/program changes, press panel controls (the tutorial engine's `__fm1do` already
  drives buttons, knobs and keys), mute/unmute slots, change tempo. **Scenes** store mute/level states and switch
  together. Setlists (6) can recall a set.
- **Performance limits.** Each emulator is a full CPU emulation. On iPad one instance showed about 18% load at
  100 MHz; all emulators in one page share one audio thread, so 3 to 5 slots is the likely limit on iPad and fewer
  on iPhone (to be measured in the spike). Desktop Chrome handles more. The native engine from 8b (fm1-emu's Rust
  core) would run slots far more cheaply, so FM1 Live should be built so that engine can replace the web view later.
- **Spike first (S):** (1) run 2–5 emulators in one web view on iPad and iPhone and measure load and glitches;
  (2) confirm emulated Felucca/SLOOP follow MIDI clock; (3) prototype the MIDI-out hook in fm1-emu locally and a
  hardware → emulator restore of one Felucca project.

### Emulator performance review (with fm1-emu's author)
A code review of fm1-emu (MIT, github.com/joakimeriksson/fm1-emu) for performance, before FM1 Live needs several
emulators at once. Improvements go upstream as contributions, not a private fork.

Known so far (2026-11-16, from the copy we ship):
- "load 18%" on the iPad is busy time on the emulator's audio thread: about 18% of **one** core (roughly 2% of
  an iPad Pro), the inverse of "5.7x real time".
- It already has a WebAssembly JIT (hot blocks compiled to small modules, crates/fm1-core/src/jit_wasm.rs + jit.js)
  and skips the firmware's idle time (fm1_soc skip_idle), so lowering the emulated clock barely helps.
- All emulators in one page share one AudioContext render thread, so N instances add up on one core: the main
  limit for FM1 Live.

To look at: JIT coverage and whether WebKit (iOS) runs the JIT as well as Chrome (measure jit stats, compile time,
fallbacks); per-quantum overhead and buffer size; one audio thread per emulator (separate contexts, frames or
web views) or several machines in one worklet with shared work; LCD/LED frame traffic to the page; SIMD in the
audio path; and the native Rust core (`fm1-live`) on iOS with one thread per instance. Method: a repeatable
benchmark (Chrome, WebKit/iPad web view, native) with 1, 3 and 5 instances of Felucca, SLOOP and stock.

## Order

| Step | What | Why then |
|---|---|---|
| 0 | Hardware facts (F3) | Decides what's possible on stock and how 2 and 3 behave |
| 1 | F1 MIDI hub + F2 profiles (first 5: official, Felucca, SLOOP, FM1 Open, Melodee) | Everything depends on them |
| 2 | 1 Tempo sync (internal + follow), then Link | Biggest everyday win |
| 3 | 3 Control screen + automatic pad layouts | Quick with profiles and existing pad code |
| 4 | 4 MIDI router (UI on F1), two-FM-1 mode, monitor | Unlocks DAW and multi-device setups |
| 5 | 2 USB audio recorder | Needs phase 0 and profiles; largest |
| 6 | 5 DX7 librarian + stock preset backup | Also improves swapping |
| 7 | 6 Setlists | Combines 1, 3, swap and backups |
| 8 | 7 MIDI capture | Small once 1 and 4 exist |
| 9 | 8a Screen mirroring (with firmware authors) | Depends on upstream work |
| 10 | 8b AUv3 emulator (with fm1-emu's author) | Largest; separate track |
| — | Emulator performance review (with fm1-emu's author) | Before FM1 Live; any time after the hardware checks |
| 11 | 9 FM1 Live (last): spike, then emulated + hardware slots on one clock, capture (after the fm1-emu MIDI-out change), macros and scenes | The finale: builds on 1, 2, 4, 6, and on 8b's native engine for more slots |

Profiles keep growing in the background (a few firmwares per session with `/draft-profile`).

## Testing

- Virtual FM-1 (FM1Kit tests and web tests) extended: follows clock (counts ticks, checks start/stop), sends CC and
  notes back, and a fake multichannel audio source for the recorder.
- Timing tests for the clock on both platforms; Link tests with LinkKit's test peers.
- Hardware checklist per feature on the real FM-1 and SMC-PAD before each feature is called done.
- Profiles are validated like tutorials, and each one is marked reviewed only after a hardware or emulator check.

## Open questions

- Stock USB audio and clock behaviour (phase 0).
- Which firmwares send MIDI out over USB in practice (profiles will tell).
- Whether the iOS app's tab bar has room: likely a **Play** tab (Control, Clock, Record, Setlists) and router/monitor
  under Pads, rather than five new tabs.
- Web multichannel recording support in Chrome on each OS.
