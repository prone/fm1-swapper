---
description: Research an FM-1 firmware online and draft its emulator tutorial (Tutorials/<id>.json)
argument-hint: <firmware name, GitHub repo (owner/name) or library entry>
---

Draft an interactive tutorial for the FM-1 firmware **$ARGUMENTS**, to be played over the
fm1-emu emulator in the FM-1 Swapper app. The emulator runs the real firmware, so every step
must describe what the firmware actually does on the FM-1's panel.

## 1. Research (cite everything)

- Find the firmware's own documentation: the GitHub README, wiki, docs/ folder, manual (PDF),
  release notes and changelog. For community firmware, the repo is listed in
  https://raw.githubusercontent.com/2bbb/fm1-firmware-collection/main/catalog/firmwares.json.
  M-VAVE's own firmware: the FM-1 user manual and m-vave.com.
- Prefer the author's docs over blog posts and videos. Note the firmware version the docs
  describe. If the docs and the latest release disagree, follow the release and say so.
- Write down which control does what: the FM-1 panel is MASTER, SELECT, PRESETS, ALGORITHM,
  KNOB1-4, OCT-/OCT+, FX SCL ENV LFO EDIT GLO, HOME SAVE ARP SEQ PLAY REC, and keys F3-G5.
  Firmwares rename controls on screen; map their names back to these panel names.
- Never invent a control combination. If the docs don't say how to reach a feature, leave the
  feature out, or give a step with no `show` and say what the docs say.

## 2. Plan the tour (8-16 steps)

Start with orientation (screen, how to play, how to get home). Then cover the firmware's main
features in the order a new user needs them: sound selection, the main sound parameters, effects,
sequencer or arpeggiator, saving. End with where to learn more. Keep each step to one idea and
roughly 300 characters of text.

For each step choose:
- `highlight`: the controls the step talks about (`SCREEN` and `KEYS` highlight areas).
- `show`: a demo the app can play. It can press buttons, play notes C4-F5, and turn every
  encoder and knob. Keep demos short (under about 5 s) and leave the synth in a sensible state.
- `await`: one "Your turn" action for steps where trying it helps (about every second step).

## 3. Write the file

Write `Tutorials/<id>.json` in the exact format of `Tutorials/README.md` (read it first; use only
the control names and actions listed there). Use `"reviewed": false` and
`"author": "Claude Code draft <today's date>"`. List every page you used in `sources`. `match`
it narrowly: the repo for community firmware, `productPrefixes` / `families` for M-VAVE's.

## 4. Check

- `python3 tools/validate_tutorials.py Tutorials/<id>.json` must pass. Fix every error, and fix
  warnings where possible.
- If the firmware package is at hand, run `tools/tutorial-check.sh <id> <package.fwsc>` and look
  at each step's screenshot. Do the highlights sit on the right controls? Does each demo leave
  the screen showing what the text says? Fix the steps that don't.
- Report: the steps, the sources, anything the docs left unclear, and whether the emulator check
  ran. Do not set `reviewed` to true: a maintainer does that after trying it.
