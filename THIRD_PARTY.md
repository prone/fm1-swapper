# Third-party material

FM-1 Swapper is licensed under the GNU General Public License v3.0 only (see LICENSE). It builds on the
work below. Apache-2.0 and MIT material is used under those licences, which are compatible with GPL-3.0.

## Felucca — GPL-3.0-only
Copyright (C) 2026 Leo Kuroshita (@kurogedelic), Hügelton Instruments — https://github.com/hugelton/Felucca

The FM-1 update protocol, package (.fwsc) parsing and Felucca archive protocol in FM1Kit are a Swift
port of Felucca's `web/fm1ota.js`, `web/fm1backup.js`, `web/fm1pkg.js` and `tools/fm1_install.py`
(modified). Files: `Packages/FM1Kit/Sources/FM1Kit/OTAUpdater.swift`, `FeluccaArchive.swift`,
`FirmwarePackage.swift`. Because of this the whole project is GPL-3.0-only.

## FM1 Open (M-VAVE) — GPL-3.0-only WITH GPL-3.0-linking-exception
https://github.com/m-vave/fm1_open — `FM1OpenArchive.swift` implements the project transfer protocol
described in its `app/transfer.c`. `WorkbenchExtractor.swift` reads the firmware packages embedded in
M-VAVE's published Workbench release at run time; no M-VAVE firmware is included in this repository.
Official firmware is downloaded by the user from M-VAVE's own servers or GitHub releases.

## smc-pad — Apache-2.0
https://github.com/spectalive/smc-pad — the SMC-PAD light protocol, session unlock and pad colour
addresses in `SMCPad.swift`, and the captured frames in `Packages/FM1Kit/Tests/FM1KitTests/SMCPadTests.swift`
(from `reference/gatt_unlock.txt`). Its NOTICE file:

```
smc-pad
Copyright 2026 Cristian Deluxe

This repository is licensed under the Apache License, Version 2.0 (see
LICENSE), with one exception:

reference/mac-decompile/ is NOT covered by that licence. Those files are a
machine disassembly (Blutter) of M-VAVE's MidiSuite application, kept only as
the evidence the protocol notes in reference/FINDINGS.md and docs/ were
derived from. The code they describe belongs to its owner, M-VAVE; no rights
to it are granted here. Everything else in reference/ (captures, decoders,
notes) was written or recorded for this project and is under Apache-2.0.
```

Nothing from `reference/mac-decompile/` is included here.

## open-smc-pad — MIT
https://github.com/fedepaj/open-smc-pad — the SINCO service protocol notes (`docs/sinco-protocol.md`) used in `SMCPad.swift`.

```
MIT License

Copyright (c) 2026 Federico Paglioni and the open-smc-pad contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## fm1-emu — MIT
https://github.com/joakimeriksson/fm1-emu — the "Try it" emulator. The app loads its hosted page at run time
(it is not bundled); `web/public/emu-bridge.js` (shared by the iOS and web apps) contains the FM-1 panel geometry
from its `crates/fm1-live/src/panel.rs`. The web app serves a copy of fm1-emu's published build from its own
origin: `web/tools/fetch-emu.mjs` downloads it at build time into `web/public/emu/` (not committed), together
with its LICENSE.

```
MIT License

Copyright (c) 2026 Joakim Eriksson

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Community firmware catalog
https://github.com/2bbb/fm1-firmware-collection — the app downloads its catalog JSON at run time.

## Tutorials
`Tutorials/*.json` are original summaries written for this project (GPL-3.0-only like the rest), each
listing the documentation it was drawn from in `sources`. Each firmware remains under its own licence.

## Trademarks
Not affiliated with or endorsed by M-VAVE. M-VAVE, FM-1 and SMC-PAD are trademarks of their owners;
other product and firmware names belong to their authors.

## The Firmware Hub firmware list — CC BY 4.0
https://thefirmwarehub.com/catalog.json — both apps read it (at most once a day) for each firmware's package
checksum, flash chip support, kind and links. Firmware list: The Firmware Hub – https://thefirmwarehub.com,
licensed CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). Card texts and pictures belong to each
firmware's maker, who is named and linked in the apps.
