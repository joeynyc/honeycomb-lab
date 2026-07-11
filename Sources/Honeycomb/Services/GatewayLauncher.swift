import Foundation
import Observation

/// Starts the gateway that ships inside the app bundle, so a downloaded
/// Honeycomb.app works without cloning the repo or touching a terminal.
///
/// The gateway is stdlib-only Python; it needs a `python3` on the machine.
/// macOS provides one with the Command Line Tools — if it's missing we say
/// so plainly instead of failing silently.
@MainActor
@Observable
final class GatewayLauncher {
    private(set) var isStarting = false
    private(set) var lastError: String?

    /// Config lives next to the user's fleet, not inside the app bundle
    /// (bundle contents are read-only and replaced on every update).
    static var configURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Honeycomb", isDirectory: true)
            .appendingPathComponent("gateway-config.json")
    }

    /// The gateway sources bundled into the .app (nil in a `swift run` build,
    /// where the repo copy is used instead).
    static var bundledGatewayDir: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let dir = resources.appendingPathComponent("gateway", isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("server.py").path)
            ? dir
            : nil
    }

    private static func findPython() -> String? {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var canStart: Bool {
        Self.bundledGatewayDir != nil && Self.findPython() != nil
    }

    /// Why we can't start, in words a non-developer can act on.
    var blockedReason: String? {
        if Self.bundledGatewayDir == nil {
            return "gateway not bundled — run it from the repo (gateway/start.sh)"
        }
        if Self.findPython() == nil {
            return "python3 not found — install Xcode Command Line Tools: xcode-select --install"
        }
        return nil
    }

    func start() async {
        guard !isStarting, let dir = Self.bundledGatewayDir, let python = Self.findPython() else {
            lastError = blockedReason
            return
        }
        isStarting = true
        lastError = nil
        defer { isStarting = false }

        // First run: seed a config the user can edit, from the bundled example.
        let config = Self.configURL
        if !FileManager.default.fileExists(atPath: config.path) {
            let example = dir.appendingPathComponent("config.example.json")
            try? FileManager.default.createDirectory(
                at: config.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.copyItem(at: example, to: config)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [dir.appendingPathComponent("server.py").path]
        process.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["HONEYCOMB_GATEWAY_CONFIG"] = config.path
        process.environment = env

        let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/honeycomb-gateway.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            process.standardOutput = handle
            process.standardError = handle
        }

        do {
            try process.run()
        } catch {
            lastError = "could not start gateway: \(error.localizedDescription)"
            return
        }

        // Give it a moment to bind the port; the monitor's next poll confirms.
        try? await Task.sleep(for: .seconds(2))
    }
}
