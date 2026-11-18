# Audio import prototypes (Python)

These are the Python prototypes behind **Import from audio**. They were used to design and check the analysis before it
was ported to TypeScript, and to compare ideas by ear. The app doesn't use them; the shipped code is in
`web/src/audio/` (`analysis.ts`, `loops.ts`), which the web app and the iOS app's hidden analysis page share.

No audio is included. Use recordings you have the rights to; everything runs locally and writes its output where you
point it.

## Setup

Python 3.12. Use two virtual environments, because Demucs pins its own PyTorch:

```sh
python3.12 -m venv ~/venvs/fm1-audio && ~/venvs/fm1-audio/bin/pip install librosa soundfile scipy basic-pitch
python3.12 -m venv ~/venvs/fm1-demucs && ~/venvs/fm1-demucs/bin/pip install demucs soundfile scipy   # stems only
```

Run the scripts with `python -I` (isolated mode), and pass audio paths as arguments.

## `analysis/`: one 4-bar section

| Script | What it does |
|---|---|
| `a2s.py` | The reference analysis: beats (librosa, tempo checked against half and double), a 16th grid per section slid onto the attacks, drums (kick, snare, hats from band rises), bar 1 from the kicks and snares. `analysis.ts` follows it. |
| `drumtest.py`, `drumtest_75.py`, `drumtest_128.py` | Synthetic drum parts with known hits at 92, 75 and 128 BPM: `python -I drumtest.py outdir` writes `drumtest.wav` and the truth as JSON. |
| `test_a2s.py`, `score.py` | Scores the drums found against that truth: precision, recall and F1 per lane. |
| `transcribe.py` | Basic Pitch on a whole song, giving its notes as JSON. |
| `arrange3.py`, `render.py` | Notes and drums arranged into sections, and the sections rendered as audio to compare by ear. |
| `real2.py` | Prints the drum grids of sections of a real song. |

## `loops/`: the song's own loops

`loops.py` is what `loops.ts` was ported from:
- **Describe each bar:** drum attacks per 16th, and bass and chord pitch classes per beat.
- **Find pattern lengths:** each part's length (1, 2 or 4 bars).
- **Find the phrases:** the 4-bar phrases, grouped into the song's distinct loops.
- **Refine each loop (`refine`):** give it its own start, keep it off the bars where a new sound comes in, and choose the full-volume repeat to take it from.
- **Build the parts (`consensus`):** the loop's drums, taken from all its repeats.

| Script | What it does |
|---|---|
| `sampler.py` | Builds the **loop sampler** page: pads that play each loop on repeat, switching at the next bar line, with a live timer. Usage: `python -I sampler.py analysis/ out.html song1.mp3 "Name 1" song2.mp3 "Name 2" …`. The audio is embedded in the page, so keep it to yourself. |
| `sampler_from.py` | The same page, built from the app's own loops (from `web/src/audio/loops.songs.test.ts` with `LOOP_DUMP`). |
| `timbre.py` | Finds where a new sound comes in (`entries`: two or more tonal bands jumping at the same beat), plus tone-colour change points. |
| `bounds.py` | Section boundaries: where the bars before differ from the bars after. |
| `render_loops.py` | Listening files: each loop twice in a row (to check the join), then its drums from all repeats. |
| `inspect_loops.py`, `onset_of_change.py`, `period_secs.py`, `entries_check.py` | Diagnostics: how well each loop's join scores at each start, where a change starts to the beat, the repeat length in seconds, and the entries found. |
| `compare_feats.py`, `compare_drums.py` | Check the TypeScript port against this prototype bar by bar, using features dumped by `loops.songs.test.ts`. |

To run the app's loop finder on your own songs: decode them to 22050 Hz mono WAV (on macOS:
`afconvert -f WAVE -d LEI16@22050 -c 1 song.mp3 song.wav`), then
`LOOP_WAVS=folder [LOOP_DUMP=folder] npx vitest run src/audio/loops.songs.test.ts` in `web/`.

## `stems/`: separating the instruments first (Demucs)

This is a test of whether separating a song into drums, bass, other and vocals (Demucs, MIT licence) improves the
import. Only the pieces being imported are separated, each with a second either side. On a Mac's GPU that takes about
3 seconds a song.

| Script | What it does |
|---|---|
| `sep.py` | Separates a file, or the `start:end` pieces of it, into 22050 Hz mono stems. Run it in the Demucs environment. |
| `score_stems.py`, `stemdrums.py` | Drums from the mix against drums from the drum stem, scored on the synthetic tests. `stemdrums.drums2` gives each hit to the band that dominates it. |
| `bass_test.py` | The bassline from the mix (the lowest note per step, below C3) against Basic Pitch on the bass stem: scored on the synthetic tests, compared on real songs, plus listening files. |
| `real_grid.py`, `real_compare.py`, `ab.py`, `abmono.py`, `ab_sounds.py` | The same comparison on real songs, with A/B listening files. They're mono and play in sequence (the original, then what was found, then both together), not split left and right. |

Findings so far (2026-11-17):
- **Bass:** the bass stem was clearly better on the synthetic tests (F1 0.84–1.00, against 0.60–0.76 from the mix).
- **Drums:** detection on the drum stem needs its own tuning before it beats the mix.
- **Loops:** finding the loops (the repetition) mattered more than either.
