// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import FM1Kit
import Foundation
import SwiftData
import UniformTypeIdentifiers

extension UTType {
    /// A saved SLOOP song as a file (`.fm1song`, JSON): shared by AirDrop, Files or iCloud Drive, and by the web app.
    static let fm1song = UTType(exportedAs: SLOOPSongFile.typeIdentifier, conformingTo: .json)
}

/// Sharing saved SLOOP songs as files and adding the ones that arrive.
enum SongFiles {
    /// The file for a saved song (its current data and its name).
    static func file(_ song: Backup) throws -> (name: String, data: Data) {
        guard let a = song.archive else { throw FM1Error.badPackage("This song can't be read.") }
        return try file(a, name: song.label)
    }

    static func file(_ archive: DeviceArchive, name: String) throws -> (name: String, data: Data) {
        (SLOOPSongFile.fileName(name), try SLOOPSongFile.encode(archive, name: name))
    }

    /// Whether a file looks like a song file (by its extension, or a JSON file that is one).
    static func isSong(_ data: Data, fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if ext == SLOOPSongFile.fileExtension { return true }
        guard ext == "json" else { return false }
        return (try? SLOOPSongFile.decode(data)) != nil
    }

    /// Adds a song file to the saved songs, unless the same song is already there. Returns what to tell the user.
    @MainActor
    static func add(_ data: Data, fileName: String, context: ModelContext) throws -> String {
        let (archive, savedName) = try SLOOPSongFile.decode(data)
        let name = savedName ?? ((fileName as NSString).deletingPathExtension as NSString).deletingPathExtension
        let songs = try context.fetch(FetchDescriptor<Backup>(predicate: #Predicate { $0.kindRaw == "song" }))
        if let twin = songs.first(where: { $0.archive.map { SLOOPSongFile.same($0, archive) } ?? false }) {
            return "“\(twin.label)” is already in Firmware Editor → SLOOP, with the same notes."
        }
        let identity = archive.info["identity"] ?? archive.firmware
        try context.addBackup(archive, label: name, kind: "song", firmware: try context.fetch(FetchDescriptor<Firmware>()).first { $0.product == identity })
        return "Added the song “\(name)” to Firmware Editor → SLOOP."
    }
}
