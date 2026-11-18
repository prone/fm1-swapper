// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import Foundation

/// M-VAVE's FM1 Open Workbench is a single HTML file that carries its firmware packages
/// (FM1 Open itself and the original official V15) as base64 JSON records:
/// {"schema":1, "product":"FM-1_8000014", "release_version":"V14", "sha256":"…", "data":"…"}.
/// This pulls them out and checks each against its own digest.
public enum WorkbenchExtractor {
    public struct Embedded: Sendable {
        public let product: String
        public let releaseVersion: String
        public let profile: String
        public let isStock: Bool
        public let hardwareValidated: Bool?
        public let package: FirmwarePackage
    }

    public static func packages(inHTML data: Data) -> [Embedded] {
        guard let s = String(data: data, encoding: .utf8) else { return [] }
        let pattern = #"\{"schema":1,[^{}]*?"data":"([A-Za-z0-9+/=]+)""#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        var out: [Embedded] = []
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let whole = Range(m.range, in: s), let b64 = Range(m.range(at: 1), in: s) else { continue }
            let header = String(s[whole.lowerBound..<b64.lowerBound])
            func field(_ k: String) -> String? {
                guard let r = header.range(of: "\"\(k)\":\"") else { return nil }
                return header[r.upperBound...].split(separator: "\"", maxSplits: 1).first.map(String.init)
            }
            guard let product = field("product"), let sha = field("sha256"),
                  let bytes = Data(base64Encoded: String(s[b64])),
                  sha256Hex(bytes) == sha,
                  let pkg = try? FirmwarePackage(data: bytes), pkg.product == product else { continue }
            out.append(Embedded(product: product, releaseVersion: field("release_version") ?? "", profile: field("profile") ?? "",
                                isStock: field("kind") == "stock", hardwareValidated: header.contains("\"hardware_validated\":false") ? false
                                    : header.contains("\"hardware_validated\":true") ? true : nil,
                                package: pkg))
        }
        return out
    }
}
