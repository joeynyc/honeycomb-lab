import Foundation

/// Shared subprocess runner: hard timeout with SIGKILL, stdout drained
/// concurrently, stderr discarded — a child can never block on a full pipe
/// and no thread ever parks in waitUntilExit.
enum Subprocess {
    struct Result: Sendable {
        var status: Int32
        var output: String
    }

    /// mergeStderr: some CLIs (lms link status) write human output to stderr
    /// when not attached to a TTY — merge both streams into one pipe so
    /// parsing sees it either way.
    static func run(
        _ path: String,
        _ args: [String],
        timeout: TimeInterval,
        mergeStderr: Bool = false
    ) async -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = mergeStderr ? out : FileHandle.nullDevice

        let exitStream = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in
                continuation.yield(())
                continuation.finish()
            }
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        // Drain stdout off the exit-wait path.
        let reader = Task.detached(priority: .utility) {
            (try? out.fileHandleForReading.readToEnd()) ?? Data()
        }

        let exited = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in exitStream { break }
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return false
            }
            let first = await group.next() ?? false
            if !first {
                kill(process.processIdentifier, SIGKILL)
            }
            group.cancelAll()
            return first
        }

        let data = await reader.value
        guard exited else { return nil }
        return Result(
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? ""
        )
    }
}

/// Subprocess probes are expensive (a fork per call) and their answers change
/// slowly — cache per command line and collapse concurrent callers.
actor SubprocessCache {
    static let shared = SubprocessCache()
    private var entries: [String: (Date, Subprocess.Result?)] = [:]
    private var inFlight: [String: Task<Subprocess.Result?, Never>] = [:]

    func value(
        key: String,
        ttl: TimeInterval,
        compute: @Sendable @escaping () async -> Subprocess.Result?
    ) async -> Subprocess.Result? {
        if let (stamp, cached) = entries[key], Date().timeIntervalSince(stamp) < ttl {
            return cached
        }
        if let running = inFlight[key] {
            return await running.value
        }
        let task = Task { await compute() }
        inFlight[key] = task
        let result = await task.value
        entries[key] = (Date(), result)
        inFlight[key] = nil
        return result
    }
}
