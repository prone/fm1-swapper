// swift-tools-version: 5.9
// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import PackageDescription

// FM1Kit: talk to an M-VAVE FM-1 over USB-MIDI SysEx.
// Firmware packages (.fwsc), the shared update (OTA) protocol, and the
// settings-archive protocols of firmwares that expose one. Reusable by any
// app (the swapper, editors, librarians...).
let package = Package(
    name: "FM1Kit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "FM1Kit", targets: ["FM1Kit"])],
    targets: [
        .target(name: "FM1Kit"),
        .testTarget(name: "FM1KitTests", dependencies: ["FM1Kit"]),
    ]
)
