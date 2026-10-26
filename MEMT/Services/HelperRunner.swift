import Foundation

/// Runs LEModHelper, the bundled command-line tool that performs the install steps that edit game
/// packages (merge mods, LE1 TLK merge, 2DA/Coalesced/PlotManager merges, AutoTOC). It's built from
/// ME3TweaksCore and LegendaryExplorerCore, the libraries ME3Tweaks Mod Manager uses; see Helper/.
nonisolated enum HelperRunner {
    struct HelperError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Result: Decodable {
        let ok: Bool
        let error: String?
        let backedUp: [String?]?
        let values: [String: [String]]?
    }

    /// Location of the helper inside the app bundle (copied from MEMT/Helper by Xcode).
    static var executableURL: URL? {
        Bundle.main.url(forResource: "LEModHelper", withExtension: nil)
    }

    /// Where original base-game files are kept before this app first changes them.
    static func backupDirectory(for game: LEGame, in install: GameInstall) -> URL {
        // Keyed by the install path so different copies of the game don't share backups.
        let key = install.root.standardizedFileURL.path.data(using: .utf8)!.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
        return URL.applicationSupportDirectory
            .appending(path: "LEModManager/Backups/\(key)/\(game.rawValue)", directoryHint: .isDirectory)
    }

    /// Reads config values from a game's base config (entries are "File.ini|Section|Key").
    /// Returns the values found; entries that don't exist in this game are left out.
    @concurrent
    static func readConfig(game: LEGame, gameDirectory: URL, entries: [String]) async throws -> [String: [String]] {
        let result = try await execute("config-read", arguments: [
            "game": game.rawValue,
            "gamedir": gameDirectory.path,
            "entries": entries.joined(separator: ";"),
        ], progress: { _ in })
        return result.values ?? [:]
    }

    /// Runs the helper and returns the game-relative paths of any base-game files it backed up.
    /// `progress` receives the helper's status lines as they arrive.
    @concurrent
    @discardableResult
    static func run(_ command: String, arguments: [String: String], progress: @escaping @Sendable (String) -> Void) async throws -> [String] {
        let result = try await execute(command, arguments: arguments, progress: progress)
        return (result.backedUp ?? []).compactMap(\.self)
    }

    @concurrent
    private static func execute(_ command: String, arguments: [String: String], progress: @escaping @Sendable (String) -> Void) async throws -> Result {
        guard let executableURL else {
            throw HelperError(message: "The install helper is missing from the app. Run Helper/build-helper.sh, then rebuild the app.")
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [command] + arguments.sorted { $0.key < $1.key }.flatMap { ["--\($0.key)", $0.value] }
        // Xcode debug sessions inject libraries via DYLD_* variables; the helper must not inherit them.
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        // Collected from the pipes as data arrives so a chatty helper can't fill a pipe buffer and stall.
        let collector = OutputCollector(progress: progress)
        // Each pipe is read until end-of-file, so the final result line is never lost to a race
        // between the process exiting and the last chunk of output arriving.
        let pipesDone = DispatchGroup()
        pipesDone.enter()
        pipesDone.enter()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                pipesDone.leave()
            } else {
                collector.appendOutput(data)
            }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                pipesDone.leave()
            } else {
                collector.appendErrors(data)
            }
        }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        // Wait (off the main thread) until both pipes have delivered everything.
        await withCheckedContinuation { continuation in
            pipesDone.notify(queue: .global()) { continuation.resume() }
        }

        writeLog(command: command, arguments: process.arguments ?? [], status: status, reason: process.terminationReason, collector: collector)

        // The result is the last line that parses as the helper's JSON result.
        let result = collector.output.split(separator: "\n").reversed().lazy
            .compactMap { try? JSONDecoder().decode(Result.self, from: Data($0.utf8)) }
            .first
        guard let result else {
            let detail = collector.errorTail.isEmpty ? "exit code \(status)" : collector.errorTail
            throw HelperError(message: "The install helper failed (\(detail)).")
        }
        guard result.ok else {
            throw HelperError(message: result.error ?? "The install helper failed.")
        }
        return result
    }

    /// Folder with a log of each helper run (newest kept), for diagnosing install problems.
    static var logsFolder: URL {
        URL.applicationSupportDirectory.appending(path: "LEModManager/Logs", directoryHint: .isDirectory)
    }

    private static func writeLog(command: String, arguments: [String], status: Int32, reason: Process.TerminationReason, collector: OutputCollector) {
        let fm = FileManager.default
        try? fm.createDirectory(at: logsFolder, withIntermediateDirectories: true)
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted).dateTimeSeparator(.standard))
        let file = logsFolder.appending(path: "\(stamp) \(command).log")
        let text = """
        command: \(arguments.joined(separator: " "))
        exit status: \(status) (\(reason == .uncaughtSignal ? "killed by signal" : "exited"))

        ===== stdout =====
        \(collector.output)
        ===== stderr =====
        \(collector.allErrors)
        """
        try? text.write(to: file, atomically: true, encoding: .utf8)
        // Keep the 40 newest logs.
        let logs = ((try? fm.contentsOfDirectory(at: logsFolder, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in logs.dropFirst(40) { try? fm.removeItem(at: old) }
    }

    /// Thread-safe accumulator for the helper's stdout/stderr.
    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private let progress: @Sendable (String) -> Void
        private var outputData = Data()
        private var pendingErrorLine = ""
        private var errorLines: [String] = []

        init(progress: @escaping @Sendable (String) -> Void) {
            self.progress = progress
        }

        var output: String {
            lock.withLock { String(decoding: outputData, as: UTF8.self) }
        }

        private var allErrorData = Data()

        /// Everything the helper wrote to stderr.
        var allErrors: String {
            lock.withLock { String(decoding: allErrorData, as: UTF8.self) }
        }

        /// The last few non-progress stderr lines, for error messages.
        var errorTail: String {
            lock.withLock { errorLines.suffix(3).joined(separator: " ") }
        }

        func appendOutput(_ data: Data) {
            lock.withLock { outputData.append(data) }
        }

        func appendErrors(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.withLock { allErrorData.append(data) }
            let lines: [String] = lock.withLock {
                pendingErrorLine += String(decoding: data, as: UTF8.self)
                var parts = pendingErrorLine.components(separatedBy: "\n")
                pendingErrorLine = parts.removeLast()
                return parts
            }
            for line in lines where !line.isEmpty {
                if line.hasPrefix("PROGRESS: ") {
                    progress(String(line.dropFirst("PROGRESS: ".count)))
                } else if !line.hasPrefix("   at ") {
                    lock.withLock { errorLines.append(line) }
                }
            }
        }
    }
}
