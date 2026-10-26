import Foundation

/// Extracts mod archives with macOS's built-in `bsdtar` (libarchive), which reads zip, 7z and rar.
nonisolated enum ArchiveExtractor {
    static let supportedExtensions: Set<String> = ["zip", "7z", "rar"]

    struct ExtractionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Lists the archive (without extracting it) to check whether it's an ME3Tweaks Mod Manager mod.
    @concurrent
    static func containsModdesc(_ archive: URL) async -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/bsdtar")
        process.arguments = ["-t", "-f", archive.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        // Read before waiting so a long listing can't fill the pipe and block bsdtar.
        let listing = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return listing.split(separator: "\n").contains { $0.lowercased().hasSuffix("moddesc.ini") }
    }

    /// Extracts `archive` into a new folder inside `parent` and returns that folder.
    @concurrent
    static func extract(_ archive: URL, into parent: URL) async throws -> URL {
        let destination = parent.appending(path: "Unpack-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        // bsdtar refuses absolute paths and `..` entries by default, so archives can't write outside `destination`.
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/bsdtar")
        process.arguments = ["-x", "-f", archive.path, "-C", destination.path]
        // stderr goes to a file rather than a pipe so a noisy archive can't fill the pipe buffer and stall bsdtar.
        let errorLog = destination.appending(path: ".bsdtar-errors.log")
        FileManager.default.createFile(atPath: errorLog.path, contents: nil)
        let errorHandle = try FileHandle(forWritingTo: errorLog)
        defer { try? errorHandle.close() }
        process.standardError = errorHandle
        process.standardOutput = FileHandle.nullDevice

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }

        guard status == 0 else {
            let output = (try? String(contentsOf: errorLog, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: destination)
            throw ExtractionError(message: "Couldn't extract \(archive.lastPathComponent): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        try? FileManager.default.removeItem(at: errorLog)
        return destination
    }
}
