# SLOOP user samples (research for "Send to SLOOP on FM-1")

Collected 2026-11-15 from SLOOP 2.8.5 docs; not yet verified against a device.

- **Tools today:** SLOOP's web editor (Samples and Drum kit pages; Chrome/Edge, Web MIDI + SysEx over USB) and
  `tools/fm1_sample_upload.py` (load / erase / info / build) in github.com/isod89/sloop-fm1.
  Docs: GUIDE.md §23 "Your own samples and drum kits", SLOOP.md "Your own samples (USR1–USR4)", web/EDITOR_PROTOCOL.md.
- **Transport:** SysEx `F0 7D 46 4C <cmd> <args> F7` (the Felucca protocol family FM1Kit already speaks), one request
  at a time, a reply to each; flash commands answer rc 3 while the song plays (stop first).
  - 11 SMP_BEGIN slot (erases the header sector)
  - 12 SMP_WRITE slot, offset (3 × 7-bit, LSB first; ≥ 512, multiple of 256, increasing), ≤ 256 bytes mask-packed
  - 13 SMP_END slot, 480-byte header mask-packed (rc 1 size, 2 header, 3 data CRC, 4 flash, 5 zones)
  - 14 SMP_ERASE slot (~1 s), 15 SMP_INFO (slot count, slot KiB, each slot's zones, name, KiB)
  - Slot indices 0..3. Backups read slots as archive objects 32..35 (FeluccaArchive already handles those ids).
- **Slot format:** 512-byte header area: magic "FSMP", u16 version 1, u8 zones (1–16), 8-char ASCII name, u32 data
  length, u32 zlib CRC-32 of the data, then 16 zones × 28 bytes (offset, sample count, loop start, loop end,
  rate = Hz/44100×65536, root note, ADPCM state at loop start, lo/hi note, loop mode 0 one-shot / 1 loop / 2 loop+tail).
  Audio from byte 512: IMA ADPCM 4-bit, low nibble first, from predictor 0 / step index 0, mono 22050 Hz, little endian.
  Reference encoder: tools/sampleio.py (`user_slot`), web port checked by web/test_web.mjs.
- **Sizes:** 80 KiB per slot (~7.4 s), USR1 0xA0000, USR2 0xB4000, USR3 0xC8000, USR4 0xE7000; USR3+4 = one ~15 s kit.
- **Doc slips:** README says three user slots and EDITOR_PROTOCOL.md says SMP_BEGIN slot 0..2; firmware has 4 (0..3).
- **Detection:** SLOOP reports identity FM-1_900 — the same as clipper-fm1 — so gate on the archive INFO version
  string (FeluccaArchive.supportsArchive) rather than the identity.
