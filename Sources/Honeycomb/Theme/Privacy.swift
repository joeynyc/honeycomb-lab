import Foundation
import SwiftUI

/// Privacy mode — redacts anything that identifies *your* network when the
/// map is on a projector, in a screenshot, or in a demo video. Health,
/// models, and metrics stay visible; addresses and machine names don't.
enum Privacy {
    @MainActor static var enabled: Bool {
        UserDefaults.standard.bool(forKey: "privacyMode")
    }

    /// Redact an IP address / hostname / SSH alias.
    @MainActor static func host(_ value: String) -> String {
        enabled ? "•••" : value
    }

    /// Redact any addresses embedded in a longer string (URLs, detail lines).
    @MainActor static func scrub(_ text: String) -> String {
        guard enabled else { return text }
        var out = text
        // IPv4 literals
        out = out.replacingOccurrences(
            of: #"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"#,
            with: "•••.•••.•••.•••",
            options: .regularExpression
        )
        // Hostnames inside URLs (http://name:port → http://•••:port)
        out = out.replacingOccurrences(
            of: #"(https?://)[^/:\s]+"#,
            with: "$1•••",
            options: .regularExpression
        )
        // Tailnet / DNS names
        out = out.replacingOccurrences(
            of: #"\b[\w-]+(\.[\w-]+)*\.(ts\.net|local|lan|internal)\b"#,
            with: "•••",
            options: .regularExpression
        )
        return out
    }
}
