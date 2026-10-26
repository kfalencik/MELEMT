import Foundation

/// An optional component of a mod: an `altdlc` or `altfiles` entry from moddesc.ini, following
/// ME3Tweaks Mod Manager's alternates rules (objects/alternates in the M3 source).
nonisolated struct ModOption: Identifiable, Sendable, Hashable {
    enum Kind: Sendable, Hashable { case dlc, file }
    enum Header: String, Sendable, Hashable { case customDLC = "customdlc", basegame = "basegame" }

    /// The option key (explicit `OptionKey`, or M3's CRC32 of the name and group).
    let id: String
    let kind: Kind
    let header: Header
    let name: String
    let details: String
    let condition: String
    let operation: String
    let conditionalDLC: [String]
    let modAltDLC: String?
    let modDestDLC: String?
    let modFile: String?
    let altFile: String?
    let multiListID: Int?
    let multiListRoot: String?
    let multiListTarget: String?
    let flatten: Bool
    let checkedByDefault: Bool
    let group: String?
    let hidden: Bool
    /// `+KEY` / `-KEY` entries.
    let dependsOn: [String]
    let metAction: String?
    let notMetAction: String?
    /// `+DLC_X` / `-DLC_X` / `DLC_X` entries; manual altdlc options are only available when met.
    let dlcRequirements: [String]
    let requiredFiles: [(path: String, size: Int64)]
    let sortIndex: Int?
    let mergeFiles: [String]
    let tlkOptionKey: String?
    let applicableText: String?
    let notApplicableText: String?
    let imageName: String?

    var isManual: Bool { condition == "COND_MANUAL" }
    var isAlways: Bool { condition == "COND_ALWAYS" }

    static func == (lhs: ModOption, rhs: ModOption) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: Parsing

nonisolated enum ModOptionParser {
    /// Parses `altdlc` / `altfiles` lists for one header. Throws with a readable message on bad data.
    static func parse(_ value: String?, kind: ModOption.Kind, header: ModOption.Header) throws -> [ModOption] {
        guard let value, !value.isEmpty else { return [] }
        return try structs(in: value).map { try option(from: keyValues(in: $0), kind: kind, header: header) }
    }

    private static func option(from map: [String: String], kind: ModOption.Kind, header: ModOption.Header) throws -> ModOption {
        func value(_ key: String) -> String? {
            map.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }.flatMap { $0.value.isEmpty ? nil : $0.value }
        }
        func path(_ key: String) -> String? {
            value(key).map { $0.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        }
        func list(_ key: String) -> [String] {
            (value(key) ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        guard let name = value("FriendlyName") else {
            throw ModPackage.ParseError(message: "An optional component in moddesc.ini has no FriendlyName.")
        }
        for key in ["ModAltDLC", "ModDestDLC", "ModFile", "AltFile", "ModAltFile", "MultiListRootPath", "MultiListTargetPath"] {
            if let p = path(key), p.split(separator: "/").contains("..") {
                throw ModPackage.ParseError(message: "The optional component \"\(name)\" has an invalid path.")
            }
        }
        let group = value("OptionGroup")
        let paths = list("RequiredFileRelativePaths").map { $0.replacingOccurrences(of: "\\", with: "/") }
        let sizes = list("RequiredFileSizes").compactMap { Int64($0) }

        return ModOption(
            id: value("OptionKey") ?? generatedKey(name: name, group: group),
            kind: kind,
            header: header,
            name: name,
            details: value("Description") ?? "",
            condition: (value("Condition") ?? "COND_MANUAL").uppercased(),
            operation: (value("ModOperation") ?? "OP_NOTHING").uppercased(),
            conditionalDLC: list("ConditionalDLC"),
            modAltDLC: path("ModAltDLC"),
            modDestDLC: path("ModDestDLC"),
            modFile: path("ModFile"),
            altFile: path("AltFile") ?? path("ModAltFile") ?? path("SubstituteFile"),
            multiListID: value("MultiListId").flatMap { Int($0) },
            multiListRoot: path("MultiListRootPath"),
            multiListTarget: path("MultiListTargetPath"),
            flatten: value("FlattenMultiListOutput")?.lowercased() == "true",
            checkedByDefault: value("CheckedByDefault")?.lowercased() == "true",
            group: group,
            hidden: value("Hidden")?.lowercased() == "true",
            dependsOn: list("DependsOnKeys"),
            metAction: value("DependsOnMetAction")?.uppercased(),
            notMetAction: value("DependsOnNotMetAction")?.uppercased(),
            dlcRequirements: list("DLCRequirements"),
            requiredFiles: zip(paths, sizes).map { (path: $0, size: $1) },
            sortIndex: value("SortIndex").flatMap { Int($0) },
            mergeFiles: list("MergeFiles"),
            tlkOptionKey: value("LE1TLKOptionKey"),
            applicableText: value("ApplicableAutoText"),
            notApplicableText: value("NotApplicableAutoText"),
            imageName: value("ImageAssetName")
        )
    }

    /// `((A=1,B=2),(A=3))` → `["A=1,B=2", "A=3"]`.
    static func structs(in value: String) -> [String] {
        var text = value.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("("), text.hasSuffix(")") { text = String(text.dropFirst().dropLast()) }
        var results: [String] = []
        var depth = 0
        var current = ""
        for character in text {
            switch character {
            case "(", "[":
                if depth > 0 { current.append(character) }
                depth += 1
            case ")", "]":
                depth -= 1
                if depth == 0 {
                    results.append(current)
                    current = ""
                } else {
                    current.append(character)
                }
            default:
                if depth > 0 { current.append(character) }
            }
        }
        return results
    }

    /// `A=1,B=[x;y],C=(z)` → `["A": "1", "B": "x;y", "C": "z"]`.
    static func keyValues(in text: String) -> [String: String] {
        var parts: [String] = []
        var depth = 0
        var inQuotes = false
        var current = ""
        for character in text {
            switch character {
            case "\"": inQuotes.toggle(); current.append(character)
            case "(", "[": depth += 1; current.append(character)
            case ")", "]": depth -= 1; current.append(character)
            case "," where depth == 0 && !inQuotes:
                parts.append(current)
                current = ""
            default: current.append(character)
            }
        }
        parts.append(current)
        var map: [String: String] = [:]
        for part in parts {
            guard let equals = part.firstIndex(of: "=") else { continue }
            let key = part[..<equals].trimmingCharacters(in: .whitespaces)
            var value = part[part.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            for (open, close) in [("[", "]"), ("\"", "\""), ("(", ")")] where value.hasPrefix(open) && value.hasSuffix(close) && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            map[key] = value
        }
        return map
    }

    /// M3's default OptionKey: uppercase hex CRC32 of the UTF-16LE bytes of name + group name.
    static func generatedKey(name: String, group: String?) -> String {
        let bytes = Array((name + (group ?? "")).utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        return String(format: "%08X", ~crc)
    }
}

// MARK: Resolving choices

/// The resolved state of one option given the game's installed DLC and the user's choices.
nonisolated struct ModOptionState: Sendable, Hashable {
    var selected: Bool
    var selectable: Bool
    var notApplicable: Bool
}

/// Applies M3's selection rules: automatic conditions, manual defaults, DLC requirements,
/// option groups (exactly one selected) and DependsOn actions.
nonisolated struct ModOptionResolver: Sendable {
    let options: [ModOption]
    /// Lowercased names of enabled DLC folders in the game (official and mods).
    let installedDLC: Set<String>
    let gameDirectory: URL

    /// `choices` holds the user's explicit picks (option id → on/off).
    func resolve(choices: [String: Bool]) -> [String: ModOptionState] {
        var states: [String: ModOptionState] = [:]
        for option in options {
            states[option.id] = baseState(option, choice: choices[option.id])
        }
        for _ in 0..<15 {
            let before = states
            applyGroups(&states, choices: choices)
            applyDependsOn(&states, choices: choices)
            if states == before { break }
        }
        applyGroups(&states, choices: choices)
        return states
    }

    private func present(_ name: String) -> Bool { installedDLC.contains(name.lowercased()) }

    /// `+X`/`X` must be present, `-X` must be absent.
    private func requirementsMet(_ entries: [String]) -> Bool {
        entries.allSatisfy { entry in
            if entry.hasPrefix("-") { return !present(String(entry.dropFirst())) }
            return present(entry.hasPrefix("+") ? String(entry.dropFirst()) : entry)
        }
    }

    private func conditionMet(_ option: ModOption) -> Bool {
        let names = option.conditionalDLC.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "+-")) }
        switch option.condition {
        case "COND_ALWAYS": return true
        case "COND_DLC_PRESENT", "COND_ANY_DLC_PRESENT": return names.contains(where: present)
        case "COND_DLC_NOT_PRESENT", "COND_ANY_DLC_NOT_PRESENT":
            return option.kind == .file ? !names.contains(where: present) : !names.allSatisfy(present)
        case "COND_ALL_DLC_PRESENT": return names.allSatisfy(present)
        case "COND_ALL_DLC_NOT_PRESENT": return !names.contains(where: present)
        case "COND_SPECIFIC_DLC_SETUP": return requirementsMet(option.conditionalDLC)
        case "COND_SPECIFIC_SIZED_FILES":
            return option.requiredFiles.allSatisfy { file in
                guard let url = PathResolver.resolve(file.path, in: gameDirectory),
                      let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 else { return false }
                return size == file.size
            }
        default: return false
        }
    }

    private func baseState(_ option: ModOption, choice: Bool?) -> ModOptionState {
        if option.isManual {
            if option.kind == .dlc, !option.dlcRequirements.isEmpty, !requirementsMet(option.dlcRequirements) {
                return ModOptionState(selected: false, selectable: false, notApplicable: true)
            }
            return ModOptionState(selected: choice ?? option.checkedByDefault, selectable: true, notApplicable: false)
        }
        let met = conditionMet(option)
        return ModOptionState(selected: met, selectable: false, notApplicable: !met && !option.isAlways)
    }

    private func applyGroups(_ states: inout [String: ModOptionState], choices: [String: Bool]) {
        var groups: [String: [ModOption]] = [:]
        for option in options { if let group = option.group { groups[group, default: []].append(option) } }
        for members in groups.values {
            let applicable = members.filter { !(states[$0.id]?.notApplicable ?? true) }
            let chosen = members.first { !$0.isManual && states[$0.id]?.selected == true }
                ?? members.first { choices[$0.id] == true && states[$0.id]?.selectable == true }
                ?? members.first { $0.checkedByDefault && applicable.contains($0) }
                ?? applicable.first
            for member in members {
                states[member.id]?.selected = member.id == chosen?.id
            }
        }
    }

    private func applyDependsOn(_ states: inout [String: ModOptionState], choices: [String: Bool]) {
        for option in options where !option.dependsOn.isEmpty && !(states[option.id]?.notApplicable ?? false) {
            let met = option.dependsOn.allSatisfy { entry in
                let key = String(entry.dropFirst())
                let selected = states[key]?.selected ?? false
                return entry.hasPrefix("-") ? !selected : selected
            }
            let wasSelectable = states[option.id]?.selectable ?? false
            switch (met ? option.metAction : option.notMetAction) ?? "ACTION_ALLOW_SELECT" {
            case "ACTION_DISALLOW_SELECT":
                states[option.id]?.selectable = false
                states[option.id]?.selected = false
            case "ACTION_DISALLOW_SELECT_CHECKED":
                states[option.id]?.selectable = false
                states[option.id]?.selected = true
            case "ACTION_ALLOW_SELECT_CHECKED":
                let current = states[option.id]?.selected ?? true
                states[option.id]?.selectable = true
                states[option.id]?.selected = choices[option.id] ?? (wasSelectable ? current : true)
            default: // ACTION_ALLOW_SELECT
                let current = states[option.id]?.selected ?? false
                states[option.id]?.selectable = true
                states[option.id]?.selected = choices[option.id] ?? (wasSelectable ? current : false)
            }
        }
    }
}

// MARK: Install plan

/// Exactly what an install copies, after applying the selected options (M3's
/// Mod-Installation.cs order: base files, then option overrides, then removals).
nonisolated struct InstallPlan: Sendable {
    /// Paths relative to BioGame/DLC (e.g. `DLC_MOD_X/CookedPCConsole/A.pcc`) → source file.
    var dlcFiles: [String: URL] = [:]
    /// Paths relative to the game folder → source file.
    var basegameFiles: [String: URL] = [:]
    var mergeMods: [String] = []
    var tlkOptionKeys: [String] = []
    /// Names of the selected optional components, recorded in _metacmm.txt.
    var selectedOptionNames: [String] = []

    /// Top-level DLC folders this install creates.
    var dlcFolders: [String] {
        Array(Set(dlcFiles.keys.compactMap { $0.split(separator: "/").first.map(String.init) })).sorted()
    }

    init(package: ModPackage, states: [String: ModOptionState]) throws {
        let root = package.rootURL
        let selected = package.options.filter { states[$0.id]?.selected == true }
        selectedOptionNames = selected.filter { !$0.hidden }.map(\.name)

        func files(under relative: String) throws -> [(relative: String, url: URL)] {
            guard let folder = PathResolver.resolve(relative, in: root), PathResolver.isDirectory(folder) else {
                throw ModPackage.ParseError(message: "The mod's folder \"\(relative)\" is missing from the unpacked download.")
            }
            guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
            let base = folder.standardizedFileURL.path
            return enumerator.allObjects.compactMap { item in
                guard let url = item as? URL, !PathResolver.isDirectory(url), url.lastPathComponent != ".DS_Store" else { return nil }
                return (String(url.standardizedFileURL.path.dropFirst(base.count + 1)), url)
            }
        }
        func source(_ relative: String?) throws -> URL {
            guard let relative, let url = PathResolver.resolve(relative, in: root), !PathResolver.isDirectory(url) else {
                throw ModPackage.ParseError(message: "A file for one of the selected options (\(relative ?? "?")) is missing from the download.")
            }
            return url
        }
        func multilist(_ option: ModOption) -> [String] {
            guard let id = option.multiListID else { return [] }
            return package.multilists[option.header]?[id] ?? []
        }
        func matches(_ a: String?, _ b: String) -> Bool { a?.caseInsensitiveCompare(b) == .orderedSame }

        // Custom DLC: base folders plus OP_ADD_CUSTOMDLC, with altfiles applied per file.
        var mappings = package.jobs.map { (source: $0.sourcePath, destination: $0.destinationName) }
        for option in selected where option.kind == .dlc && option.operation == "OP_ADD_CUSTOMDLC" {
            if let src = option.modAltDLC, let dest = option.modDestDLC {
                mappings.removeAll { $0.source.caseInsensitiveCompare(src) == .orderedSame }
                mappings.append((src, dest))
            }
        }
        let dlcAltFiles = selected.filter { $0.kind == .file && $0.header == .customDLC }
        for mapping in mappings {
            for file in try files(under: mapping.source) {
                let sourceKey = "\(mapping.source)/\(file.relative)"
                let destinationKey = "\(mapping.destination)/\(file.relative)"
                if let alt = dlcAltFiles.first(where: { matches($0.modFile, sourceKey) }) {
                    switch alt.operation {
                    case "OP_NOINSTALL": continue
                    case "OP_SUBSTITUTE", "OP_INSTALL": dlcFiles[destinationKey] = try source(alt.altFile); continue
                    default: break
                    }
                }
                dlcFiles[destinationKey] = file.url
            }
        }
        for option in selected where option.kind == .dlc {
            switch option.operation {
            case "OP_ADD_FOLDERFILES_TO_CUSTOMDLC":
                guard let src = option.modAltDLC, let dest = option.modDestDLC else { continue }
                for file in try files(under: src) { dlcFiles["\(dest)/\(file.relative)"] = file.url }
            case "OP_ADD_MULTILISTFILES_TO_CUSTOMDLC":
                guard let rootPath = option.multiListRoot, let dest = option.modDestDLC else { continue }
                for entry in multilist(option) {
                    let name = option.flatten ? (entry as NSString).lastPathComponent : entry
                    dlcFiles["\(dest)/\(name)"] = try source("\(rootPath)/\(entry)")
                }
            case "OP_ENABLE_TLKMERGE_OPTIONKEY":
                if let key = option.tlkOptionKey { tlkOptionKeys.append(key) }
            default: break
            }
        }
        for option in dlcAltFiles where option.operation == "OP_NOINSTALL_MULTILISTFILES" {
            for entry in multilist(option) {
                let key = "\(option.multiListTarget ?? "")/\(entry)"
                dlcFiles.keys.filter { $0.caseInsensitiveCompare(key) == .orderedSame }.forEach { dlcFiles.removeValue(forKey: $0) }
            }
        }

        // Base game: replacements with altfiles applied, multilists, removals, merge mods.
        let baseAltFiles = selected.filter { $0.kind == .file && $0.header == .basegame }
        for file in package.basegameFiles {
            if let alt = baseAltFiles.first(where: { matches($0.modFile, file.gameRelativePath) }) {
                switch alt.operation {
                case "OP_NOINSTALL": continue
                case "OP_SUBSTITUTE", "OP_INSTALL": basegameFiles[file.gameRelativePath] = try source(alt.altFile); continue
                default: break
                }
            }
            basegameFiles[file.gameRelativePath] = file.sourceURL
        }
        mergeMods = package.mergeMods
        for option in baseAltFiles {
            switch option.operation {
            case "OP_APPLY_MULTILISTFILES":
                guard let rootPath = option.multiListRoot, let target = option.multiListTarget else { continue }
                for entry in multilist(option) {
                    let name = option.flatten ? (entry as NSString).lastPathComponent : entry
                    basegameFiles["\(target)/\(name)"] = try source("\(rootPath)/\(entry)")
                }
            case "OP_APPLY_MERGEMODS":
                mergeMods += option.mergeFiles
            default: break
            }
        }
        for option in baseAltFiles where option.operation == "OP_NOINSTALL_MULTILISTFILES" {
            for entry in multilist(option) {
                let key = "\(option.multiListTarget ?? "")/\(entry)"
                basegameFiles.keys.filter { $0.caseInsensitiveCompare(key) == .orderedSame }.forEach { basegameFiles.removeValue(forKey: $0) }
            }
        }
        for key in Array(basegameFiles.keys) + Array(dlcFiles.keys) where key.split(separator: "/").contains("..") {
            throw ModPackage.ParseError(message: "One of the mod's files has an invalid path (\(key)).")
        }
    }
}
