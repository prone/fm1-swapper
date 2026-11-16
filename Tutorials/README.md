# Firmware tutorials

One JSON file per firmware tutorial. The app ships every `*.json` in this folder and plays it
over the FM-1 emulator (fm1-emu runs the real firmware, so steps behave as on the hardware).
Adding a tutorial needs no app code. Files are drafted by Claude Code (`/draft-tutorial`), then
checked in the emulator before `"reviewed": true` is set.

```json
{
  "format": 1,
  "id": "felucca",
  "title": "Felucca: a guided tour",
  "summary": "One or two sentences on what the tutorial covers.",
  "firmwareVersion": "1.8.2",
  "match": { "repos": ["hugelton/Felucca"], "names": ["Felucca"] },
  "sources": ["https://github.com/hugelton/Felucca/wiki/Controls"],
  "reviewed": false,
  "author": "Claude Code draft 2026-11-15",
  "setup": [ { "press": "HOME" } ],
  "steps": [
    {
      "title": "Pick an engine",
      "text": "Hold HOME and turn SELECT to choose one of the engines…",
      "highlight": ["HOME", "SELECT", "SCREEN"],
      "show": [ { "hold": "HOME" }, { "turn": "SELECT", "clicks": 2 }, { "release": "HOME" } ],
      "await": { "turn": "SELECT", "hint": "Turn SELECT to hear another engine" }
    }
  ]
}
```

## Controls (the FM-1 panel as fm1-emu draws it)

| Name | What |
|---|---|
| `SCREEN` | the display (highlight only) |
| `KEYS` | the whole keyboard (highlight only) |
| `MASTER` | volume pot, top left |
| `SELECT`, `PRESETS`, `ALGORITHM` | the three large encoders, top left |
| `KNOB1` … `KNOB4` | the four knobs, top right |
| `OCT-`, `OCT+` | octave buttons under the encoders |
| `FX` `SCL` `ENV` `LFO` `EDIT` `GLO` | top row of buttons, right |
| `HOME` `SAVE` `ARP` `SEQ` `PLAY` `REC` | bottom row of buttons, right |
| `C4`, `F#3`, `Bb4` … | a note key; the panel has F3 to G5 (MIDI 53–79) |

There is no SHIFT button on the FM-1. Firmwares use HOME, the buttons or held keys as modifiers.

## Actions (`setup` runs once at the start; `show` runs on "Show me")

| Action | Meaning |
|---|---|
| `{ "press": "PLAY", "ms": 160 }` | press and release (ms held, default 160) |
| `{ "hold": "HOME" }` / `{ "release": "HOME" }` | hold until released |
| `{ "turn": "KNOB1", "clicks": 3 }` | turn an encoder or knob; negative = anticlockwise |
| `{ "note": "C4", "ms": 400 }` | play a note |
| `{ "wait": 500 }` | pause, in ms |

Limits of the app's driving: buttons and notes C4–F5 only are pressable (the page's keyboard
shortcuts); every encoder, knob and MASTER can be turned. Notes outside C4–F5 can be highlighted
and awaited but not played by `show`.

## Await (a "Your turn" step)

| Await | Done when |
|---|---|
| `{ "press": ["PLAY"] }` | the user presses PLAY |
| `{ "press": ["SEQ", "C4"] }` | C4 is pressed while SEQ is held (last item completes it) |
| `{ "turn": "KNOB2" }` | the user turns KNOB2 |
| `{ "anyNote": true }` | any note (panel, keyboard, or a MIDI controller) |

Add `"hint"` to override the text shown. Next becomes Skip until the await is done.

## Matching a tutorial to a firmware

`match` fields, most specific first: `sha256` (an exact package), `repos` (GitHub owner/name),
`productPrefixes` (identity, e.g. `"FM-1_015"`), `families` (`official`, `fm1Open`, `felucca`),
`names` (substring of the library name). Do not use the `felucca` family for Felucca itself:
many forks report Felucca-style identities and would get the wrong tutorial.

Validate with `python3 tools/validate_tutorials.py`.
