# FM-1 flash chips (research, 2026-11-16)

FM-1s come with one of two 1 MiB SPI NOR flash chips:

| Chip | JEDEC ID | Units |
|---|---|---|
| Puya P25Q80H | `0x856014` | the first FM-1s |
| UCUN UC25HQ80 | `0xB36014` | sold since autumn 2026, mostly AliExpress |

Both use the same commands. The hardware is fine either way; the problem is firmware that checks the ID and only
accepts `0x856014` (common in Felucca-based firmware before late 2026, including its update loader `ldr_flash_known`).

## What happens on a newer-chip FM-1 running a firmware that only knows the old chip

- Saves stay in RAM ("SAVED (RAM)" / "save error") and are lost at power-off.
- Updates started from that firmware fail: Felucca ≤ 1.8.1 "stops after 0 requests" (Felucca #324). Nothing is
  written, but the unit is stuck on that firmware until it is rescued.
- The recovery is download mode (M-Flasher's DOWNLOAD MODE, The Firmware Hub's "send to bootloader", or OCT− + OCT+
  for 5 s on Felucca/SLOOP) and a flash with M-Flasher (Win/Mac/Linux), after a full-flash backup. Then install a
  firmware that knows the new chip. Guide: https://thefirmwarehub.com/tools/rescue/#chip
- Installing again and again doesn't help.

M-VAVE's own firmware (V15/V16) works on both chips.

## What this means for FM-1 Swapper

- **The chip can't be read over USB MIDI** while a firmware runs. Only download mode shows it (M-Flasher). The
  Firmware Hub says so in its installer, so an app can't detect it automatically today.
- **Packages can be classified.** The Firmware Hub reads each package (its `tools/fm1_chip.py`) and publishes the
  result as `chip` in https://thefirmwarehub.com/catalog.json: `new` (knows both chips), `old` (first chip only),
  `any` (doesn't check). As of 2026-11-16: 152 new, 71 old, 5 any. CC-BY-4.0, fetch at most once a day, credit
  The Firmware Hub with a link. A plain byte search for the ID in our packages does not work (the constants aren't
  stored plainly), so use the hub's data, keyed by SHA-256.
- Our updater already stops safely when the running firmware refuses (0 requests, nothing written). The message
  should then point to the chip explanation and the rescue guide, and say not to retry repeatedly.
- The swap flow should warn before installing an `old`-chip package, and more strongly if the user has said their
  FM-1 has the newer chip.

Sources: The Firmware Hub FAQ and rescue page; Felucca README and v1.8.2 release notes; jvitkauskas/m-bootloader
README; SLOOP 2.8.5 notes; isod89/sloop-fm1 `firmware/hal/fm1_flash_id.h`. Mooring for FM-1 advertises chip
detection, but its source isn't public, so how it does it is unknown.

## Checking a unit's chip (M-Flasher)

Confirmed in DECIMA1's video "FM-1 New VS Old Flash Chip" (2026-11-16, youtube.com/watch?v=VNFZqDnTFYs), which walks
through M-Flasher (github.com/jvitkauskas/m-flasher, desktop: Windows/Mac/Linux):

1. Put the FM-1 in download mode. M-Flasher's "How to connect" panel lists: M-VAVE firmware or Felucca running →
   connect and press DOWNLOAD MODE (it sends a MIDI message); FM-1 with m-bootloader → hold REC while switching on;
   Felucca, SLOOP or Snoop37 running → hold OCT− and OCT+; then connect USB with a data cable.
2. Device info then shows model, firmware (e.g. "FM-1 820"), bootloader (e.g. m-bootloader 2.3), **FLASH CHIP**
   (`0x856014 (old) · 1 MiB` on the video's unit) and the chip key, plus a map of the flash.

Lead to check: units with **m-bootloader** may report the chip over MIDI (its README says the recovery menu shows the
chip and that MIDI mode answers read commands). If so, the apps could detect the chip automatically on those units.
Read m-bootloader's source before relying on it.
