import Foundation
import CryptoKit

/// Minimal INI reader matching how moddesc.ini files are written: case-insensitive section and key names,
/// full-line `;`/`#` comments only (values themselves contain `;`-separated lists).
nonisolated struct IniFile: Sendable {
    private(set) var sections: [String: [String: String]] = [:]
    /// Entries per (lowercased) section with the key's original case, in file order.
    private(set) var entries: [String: [(key: String, value: String)]] = [:]

    init(text: String) {
        var current = ""
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                current = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased()
                if sections[current] == nil { sections[current] = [:] }
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            sections[current, default: [:]][key] = value
            entries[current, default: []].append((String(line[..<equals].trimmingCharacters(in: .whitespaces)), value))
        }
    }

    func value(_ section: String, _ key: String) -> String? {
        guard let value = sections[section.lowercased()]?[key.lowercased()], !value.isEmpty else { return nil }
        return value
    }

    func hasSection(_ section: String) -> Bool {
        !(sections[section.lowercased()]?.isEmpty ?? true)
    }
}

/// One Custom DLC folder a mod installs: `sourcedirs[i]` in the mod → `BioGame/DLC/destdirs[i]`.
nonisolated struct CustomDLCJob: Sendable, Hashable {
    let sourceURL: URL
    /// The source folder as written in moddesc.ini (relative to the mod root, `/` separators).
    let sourcePath: String
    let destinationName: String
}

/// A `[BASEGAME]` file replacement: a file in the mod copied to a path relative to the game folder (`Game/MEx`).
nonisolated struct BasegameFile: Sendable, Hashable {
    let sourceURL: URL
    let gameRelativePath: String
}

/// An ASI mod a mod asks for: an ME3Tweaks ASI update group, optionally pinned to a version.
nonisolated struct ASIModRequest: Sendable, Hashable {
    let groupID: Int
    let version: Int?

    /// Argument format for `LEModHelper install-asi --asimods` (`group:version`, 0 = latest).
    var helperArgument: String { "\(groupID):\(version ?? 0)" }
}

/// A mod found in an archive or folder, described by its moddesc.ini.
nonisolated struct ModPackage: Identifiable, Sendable {
    let id = UUID()
    let rootURL: URL
    let name: String
    let developer: String
    let version: String
    let description: String
    let website: URL?
    let game: LEGame?
    let gameValue: String
    /// `game = LELAUNCHER`: the mod changes the Legendary Edition launcher (Game/Launcher), not a game.
    /// `game` is then the game the mod belongs with, so it's listed (and restored) with that game.
    let targetsLauncher: Bool
    /// `[LELAUNCHER]` files, with paths relative to Game/Launcher (always under `Content/`).
    let launcherFiles: [BasegameFile]
    let featureLevel: String
    /// `cmmver` as M3 normalizes it (ModDescTargetVersion): 1.0 when missing, rounded to one decimal.
    let featureLevelValue: Double
    /// The version M3 records in `_metacmm.txt` (ModVersionString): integer versions get ".0".
    let metaVersion: String
    /// `[CUSTOMDLC] DLC_X = Friendly Name` entries (exact folder-name case), used as each folder's mod name.
    let customDLCNames: [String: String]
    let nexusCode: Int?
    let moddescHash: String
    let jobs: [CustomDLCJob]
    /// `[BASEGAME]` newfiles/replacefiles: files copied over the game's own files (originals are backed up).
    let basegameFiles: [BasegameFile]
    /// `[BASEGAME] mergemods`: .m3m files in the mod's MergeMods folder, applied by LEModHelper.
    let mergeMods: [String]
    /// `[GAME1_EMBEDDED_TLK] usesfeature=true` (LE1): game text merged in by LEModHelper.
    let usesTLKMerge: Bool
    /// `[ASIMODS] asimodstoinstall`: ASI mods (by ME3Tweaks update group) installed by LEModHelper.
    let asiMods: [ASIModRequest]
    /// Optional components the user can choose (or that apply automatically).
    let options: [ModOption]
    /// `multilistN` entries per header, referenced by multilist options.
    let multilists: [ModOption.Header: [Int: [String]]]

    /// Whether the user has anything to choose when installing.
    var hasChoices: Bool { options.contains { $0.isManual && !$0.hidden } }

    struct ParseError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    /// Folders the mod says replace older versions of itself; removed on install.
    let outdatedDLC: [String]
    /// `requireddlc` entries that must all be met.
    let requiredDLC: [DLCRequirement]
    /// `requireddlc` entries prefixed with `?`: at least one of them must be met (moddesc 6.2+).
    let optionalRequiredDLC: [DLCRequirement]
    let incompatibleDLC: [String]
    /// Issues the user should know about but that don't prevent installation.
    let warnings: [String]
    /// Issues that make the mod impossible to install correctly with this app.
    let blockingIssues: [String]

    var canInstall: Bool {
        blockingIssues.isEmpty && game != nil
            && (!jobs.isEmpty || !basegameFiles.isEmpty || !launcherFiles.isEmpty || !mergeMods.isEmpty || usesTLKMerge || !asiMods.isEmpty
                || options.contains { $0.operation == "OP_ADD_CUSTOMDLC" })
    }

    /// Whether installing this mod edits the game's own files, which are backed up first.
    var modifiesBasegame: Bool { !basegameFiles.isEmpty || !launcherFiles.isEmpty || !mergeMods.isEmpty || usesTLKMerge }

    /// Headers for install steps this app doesn't implement. Skipping them would leave a mod half-installed,
    /// so mods that use them are refused rather than installed partially.
    private static let unsupportedHeaders: [(header: String, feature: String)] = [
        ("TEXTURES", "texture installation"),
        ("HEADMORPHS", "headmorphs"),
    ]

    init(moddescURL: URL) throws {
        let data = try Data(contentsOf: moddescURL)
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let ini = IniFile(text: text.replacingOccurrences(of: "\u{FEFF}", with: ""))
        let root = moddescURL.deletingLastPathComponent()

        rootURL = root
        moddescHash = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        name = ini.value("ModInfo", "modname") ?? root.lastPathComponent
        developer = ini.value("ModInfo", "moddev") ?? "Unknown"
        version = ini.value("ModInfo", "modver") ?? ""
        description = (ini.value("ModInfo", "moddesc") ?? "")
            .replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
        website = ini.value("ModInfo", "modsite").flatMap(URL.init(string:))
        gameValue = ini.value("ModInfo", "game") ?? ""
        targetsLauncher = gameValue.uppercased() == "LELAUNCHER"
        var launcherFiles: [BasegameFile] = []
        var launcherIssue: String?
        if targetsLauncher {
            // Like M3: every file in the moddir goes to the same path under Game/Launcher/Content.
            if let dir = ini.value("LELAUNCHER", "moddir").map({ $0.replacingOccurrences(of: "\\", with: "/") }),
               let sourceDir = PathResolver.resolve(dir, in: root), PathResolver.isDirectory(sourceDir) {
                for file in Self.files(in: sourceDir) {
                    if Self.launcherExtensions.contains((file.relativePath as NSString).pathExtension.lowercased()) {
                        launcherFiles.append(BasegameFile(sourceURL: file.url, gameRelativePath: "Content/" + file.relativePath))
                    } else {
                        launcherIssue = "The launcher file \"\(file.relativePath)\" isn't a type the launcher uses."
                    }
                }
            } else {
                launcherIssue = "The mod's LELAUNCHER folder is missing from the download."
            }
            game = Self.launcherHomeGame(name: ini.value("ModInfo", "modname") ?? "", files: launcherFiles)
        } else {
            game = LEGame(moddescValue: gameValue)
        }
        featureLevel = ini.value("ModManager", "cmmver") ?? ""
        let fl = Self.normalizedFeatureLevel(featureLevel)
        featureLevelValue = fl
        // M3 (Mod-Parsing.cs): an integer modver such as "2" is treated as "2.0".
        metaVersion = Int(version) != nil ? version + ".0" : version
        nexusCode = ini.value("ModInfo", "nexuscode").flatMap { Int($0) }

        let warnings: [String] = []
        var blocking: [String] = launcherIssue.map { [$0] } ?? []

        if game == nil {
            blocking.append(gameValue.isEmpty
                ? "moddesc.ini doesn't say which game this mod is for."
                : "This mod is for \(gameValue), not Mass Effect Legendary Edition.")
        }
        for (header, feature) in Self.unsupportedHeaders where ini.hasSection(header) {
            blocking.append("Uses \(feature) ([\(header)]), which this app can't install yet.")
        }

        // Base game jobs: file replacements (newfiles/replacefiles), additions (addfiles/addfilestargets)
        // and merge mods, following Mod-Parsing.cs and ModJob.AddFileToInstall / AddAdditionalFileToInstall.
        // Keys of `basegameMap` are lowercased destinations (M3's FilesToInstall is case-insensitive).
        var basegameMap: [String: BasegameFile] = [:]
        var basegameOrder: [String] = []
        func mapBasegame(_ destination: String, _ sourceURL: URL) {
            let key = destination.lowercased()
            if basegameMap[key] == nil { basegameOrder.append(key) }
            basegameMap[key] = BasegameFile(sourceURL: sourceURL, gameRelativePath: destination)
        }
        let basegameModDir = ini.value("BASEGAME", "moddir").map { dir -> String in
            var path = dir.replacingOccurrences(of: "\\", with: "/")
            while path.hasPrefix("/") { path.removeFirst() }
            return path
        }
        let newFiles = Self.list(ini.value("BASEGAME", "newfiles"))
        let replaceFiles = Self.list(ini.value("BASEGAME", "replacefiles"))
        let addFiles = fl >= 4.1 ? Self.list(ini.value("BASEGAME", "addfiles")) : []
        let addFilesTargets = fl >= 4.1 ? Self.list(ini.value("BASEGAME", "addfilestargets")) : []
        let gameDirectoryStructure = fl >= 6.0 && ini.value("BASEGAME", "gamedirectorystructure")?.lowercased() == "true"
        let modDirURL = basegameModDir.flatMap { PathResolver.resolve($0, in: root) }
        if newFiles.count != replaceFiles.count {
            blocking.append("[BASEGAME] has \(newFiles.count) newfiles but \(replaceFiles.count) replacefiles.")
        } else if !gameDirectoryStructure && addFiles.count != addFilesTargets.count {
            blocking.append("[BASEGAME] has \(addFiles.count) addfiles but \(addFilesTargets.count) addfilestargets.")
        } else if !newFiles.isEmpty || (!gameDirectoryStructure && !addFiles.isEmpty) {
            if let modDir = modDirURL, PathResolver.isDirectory(modDir) {
                if gameDirectoryStructure {
                    // newfiles/replacefiles name folders: every game file inside each newfiles folder goes to
                    // the same relative path under the matching replacefiles folder.
                    for (source, destination) in zip(newFiles, replaceFiles) {
                        var target = destination
                        while target.hasSuffix("/") { target.removeLast() }
                        guard let sourceDir = source == "." ? modDir : PathResolver.resolve(source, in: modDir), PathResolver.isDirectory(sourceDir) else {
                            blocking.append("The mod's folder \"\(source)\" is missing from the download.")
                            continue
                        }
                        var found = false
                        for file in Self.files(in: sourceDir)
                        where Self.gameFileExtensions.contains((file.relativePath as NSString).pathExtension.lowercased()) {
                            found = true
                            if let issue = Self.checkSourceExtension(file.relativePath) {
                                blocking.append(issue)
                                continue
                            }
                            mapBasegame(Self.normalizeBasegameDestination(target + "/" + file.relativePath, trimDots: true), file.url)
                        }
                        if !found && blocking.isEmpty {
                            blocking.append("[BASEGAME] gamedirectorystructure found no game files to install in \"\(source)\".")
                        }
                    }
                } else {
                    for (source, destination) in zip(newFiles, replaceFiles) {
                        if let issue = Self.checkSourceExtension(source) {
                            blocking.append(issue)
                        } else if destination.contains("..") {
                            blocking.append("Relative path \(destination) cannot contain '..' in it")
                        } else if let sourceURL = PathResolver.resolve(source, in: modDir), !PathResolver.isDirectory(sourceURL) {
                            mapBasegame(Self.normalizeBasegameDestination(destination, trimDots: true), sourceURL)
                        } else {
                            blocking.append("The mod's file \"\(source)\" is missing from the download.")
                        }
                    }
                    // addfiles (moddesc 4.1+): files that may not exist in the game yet. They can't
                    // overlap each other or the replacement files.
                    for (source, destination) in zip(addFiles, addFilesTargets) {
                        let normalized = Self.normalizeBasegameDestination(destination, trimDots: false)
                        if let issue = Self.checkSourceExtension(source) {
                            blocking.append(issue)
                        } else if let sourceURL = PathResolver.resolve(source, in: modDir), !PathResolver.isDirectory(sourceURL) {
                            if basegameMap[normalized.lowercased()] != nil {
                                blocking.append("Failed to add additional file to mod job: \(destination) already is marked for modification. Files that are in the addfiles descriptor cannot overlap each other or replacement files.")
                            } else {
                                mapBasegame(normalized, sourceURL)
                            }
                        } else {
                            blocking.append("The mod's file \"\(source)\" is missing from the download.")
                        }
                    }
                }
            } else {
                blocking.append("[BASEGAME] moddir \"\(basegameModDir ?? "")\" is missing from the download.")
            }
        }
        let basegameFiles = basegameOrder.compactMap { basegameMap[$0] }
        if let game {
            for file in basegameFiles {
                if let issue = Self.basegameSiloIssue(file.gameRelativePath, game: game, modName: name) { blocking.append(issue) }
            }
        }

        var mergeMods: [String] = []
        for mergeMod in Self.list(ini.value("BASEGAME", "mergemods")) {
            let relative = mergeMod.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if relative.split(separator: "/").contains("..") {
                blocking.append("Merge mod \"\(mergeMod)\" has an invalid name.")
            } else if PathResolver.resolve("MergeMods/\(relative)", in: root) == nil {
                blocking.append("Merge mod \"\(relative)\" is missing from the MergeMods folder.")
            } else {
                mergeMods.append(relative)
            }
        }

        let usesTLKMerge = game == .le1
            && (Double(featureLevel) ?? 0) >= 7
            && ini.value("GAME1_EMBEDDED_TLK", "usesfeature")?.lowercased() == "true"
        if usesTLKMerge && PathResolver.resolve("GAME1_EMBEDDED_TLK", in: root) == nil {
            blocking.append("The mod's GAME1_EMBEDDED_TLK folder is missing from the download.")
        }

        // ASI mods (moddesc 9+, LE only): `asimodstoinstall = ((GroupID=87),(GroupID=12,Version=3))`.
        var asiMods: [ASIModRequest] = []
        if (Double(featureLevel) ?? 0) >= 9, let value = ini.value("ASIMODS", "asimodstoinstall") {
            for entry in value.matches(of: /\(([^()]+)\)/) {
                var group: Int?
                var version: Int?
                for pair in entry.output.1.split(separator: ",") {
                    let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard parts.count == 2 else { continue }
                    switch parts[0].lowercased() {
                    case "groupid": group = Int(parts[1])
                    case "version": version = Int(parts[1])
                    default: break
                    }
                }
                if let group {
                    asiMods.append(ASIModRequest(groupID: group, version: version))
                } else {
                    blocking.append("[ASIMODS] has an entry without a GroupID: \(entry.output.1)")
                }
            }
        }

        // Custom DLC jobs.
        var jobs: [CustomDLCJob] = []
        let sources = Self.list(ini.value("CUSTOMDLC", "sourcedirs"))
        let destinations = Self.list(ini.value("CUSTOMDLC", "destdirs"))
        if sources.count != destinations.count {
            blocking.append("[CUSTOMDLC] has \(sources.count) sourcedirs but \(destinations.count) destdirs.")
        } else {
            for (source, destination) in zip(sources, destinations) {
                if let issue = Self.validateDestination(destination, game: game) {
                    blocking.append(issue)
                    continue
                }
                guard !source.split(separator: "/").contains(".."),
                      let sourceURL = PathResolver.resolve(source, in: root),
                      PathResolver.isDirectory(sourceURL) else {
                    blocking.append("The mod's folder \"\(source)\" is missing from the download.")
                    continue
                }
                jobs.append(CustomDLCJob(sourceURL: sourceURL, sourcePath: source, destinationName: destination))
            }
        }

        // Optional components (altdlc / altfiles / multilistN), chosen in the install options window.
        var options: [ModOption] = []
        var multilists: [ModOption.Header: [Int: [String]]] = [:]
        do {
            options += try ModOptionParser.parse(ini.value("CUSTOMDLC", "altdlc"), kind: .dlc, header: .customDLC)
            options += try ModOptionParser.parse(ini.value("CUSTOMDLC", "altfiles"), kind: .file, header: .customDLC)
            options += try ModOptionParser.parse(ini.value("BASEGAME", "altfiles"), kind: .file, header: .basegame)
        } catch {
            blocking.append(error.localizedDescription)
        }
        for header in [ModOption.Header.customDLC, .basegame] {
            var index = 1
            while let value = ini.value(header.rawValue, "multilist\(index)") {
                multilists[header, default: [:]][index] = value.split(separator: ";")
                    .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
                    .filter { !$0.isEmpty }
                index += 1
            }
        }
        for option in options where option.kind == .dlc && option.operation == "OP_ADD_CUSTOMDLC" {
            if let dest = option.modDestDLC, let issue = Self.validateDestination(dest, game: game) {
                blocking.append(issue)
            }
        }
        let supported: Set<String> = [
            "OP_ADD_CUSTOMDLC", "OP_ADD_FOLDERFILES_TO_CUSTOMDLC", "OP_ADD_MULTILISTFILES_TO_CUSTOMDLC", "OP_NOTHING",
            "OP_ENABLE_TLKMERGE_OPTIONKEY", "OP_SUBSTITUTE", "OP_INSTALL", "OP_NOINSTALL", "OP_APPLY_MULTILISTFILES",
            "OP_NOINSTALL_MULTILISTFILES", "OP_APPLY_MERGEMODS",
        ]
        for option in options where !supported.contains(option.operation) {
            blocking.append("The optional component \"\(option.name)\" uses \(option.operation), which this app can't install yet.")
        }

        if jobs.isEmpty && basegameFiles.isEmpty && launcherFiles.isEmpty && mergeMods.isEmpty && !usesTLKMerge && asiMods.isEmpty
            && !options.contains(where: { $0.operation == "OP_ADD_CUSTOMDLC" }) && blocking.isEmpty {
            blocking.append("This mod has nothing this app can install.")
        }

        // Outdated (4.4+), required (5.0+) and incompatible (6.0+) DLC, as in Mod-Parsing.cs.
        let parsedGame = game
        var outdated: [String] = []
        if fl >= 4.4 {
            for entry in Self.list(ini.value("CUSTOMDLC", "outdatedcustomdlc")) {
                if let parsedGame, parsedGame.isOfficialDLC(entry) {
                    blocking.append("Outdated Custom DLC can't list official DLC (\(entry)).")
                } else if Self.validateDestination(entry, game: parsedGame) == nil {
                    outdated.append(entry)
                }
            }
        }
        outdatedDLC = outdated

        var required: [DLCRequirement] = []
        var optionalRequired: [DLCRequirement] = []
        if fl >= 5.0 {
            for entry in (ini.value("ModInfo", "requireddlc") ?? "").split(separator: ";").map(String.init)
            where !entry.trimmingCharacters(in: .whitespaces).isEmpty {
                var text = entry
                var isOptional = false
                if fl >= 6.2, text.hasPrefix("?") {
                    text.removeFirst()
                    isOptional = true
                }
                // M3 checks the DLC_ prefix before parsing, so +/- prefixes can't be used here.
                guard text.hasPrefix("DLC_") else {
                    blocking.append("The required DLC \"\(entry)\" isn't a DLC folder name.")
                    continue
                }
                do {
                    let requirement = fl >= 9.0
                        ? try DLCRequirement.parseKeyed(text, plusMinus: fl >= 8.0)
                        : try DLCRequirement.parseLegacy(text, supportsVersion: fl >= 8.0, plusMinus: false)
                    if let parsedGame, fl >= 8.0, parsedGame.isOfficialDLC(requirement.folder) {
                        blocking.append("Legendary Edition mods can't require official DLC (\(requirement.folder)).")
                        continue
                    }
                    if isOptional { optionalRequired.append(requirement) } else { required.append(requirement) }
                } catch {
                    blocking.append(error.localizedDescription)
                }
            }
        }
        requiredDLC = required
        optionalRequiredDLC = optionalRequired

        var incompatible: [String] = []
        if fl >= 6.0 {
            for entry in (ini.value("CUSTOMDLC", "incompatiblecustomdlc") ?? "").split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where !entry.isEmpty {
                if let parsedGame, parsedGame.isOfficialDLC(entry) {
                    blocking.append("Incompatible Custom DLC can't list official DLC (\(entry)).")
                } else {
                    incompatible.append(entry)
                }
            }
        }
        incompatibleDLC = incompatible

        var dlcNames: [String: String] = [:]
        for entry in ini.entries["customdlc"] ?? [] where entry.key.hasPrefix("DLC_") && dlcNames[entry.key] == nil {
            dlcNames[entry.key] = entry.value
        }
        customDLCNames = dlcNames

        self.jobs = jobs
        self.options = options
        self.multilists = multilists
        self.basegameFiles = basegameFiles
        self.launcherFiles = launcherFiles
        self.mergeMods = mergeMods
        self.usesTLKMerge = usesTLKMerge
        self.asiMods = asiMods
        self.warnings = warnings
        self.blockingIssues = blocking
    }

    /// File types M3 installs with `gamedirectorystructure` and into the launcher.
    private static let gameFileExtensions: Set<String> = ["u", "upk", "sfm", "pcc", "bin", "tlk", "cnd", "ini", "afc", "tfc", "dlc", "sfar", "txt", "bik", "bmp", "usf", "isb"]
    private static let launcherExtensions: Set<String> = ["bik", "cfg", "chn", "cht", "deu", "esn", "fra", "int", "ita", "jpn", "kor", "pol", "rus", "swd", "swf", "tmp", "wav"]

    /// Every file under `folder` (skipping hidden files), with its path relative to `folder`.
    private static func files(in folder: URL) -> [(url: URL, relativePath: String)] {
        let base = folder.standardizedFileURL.path
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return (enumerator?.allObjects ?? []).compactMap { $0 as? URL }
            .filter { !PathResolver.isDirectory($0) }
            .map { ($0, String($0.standardizedFileURL.path.dropFirst(base.count + 1))) }
            .sorted { $0.relativePath < $1.relativePath }
    }

    /// The game a launcher mod belongs with: from its files (the launcher's ME1/ME2/ME3 videos) or its name.
    private static func launcherHomeGame(name: String, files: [BasegameFile]) -> LEGame {
        let fileNames = files.map { ($0.gameRelativePath as NSString).lastPathComponent.uppercased() }
        let upperName = name.uppercased()
        for (game, number) in [(LEGame.le1, "1"), (.le2, "2"), (.le3, "3")] {
            if fileNames.contains(where: { $0.hasPrefix("ME\(number)") }) { return game }
        }
        for (game, number) in [(LEGame.le1, "1"), (.le2, "2"), (.le3, "3")]
        where upperName.contains("LE\(number)") || upperName.contains("ME\(number)") || upperName.contains("MASS EFFECT \(number)") {
            return game
        }
        return .le1
    }

    /// moddesc.ini lists are `;`-separated and use Windows path separators.
    private static func list(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\", with: "/") }
            .filter { !$0.isEmpty }
    }

    /// `replacefiles` must stay inside the game folder and outside the DLC folder (mods own their DLC folders).
    private static func validateBasegamePath(_ path: String) -> String? {
        let components = path.split(separator: "/")
        if path.hasPrefix("/") || components.contains("..") || components.isEmpty {
            return "\"\(path)\" isn't a valid game file path."
        }
        if components.count >= 2, components[0].lowercased() == "biogame", components[1].lowercased() == "dlc" {
            return "\"\(path)\" points into the DLC folder, which [BASEGAME] can't change."
        }
        return nil
    }

    /// moddesc `cmmver` as a number (M3 treats a missing or unreadable value as 1.0).
    static func normalizedFeatureLevel(_ text: String) -> Double {
        Double(text.trimmingCharacters(in: .whitespaces)) ?? 1.0
    }

    /// M3 refuses executable files in base game jobs (ModJob.checkExtension).
    static func checkSourceExtension(_ sourcePath: String) -> String? {
        switch (sourcePath as NSString).pathExtension.lowercased() {
        case "exe": return "Mods can't install .exe files (\(sourcePath))."
        case "dll": return "Mods can't install .dll files (\(sourcePath))."
        case "asi": return "Mods can't install .asi files directly (\(sourcePath)); they must use [ASIMODS]."
        default: return nil
        }
    }

    /// M3's destination clean-up (ModJob.AddFileToInstall): forward slashes, no leading separators or
    /// dots, and no `/./` segments.
    static func normalizeBasegameDestination(_ path: String, trimDots: Bool) -> String {
        var result = path.replacingOccurrences(of: "\\", with: "/")
        while result.hasPrefix("/") { result.removeFirst() }
        if trimDots { while result.hasPrefix(".") { result.removeFirst() } }
        while result.contains("/./") { result = result.replacingOccurrences(of: "/./", with: "/") }
        return result
    }

    /// M3's base game silo rules for Legendary Edition (ModJob.GetScopedSilos/CheckSilos): files may only
    /// go into Binaries/, BioGame/ or Engine/, never into Binaries/Win64, BioGame/Config or BioGame/DLC,
    /// and never over files that have their own merge feature.
    static func basegameSiloIssue(_ path: String, game: LEGame, modName: String) -> String? {
        let lower = path.lowercased()
        let components = lower.split(separator: "/")
        if components.contains("..") || components.isEmpty {
            return "\"\(path)\" isn't a valid game file path."
        }
        var disallowedFolders = ["binaries/win64/", "biogame/config/", "biogame/dlc/"]
        var disallowedFiles = ["biogame/cookedpcconsole/plotmanager.pcc", "biogame/cookedpcconsole/globalshadercache-pc-d3d-sm5.bin"]
        if game == .le3 { disallowedFiles.append("biogame/cookedpcconsole/conditionals.cnd") }
        disallowedFolders = disallowedFolders.filter { lower.hasPrefix($0) }
        if !disallowedFolders.isEmpty || disallowedFiles.contains(lower) {
            return "\(modName) tries to install \(path), which mods aren't allowed to change."
        }
        let allowed = ["binaries/", "biogame/", "engine/"]
        guard allowed.contains(where: { lower.hasPrefix($0) }) else {
            return "\(modName) tries to install \(path), outside the folders mods may change (Binaries, BioGame, Engine)."
        }
        return nil
    }

    /// Same rules M3 applies to `destdirs`: a single `DLC_` folder name that isn't an official DLC.
    private static func validateDestination(_ name: String, game: LEGame?) -> String? {
        if name.contains("/") || name.contains("..") || !name.uppercased().hasPrefix("DLC_") {
            return "\"\(name)\" isn't a valid Custom DLC folder name."
        }
        if let game, game.isOfficialDLC(name) {
            return "\"\(name)\" would overwrite official BioWare DLC."
        }
        return nil
    }
}

/// Mods are authored on Windows, where paths are case-insensitive. Resolve each path component
/// case-insensitively so a moddesc saying `dlc_mod_foo` still finds the folder `DLC_MOD_Foo`.
nonisolated enum PathResolver {
    static func resolve(_ relativePath: String, in base: URL) -> URL? {
        var current = base
        for component in relativePath.split(separator: "/").map(String.init) where component != "." {
            let exact = current.appending(path: component)
            if FileManager.default.fileExists(atPath: exact.path) {
                current = exact
                continue
            }
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: current.path),
                  let match = contents.first(where: { $0.caseInsensitiveCompare(component) == .orderedSame }) else {
                return nil
            }
            current = current.appending(path: match)
        }
        return current
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// The enabled DLC folders in a game (folders starting with `DLC_`) and their `_metacmm.txt`, as
/// ME3TweaksCore's `GameTarget.GetMetaMappedInstalledDLC` sees them. Keys are lowercased.
nonisolated struct InstalledDLC: Sendable {
    var names: Set<String> = []
    var metas: [String: MetaCMM] = [:]

    func contains(_ folder: String) -> Bool { names.contains(folder.lowercased()) }
    func meta(_ folder: String) -> MetaCMM? { metas[folder.lowercased()] }
}

/// A DLC folder plus optional conditions, ported from ME3TweaksCore's DLCRequirementBase /
/// DLCRequirement and M3's ConditionalDLC: `DLC_X`, `+DLC_X` / `-DLC_X` (must / must not be
/// installed), and since moddesc 9 `DLC_X[minversion=1.2,maxversion=2.0,optionkey=[option=+KEY]]`
/// checked against the installed folder's `_metacmm.txt`.
nonisolated struct DLCRequirement: Sendable, Hashable, CustomStringConvertible {
    struct OptionKeyCondition: Sendable, Hashable {
        /// `true` must have been chosen, `false` must not, `nil` at least one of the `nil` keys.
        let isPlus: Bool?
        let key: String
        let uiString: String?
    }

    let folder: String
    /// `+`/`-` prefix when the context allows one: `nil` means "must be installed" like `+`.
    let isPlus: Bool?
    let minVersion: [Int]?
    let maxVersion: [Int]?
    let optionKeys: [OptionKeyCondition]?
    /// Written in the keyed (moddesc 9+) form when serialized.
    let isKeyed: Bool

    var hasConditions: Bool { minVersion != nil || maxVersion != nil || optionKeys != nil }

    init(folder: String, isPlus: Bool? = nil, minVersion: [Int]? = nil, maxVersion: [Int]? = nil, optionKeys: [OptionKeyCondition]? = nil, isKeyed: Bool = false) {
        self.folder = folder
        self.isPlus = isPlus
        self.minVersion = minVersion
        self.maxVersion = maxVersion
        self.optionKeys = optionKeys
        self.isKeyed = isKeyed
    }

    private static func splitPlusMinus(_ text: String, allowed: Bool) -> (Bool?, String) {
        guard allowed, let first = text.first else { return (nil, text) }
        if first == "+" { return (true, String(text.dropFirst())) }
        if first == "-" { return (false, String(text.dropFirst())) }
        return (nil, text)
    }

    /// `DLCRequirementBase(string, featureLevel, folderNameIsPlusMinus)`: the moddesc 9+ keyed form.
    static func parseKeyed(_ input: String, plusMinus: Bool) throws -> DLCRequirement {
        let text = input.trimmingCharacters(in: .whitespaces)
        let start = text.firstIndex(of: "[")
        let end = text.lastIndex(of: "]")
        guard start != nil || end != nil else {
            let (plus, name) = splitPlusMinus(text, allowed: plusMinus)
            return DLCRequirement(folder: name, isPlus: plus, isKeyed: true)
        }
        guard let start, let end, start < end else {
            throw ModPackage.ParseError(message: "The DLC requirement \"\(text)\" has mismatched brackets.")
        }
        let attributes = String(text[text.index(after: start)..<end])
        let map = multiMap(attributes)
        if map.isEmpty {
            throw ModPackage.ParseError(message: "The DLC requirement \"\(text)\" has an empty or malformed condition list.")
        }
        var minVersion: [Int]?
        var maxVersion: [Int]?
        var optionKeys: [OptionKeyCondition]?
        for (key, values) in map {
            switch key.lowercased() {
            case "minversion":
                guard let version = parseVersion(values[0]) else {
                    throw ModPackage.ParseError(message: "The DLC requirement \"\(text)\" has an invalid version (\(values[0])).")
                }
                minVersion = version
            case "maxversion":
                guard let version = parseVersion(values[0]) else {
                    throw ModPackage.ParseError(message: "The DLC requirement \"\(text)\" has an invalid version (\(values[0])).")
                }
                maxVersion = version
            case "optionkey":
                for value in values {
                    let inner = singleMap(value)
                    guard let option = inner.first(where: { $0.key.lowercased() == "option" })?.value, !option.isEmpty else {
                        throw ModPackage.ParseError(message: "The DLC requirement \"\(text)\" has an optionkey without an option value.")
                    }
                    let (plus, key) = splitPlusMinus(option, allowed: true)
                    let ui = inner.first(where: { $0.key.lowercased() == "uistring" })?.value
                    optionKeys = (optionKeys ?? []) + [OptionKeyCondition(isPlus: plus, key: key, uiString: ui)]
                }
            default:
                throw ModPackage.ParseError(message: "The DLC requirement \"\(text)\" uses an unknown condition (\(key)).")
            }
        }
        let (plus, name) = splitPlusMinus(String(text[..<start]).trimmingCharacters(in: .whitespaces), allowed: plusMinus)
        return DLCRequirement(folder: name, isPlus: plus, minVersion: minVersion, maxVersion: maxVersion, optionKeys: optionKeys, isKeyed: true)
    }

    /// `DLCRequirement.ParseRequirement` (moddesc 8.x and below): `DLC_X` or, with versions, `DLC_X[1.2]` / `DLC_X(1.2)`.
    static func parseLegacy(_ input: String, supportsVersion: Bool, plusMinus: Bool) throws -> DLCRequirement {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard supportsVersion else {
            let (plus, name) = splitPlusMinus(text, allowed: plusMinus)
            return DLCRequirement(folder: name, isPlus: plus)
        }
        var start = text.firstIndex(of: "[")
        var end = text.firstIndex(of: "]")
        if start == nil && end == nil {
            start = text.firstIndex(of: "(")
            end = text.firstIndex(of: ")")
        }
        guard start != nil || end != nil else {
            let (plus, name) = splitPlusMinus(text, allowed: plusMinus)
            return DLCRequirement(folder: name, isPlus: plus)
        }
        guard let start, let end, start < end else {
            throw ModPackage.ParseError(message: "The DLC requirement \"\(text)\" has mismatched brackets.")
        }
        let versionText = String(text[text.index(after: start)..<end])
        guard let version = parseVersion(versionText) else {
            throw ModPackage.ParseError(message: "The DLC requirement \"\(text)\" has an invalid version (\(versionText)).")
        }
        let (plus, name) = splitPlusMinus(String(text[..<start]), allowed: plusMinus)
        return DLCRequirement(folder: name, isPlus: plus, minVersion: version)
    }

    /// .NET `Version.TryParse`: 2 to 4 non-negative integer components.
    static func parseVersion(_ text: String) -> [Int]? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == parts.count, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        return numbers
    }

    /// ME3TweaksCore ProperVersion comparison: unset components count as 0.
    static func compare(_ a: [Int], _ b: [Int]) -> ComparisonResult {
        for index in 0..<4 {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// `StringStructParser.GetSplitMultiMapValues` with `[`/`]`: `a=1,b=[x=1],b=[x=2]` → `[a: [1], b: [[x=1], [x=2]]]`.
    private static func multiMap(_ input: String) -> [(key: String, values: [String])] {
        var text = input.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix(";") { text.removeLast() }
        if text.count > 1, text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        var result: [(key: String, values: [String])] = []
        for (key, value) in topLevelPairs(text) {
            if let index = result.firstIndex(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
                result[index].values.append(value)
            } else {
                result.append((key, [value]))
            }
        }
        return result
    }

    /// `StringStructParser.GetSplitMapValues` with `[`/`]`.
    private static func singleMap(_ input: String) -> [(key: String, value: String)] {
        var text = input.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix(";") { text.removeLast() }
        if text.count > 1, text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        return topLevelPairs(text)
    }

    private static func topLevelPairs(_ text: String) -> [(key: String, value: String)] {
        var parts: [String] = []
        var depth = 0
        var inQuotes = false
        var current = ""
        for character in text {
            switch character {
            case "\"": inQuotes.toggle(); current.append(character)
            case "[": depth += 1; current.append(character)
            case "]": depth -= 1; current.append(character)
            case "," where depth <= 0 && !inQuotes:
                parts.append(current)
                current = ""
            default: current.append(character)
            }
        }
        parts.append(current)
        return parts.compactMap { part in
            // The last top-level '=' separates key and value, as in StringStructParser.
            var equals: String.Index?
            var level = 0
            var quoted = false
            for index in part.indices {
                switch part[index] {
                case "\"": quoted.toggle()
                case "[": level += 1
                case "]": level -= 1
                case "=" where level <= 0 && !quoted: equals = index
                default: break
                }
            }
            guard let equals else { return nil }
            let key = part[..<equals].trimmingCharacters(in: .whitespaces)
            var value = part[part.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            return (key, value)
        }
    }

    /// `DLCRequirementBase.IsRequirementMet`. Returns the reason when it isn't met.
    func check(_ installed: InstalledDLC, checkOptionKeys: Bool = true) -> String? {
        if isPlus == false {
            return installed.contains(folder) ? "\(folder) must not be installed." : nil
        }
        guard installed.contains(folder) else { return "\(folder) isn't installed." }
        guard hasConditions else { return nil }
        guard let meta = installed.meta(folder) else {
            return "\(folder) was installed without mod manager information (_metacmm.txt), so its version and options can't be checked."
        }
        if let minVersion {
            guard let version = Self.parseVersion(meta.version) else {
                return "The installed version of \(folder) (\(meta.version)) can't be read, so the minimum version \(Self.format(minVersion)) can't be checked."
            }
            if Self.compare(version, minVersion) == .orderedAscending {
                return "\(folder) \(meta.version) is installed, but version \(Self.format(minVersion)) or newer is required."
            }
        }
        if let maxVersion {
            guard let version = Self.parseVersion(meta.version) else {
                return "The installed version of \(folder) (\(meta.version)) can't be read, so the maximum version \(Self.format(maxVersion)) can't be checked."
            }
            if Self.compare(version, maxVersion) == .orderedDescending {
                return "\(folder) \(meta.version) is installed, but version \(Self.format(maxVersion)) or older is required."
            }
        }
        if checkOptionKeys, let optionKeys {
            let chosen = meta.optionKeys
            func wasChosen(_ key: String) -> Bool { chosen.contains { $0.caseInsensitiveCompare(key) == .orderedSame } }
            for condition in optionKeys where condition.isPlus != nil {
                if condition.isPlus == true && !wasChosen(condition.key) {
                    return "\(folder) isn't installed with the option \"\(condition.uiString ?? condition.key)\"."
                }
                if condition.isPlus == false && wasChosen(condition.key) {
                    return "\(folder) is installed with the incompatible option \"\(condition.uiString ?? condition.key)\"."
                }
            }
            let shared = optionKeys.filter { $0.isPlus == nil }
            if !shared.isEmpty && !shared.contains(where: { wasChosen($0.key) }) {
                return "\(folder) isn't installed with at least one of these options: \(shared.map { $0.uiString ?? $0.key }.joined(separator: ", "))."
            }
        }
        return nil
    }

    func isMet(_ installed: InstalledDLC) -> Bool { check(installed) == nil }

    private static func format(_ version: [Int]) -> String { version.map(String.init).joined(separator: ".") }

    /// `DLCRequirement.Serialize(false)`, as M3 writes it into `_metacmm.txt` `[REQUIREDDLC]`.
    var description: String {
        let name = (isPlus.map { $0 ? "+" : "-" } ?? "") + folder
        guard hasConditions else { return name }
        guard isKeyed else { return minVersion.map { "\(name)[\(Self.format($0))]" } ?? name }
        var parts: [String] = []
        if let minVersion { parts.append("minversion=\(Self.format(minVersion))") }
        if let optionKeys {
            for key in optionKeys {
                var inner = "option=" + (key.isPlus.map { $0 ? "+" : "-" } ?? "") + key.key
                if let ui = key.uiString, !ui.trimmingCharacters(in: .whitespaces).isEmpty { inner += ",uistring=\(ui)" }
                parts.append("optionkey=[\(inner)]")
            }
        }
        return parts.isEmpty ? name : "\(name)[\(parts.joined(separator: ","))]"
    }
}
