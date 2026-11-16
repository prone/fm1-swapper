# Contributing

Thanks for helping. A few things keep the project easy to work on:

- **Build and test** before sending a change: `xcodegen generate`, build the app, `cd Packages/FM1Kit && swift test`,
  and `python3 tools/validate_tutorials.py` if you touched `Tutorials/`.
- **Licence.** Contributions are under GPL-3.0-only. New source files start with
  `// SPDX-License-Identifier: GPL-3.0-only` and a copyright line. Credit any third-party code or protocol notes in
  `THIRD_PARTY.md`, and only bring in material whose licence is GPL-3.0-compatible. Never add firmware binaries or
  decompiled vendor code.
- **Device protocols** are reverse-engineered: link the source of every protocol fact in a comment, keep parsers
  bounds-checked, and validate anything from a file or device before it is written to a device.
- **Tutorials** are data. They are drafted (often by Claude Code with `.claude/commands/draft-tutorial.md`), every
  step is run in the emulator with `tools/tutorial-check.sh`, and a maintainer tries them before setting
  `"reviewed": true`. Each tutorial lists its sources.
- **Hardware testing.** Say which device, firmware version and transport (USB / Bluetooth) you tested on.
