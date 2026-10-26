import Foundation

/// The `_metacmm.txt` marker that ME3Tweaks Mod Manager writes into every Custom DLC folder it installs.
/// Writing the same format keeps mods installed by this app recognizable by M3 on Windows.
///
/// Format: line 1 mod name, line 2 version, line 3 installer build number,
/// followed by `[TAG]value` lines.
nonisolated struct MetaCMM: Sendable, Equatable {
    static let fileName = "_metacmm.txt"

    /// Build number written on line 3. M3 uses its own build number; ours marks the mod as installed by this app.
    static let installerBuild = "0"

    var modName: String
    var version: String
    var installerBuild: String = MetaCMM.installerBuild
    var featureLevel: String?
    var sourceModdesc: String?
    var sourceModdescHash: String?
    var nexusUpdateCode: Int?
    var installTime: Date?
    /// Names of the optional components chosen at install (M3's `[INSTALLOPTIONS]`, `;`-separated).
    var installOptions: [String] = []
    /// Option keys chosen at install time (`[OPTIONKEYS]`), checked by other mods' `optionkey` requirements.
    var optionKeys: [String] = []

    init(modName: String, version: String, featureLevel: String?, sourceModdescHash: String?, nexusUpdateCode: Int?, installTime: Date) {
        self.modName = modName
        self.version = version
        self.featureLevel = featureLevel
        self.sourceModdescHash = sourceModdescHash
        self.nexusUpdateCode = nexusUpdateCode
        self.installTime = installTime
    }

    init?(contentsOf url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // M3 writes Windows line endings; splitting on `.newlines` alone would turn each CRLF into two lines.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let name = lines.first, !name.isEmpty else { return nil }
        modName = name
        version = lines.count > 1 ? lines[1] : ""
        installerBuild = lines.count > 2 ? lines[2] : ""

        for line in lines.dropFirst(3) where line.hasPrefix("[") {
            guard let close = line.firstIndex(of: "]") else { continue }
            let tag = line[line.index(after: line.startIndex)..<close].uppercased()
            let value = String(line[line.index(after: close)...])
            switch tag {
            case "MDFEATURELEVEL": featureLevel = value
            case "SOURCEMODDESC": sourceModdesc = value
            case "SOURCEMODDESCHASH": sourceModdescHash = value
            case "NEXUSUPDATECODE": nexusUpdateCode = Int(value)
            case "INSTALLTIME": installTime = Int64(value).map(Self.date(fromDotNetTicks:))
            case "INSTALLOPTIONS": installOptions = value.split(separator: ";").map(String.init)
            case "OPTIONKEYS": optionKeys = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            default: break
            }
        }
    }

    func write(to url: URL) throws {
        var lines = [modName, version, installerBuild, ""]
        // M3 parses this as a number and fails on an empty value, so only write a real one.
        if let featureLevel, Double(featureLevel) != nil { lines.append("[MDFEATURELEVEL]\(featureLevel)") }
        lines.append("[SOURCEMODDESC]\(sourceModdesc ?? "")")
        if let sourceModdescHash { lines.append("[SOURCEMODDESCHASH]\(sourceModdescHash)") }
        if let nexusUpdateCode { lines.append("[NEXUSUPDATECODE]\(nexusUpdateCode)") }
        if let installTime { lines.append("[INSTALLTIME]\(Self.dotNetTicks(from: installTime))") }
        if !installOptions.isEmpty { lines.append("[INSTALLOPTIONS]\(installOptions.joined(separator: ";"))") }
        if !optionKeys.isEmpty { lines.append("[OPTIONKEYS]\(optionKeys.joined(separator: ";"))") }
        try (lines.joined(separator: "\r\n") + "\r\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // M3 stores install time as .NET DateTime ticks: 100ns intervals since 0001-01-01.
    private static let ticksPerSecond: Double = 10_000_000
    private static let secondsFromYear1To1970: Double = 62_135_596_800

    static func date(fromDotNetTicks ticks: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ticks) / ticksPerSecond - secondsFromYear1To1970)
    }

    static func dotNetTicks(from date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + secondsFromYear1To1970) * ticksPerSecond)
    }
}
