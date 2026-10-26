import AppKit
import Foundation
import Observation

/// A mod in the library: downloaded from Nexus Mods, dropped onto the window, or found in
/// ~/Downloads. Tracks it from download through install, and stays afterwards so it can be
/// reinstalled.
@Observable
final class DownloadItem: Identifiable {
    enum Phase: Equatable {
        /// Saved in the library and not unpacked (e.g. after relaunching the app).
        case stored
        case fetchingInfo
        case downloading
        case unpacking
        /// Unpacked and waiting for the user to click Install (see `attentionReasons`).
        case ready
        case installing
        case installed
        /// Download stopped part-way (app quit, network drop, expired link); resumes from the .part file.
        case paused(String)
        case failed(String)

        var failureMessage: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    enum Source: Equatable {
        case nexus(NXMLink)
        case file(URL)
    }

    let id: UUID
    /// A fresh "Mod Manager Download" click replaces the link (new one-time key) to resume.
    var source: Source
    let addedAt: Date
    var title: String
    var subtitle: String?
    var imageURL: URL?
    /// The game the mod is for, from its moddesc.ini.
    var game: LEGame?
    /// Custom DLC folders the mod installs; used to tell whether it's currently installed.
    var dlcFolders: [String] = []
    var installedAt: Date?
    var phase: Phase = .fetchingInfo
    var status: String?
    /// 0...1 while downloading; nil when the size isn't known.
    var progress: Double?
    var bytesReceived: Int64 = 0
    var bytesExpected: Int64 = 0
    /// Smoothed download speed, for the speed and time-left display.
    var bytesPerSecond: Double = 0
    @ObservationIgnored fileprivate var lastSample: (time: Date, bytes: Int64)?

    /// Seconds left at the current speed, when known.
    var secondsRemaining: Double? {
        guard phase == .downloading, bytesPerSecond > 1, bytesExpected > bytesReceived else { return nil }
        return Double(bytesExpected - bytesReceived) / bytesPerSecond
    }

    fileprivate func recordProgress(received: Int64) {
        let now = Date.now
        if let last = lastSample {
            let elapsed = now.timeIntervalSince(last.time)
            if elapsed >= 0.5 {
                let instant = Double(received - last.bytes) / elapsed
                // Exponential moving average so the numbers don't jump around.
                bytesPerSecond = bytesPerSecond == 0 ? instant : bytesPerSecond * 0.8 + instant * 0.2
                lastSample = (now, received)
            }
        } else {
            lastSample = (now, received)
        }
        bytesReceived = received
    }
    var archiveURL: URL?
    var packages: [ModPackage] = []
    var installedPackageIDs = Set<ModPackage.ID>()
    /// Why the item wasn't installed automatically.
    var attentionReasons: [String] = []
    /// The user's last choices for the mod's optional components (option id → on/off).
    var chosenOptions: [String: Bool] = [:]
    /// Required mods (DLC folder names) this item is waiting for before it installs itself.
    var waitingFor: [String] = []
    /// Folder the archive was unpacked into; removed after installing and when the item is removed.
    var unpackedFolder: URL?
    /// Where an unfinished download is being written (`<name>.part`) and its final name.
    var partialURL: URL?
    var destinationURL: URL?

    @ObservationIgnored fileprivate var downloadTask: URLSessionTask?

    init(id: UUID = UUID(), source: Source, title: String, addedAt: Date = .now) {
        self.id = id
        self.source = source
        self.title = title
        self.addedAt = addedAt
    }

    var nexusModID: Int? {
        if case .nexus(let link) = source { return link.modID }
        return nil
    }

    var isActive: Bool {
        switch phase {
        case .fetchingInfo, .downloading, .unpacking, .installing: true
        default: false
        }
    }

    var needsAttention: Bool {
        if case .failed = phase { return true }
        return phase == .ready && (!attentionReasons.isEmpty || !waitingFor.isEmpty)
    }

    var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    var isPaused: Bool {
        if case .paused = phase { return true }
        return false
    }

    /// Still being downloaded (or the download itself failed). These show in Downloads; once the
    /// file is here and the mod's game is known, the item belongs to that game's page.
    var isDownloadStage: Bool {
        switch phase {
        case .fetchingInfo, .downloading, .paused: return true
        case .failed: return archiveURL == nil
        default: return game == nil && phase != .unpacking
        }
    }

    /// Unpacking, installing or waiting for a decision: shown on its game's page.
    var isGameStageWork: Bool {
        guard game != nil, !isDownloadStage else { return false }
        return phase == .unpacking || phase == .installing || needsAttention
    }
}

/// A newer version of an installed mod on Nexus Mods.
nonisolated struct ModUpdate: Sendable, Hashable {
    let modID: Int
    /// The specific newer file (a mod page can hold separate files for each game).
    let fileID: Int
    let installedVersion: String
    let latestVersion: String
}

/// Downloads mods from Nexus Mods "Mod Manager Download" links, unpacks archives, installs each
/// mod into the game its moddesc.ini names (automatically when nothing needs a decision), keeps a
/// library for reinstalling, and checks installed mods for updates.
@Observable
final class DownloadManager {
    static let autoInstallKey = "autoInstall"
    static let watchDownloadsKey = "watchDownloadsFolder"
    private static let seenArchivesKey = "seenDownloadArchives"

    private(set) var items: [DownloadItem] = []
    private(set) var nexusUser: NexusClient.User?
    private(set) var hasAPIKey = NexusKeychain.load() != nil
    /// Updates for installed mods, keyed by lowercased DLC folder name.
    private(set) var updates: [String: ModUpdate] = [:]
    private(set) var isCheckingForUpdates = false

    /// A mod waiting for the user to choose its options in the install options window.
    struct OptionsRequest: Identifiable {
        let id = UUID()
        let item: DownloadItem
        let package: ModPackage
    }

    /// The options window currently shown; further requests wait in `pendingOptionRequests`.
    var optionsRequest: OptionsRequest?
    @ObservationIgnored private var pendingOptionRequests: [OptionsRequest] = []

    @ObservationIgnored private let library: ModLibrary
    @ObservationIgnored private var installQueue: [(DownloadItem, ModPackage, [String: Bool])] = []
    @ObservationIgnored private var isInstalling = false
    @ObservationIgnored private var downloadsWatcher: DispatchSourceFileSystemObject?

    /// Working folder on the same drive as the game, so multi-gigabyte mods don't fill the Mac's
    /// internal disk and installing doesn't copy them across drives.
    private var workFolder: URL {
        if let root = library.install?.root {
            return root.appending(path: "LEModManager", directoryHint: .isDirectory)
        }
        return URL.downloadsDirectory.appending(path: "Mass Effect LE Mods", directoryHint: .isDirectory)
    }

    /// Where downloads from Nexus Mods are saved.
    var downloadsFolder: URL { workFolder.appending(path: "Downloads", directoryHint: .isDirectory) }

    /// Where archives are unpacked before installing; emptied after each install.
    var unpackFolder: URL { workFolder.appending(path: "Temp", directoryHint: .isDirectory) }

    private static var libraryFile: URL {
        URL.applicationSupportDirectory.appending(path: "LEModManager/Library.json")
    }

    init(library: ModLibrary) {
        self.library = library
        UserDefaults.standard.register(defaults: [Self.autoInstallKey: true, Self.watchDownloadsKey: true])
        loadLibrary()
        loadPendingDownloads()
    }

    /// Removes unpacked copies and unfinished (.part) downloads left by an earlier session.
    func cleanUpUnpackFolder() {
        let folder = unpackFolder
        let downloads = downloadsFolder
        // Everything in MELEMT's own Downloads folder belongs to a library item or a resumable
        // download. Anything else is a leftover (e.g. cut off by an older version) and goes to the Trash.
        let referenced = Set(items.flatMap { [$0.partialURL, $0.archiveURL, $0.destinationURL] }.compactMap { $0?.standardizedFileURL.path })
        Task.detached {
            let fm = FileManager.default
            try? fm.removeItem(at: folder)
            for file in (try? fm.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil)) ?? []
            where !referenced.contains(file.standardizedFileURL.path) && file.lastPathComponent != ".DS_Store" {
                try? fm.trashItem(at: file, resultingItemURL: nil)
            }
        }
    }

    var activeCount: Int { items.filter { $0.isActive || $0.isPaused }.count }
    var attentionCount: Int { items.filter(\.needsAttention).count }
    /// Downloads in progress or that need attention as downloads (the Downloads badge).
    var downloadCount: Int { items.filter(\.isDownloadStage).count }
    /// Mods for `game` being unpacked/installed or waiting for a decision (the game's badge).
    func workCount(for game: LEGame) -> Int { items.filter { $0.game == game && $0.isGameStageWork }.count }

    func items(for game: LEGame) -> [DownloadItem] {
        items.filter { $0.game == game }
    }

    /// Installed mods for `game` that only change the game's own files (merge mods, text merges,
    /// replaced files) and so have no DLC folder to list.
    func gameFileMods(for game: LEGame) -> [DownloadItem] {
        items(for: game).filter { $0.dlcFolders.isEmpty && $0.installedAt != nil }
    }

    /// After a reset or restore, mods that only changed game files are no longer installed.
    func forgetGameFileMods(for game: LEGame) {
        for item in gameFileMods(for: game) {
            item.installedAt = nil
            if item.phase == .installed { item.phase = .stored }
        }
        saveLibrary()
    }

    /// Whether the item's Custom DLC folders are present (enabled or disabled) in its game.

    /// Progress of a running (or just finished) Rebuild Mods, shown in its own window.
    var rebuild: RebuildProgress?

    /// Rebuild Mods: puts back the game's original files, then reinstalls every mod from the library
    /// that's installed in `game`, one at a time in load order (mount priority) with the options chosen
    /// before, waiting for each to finish. Merge mods, text merges and config merges are all redone
    /// cleanly on vanilla files. A mod that fails is reported and the rest still go ahead.
    func rebuildMods(for game: LEGame) async {
        guard rebuild == nil || rebuild?.isFinished == true else { return }
        let priorities = Dictionary((library.mods[game] ?? []).map { ($0.dlcName.lowercased(), $0.mountPriority ?? Int.max) }, uniquingKeysWith: min)
        func priority(_ item: DownloadItem) -> Int {
            item.dlcFolders.compactMap { priorities[$0.lowercased()] }.min() ?? Int.max
        }
        let mods = items
            .filter { $0.game == game && $0.installedAt != nil && (isInstalled($0) || $0.dlcFolders.isEmpty) }
            .sorted { priority($0) < priority($1) }

        let progress = RebuildProgress(game: game, steps: ["Restore \(game.displayName)'s original files"] + mods.map(\.title))
        rebuild = progress

        progress.start(0)
        library.errorMessage = nil
        await library.restoreOriginalFiles(for: game)
        if let error = library.errorMessage {
            library.errorMessage = nil
            progress.fail(0, error)
            progress.isFinished = true
            return
        }
        forgetGameFileMods(for: game)
        progress.finish(0)

        for (index, item) in mods.enumerated() {
            let step = index + 1
            progress.start(step)
            guard item.archiveURL != nil else {
                progress.fail(step, "Its download is no longer in the library, so it can't be reinstalled.")
                continue
            }
            guard await unpack(item, userRequested: true, decide: false) else {
                progress.fail(step, item.phase.failureMessage ?? "Couldn't unpack it.")
                continue
            }
            let main = item.packages.filter { $0.canInstall && !$0.targetsLauncher }
            let addOns = item.packages.filter { $0.canInstall && $0.targetsLauncher }
            guard let package = main.first ?? addOns.first else {
                progress.fail(step, item.packages.first?.blockingIssues.first ?? "It can't be installed.")
                continue
            }
            var errors: [String] = []
            if let error = await installNow(package, from: item, choices: item.chosenOptions) { errors.append(error) }
            if !package.targetsLauncher {
                for addOn in addOns {
                    if let error = await installNow(addOn, from: item, choices: [:]) { errors.append(error) }
                }
            }
            if errors.isEmpty { progress.finish(step) } else { progress.fail(step, errors.joined(separator: " ")) }
        }
        progress.isFinished = true
        recheckWaitingItems()
    }

    func isInstalled(_ item: DownloadItem) -> Bool {
        guard let game = item.game, !item.dlcFolders.isEmpty else { return item.installedAt != nil }
        let installed = Set((library.mods[game] ?? []).map { $0.dlcName.lowercased() })
        return item.dlcFolders.allSatisfy { installed.contains($0.lowercased()) }
    }

    func update(for mod: InstalledMod) -> ModUpdate? {
        updates[mod.dlcName.lowercased()]
    }

    // MARK: Nexus account

    /// Checks the saved API key with Nexus Mods and records the account name.
    func refreshNexusAccount() async {
        guard let key = NexusKeychain.load() else {
            hasAPIKey = false
            nexusUser = nil
            return
        }
        hasAPIKey = true
        nexusUser = try? await NexusClient.validate(apiKey: key)
    }

    /// Validates and saves an API key. Returns an error message if Nexus Mods rejects it.
    func connectNexus(apiKey: String) async -> String? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return "Paste your API key first." }
        do {
            nexusUser = try await NexusClient.validate(apiKey: key)
            NexusKeychain.save(key)
            hasAPIKey = true
            await checkForUpdates()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func disconnectNexus() {
        NexusKeychain.delete()
        hasAPIKey = false
        nexusUser = nil
        updates = [:]
    }

    // MARK: Adding items

    /// Handles a "Mod Manager Download" (nxm://) link from nexusmods.com.
    func handle(nxmURL url: URL) {
        guard let link = NXMLink(url: url) else {
            library.errorMessage = "That Nexus Mods link couldn't be read."
            return
        }
        startDownload(link)
    }

    private func startDownload(_ link: NXMLink, title: String? = nil) {
        // Each "Mod Manager Download" click carries a new one-time key, so match on the file itself.
        let sameFile = items.filter { item in
            if case .nexus(let other) = item.source { return other.modID == link.modID && other.fileID == link.fileID }
            return false
        }
        if let paused = sameFile.first(where: \.isPaused) {
            // A fresh click on a paused download: use the new link and continue where it stopped.
            paused.source = .nexus(link)
            resume(paused)
            return
        }
        if sameFile.contains(where: { $0.isActive || $0.phase == .ready }) { return }
        if let existing = sameFile.first(where: { $0.archiveURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }) {
            // Already downloaded: install (or reinstall) the copy in the library.
            install(existing)
            return
        }
        let item = DownloadItem(source: .nexus(link), title: title ?? "Nexus Mods file \(link.fileID)")
        items.insert(item, at: 0)
        Task { await download(item, link: link) }
    }

    /// Adds an archive or folder the user dropped or chose, or one found in ~/Downloads.
    func add(fileURL url: URL, title: String? = nil) {
        if let existing = items.first(where: { $0.archiveURL == url }) {
            if existing.phase == .stored || existing.isFailed { install(existing) }
            return
        }
        let item = DownloadItem(source: .file(url), title: title ?? url.deletingPathExtension().lastPathComponent)
        item.archiveURL = url
        items.insert(item, at: 0)
        Task { await unpack(item, userRequested: false) }
    }

    func retry(_ item: DownloadItem) {
        switch item.source {
        case .nexus(let link) where item.archiveURL == nil:
            remove(item, deleteFile: false)
            startDownload(link, title: item.title)
        default:
            install(item)
        }
    }

    func cancel(_ item: DownloadItem) {
        item.downloadTask?.cancel()
        item.phase = .failed("Cancelled")
        if let partial = item.partialURL { try? FileManager.default.removeItem(at: partial) }
        item.partialURL = nil
        item.destinationURL = nil
        savePendingDownloads()
    }

    /// Continues a paused download from where it stopped.
    func resume(_ item: DownloadItem) {
        guard case .nexus(let link) = item.source else { return }
        if let expires = link.expires.flatMap(TimeInterval.init), Date(timeIntervalSince1970: expires) < .now,
           nexusUser?.isPremium != true {
            // Free accounts need a fresh one-time link from the website.
            item.phase = .paused("The Nexus Mods link expired. Click Mod Manager Download on the mod's Files page to continue — it picks up where it left off.")
            NSWorkspace.shared.open(NexusClient.filesPageURL(modID: link.modID))
            return
        }
        let resumeLink = (nexusUser?.isPremium == true && link.key == nil) ? NXMLink(modID: link.modID, fileID: link.fileID) : link
        Task { await download(item, link: resumeLink) }
    }

    /// Resumes downloads that were still running when the app last quit.
    func resumePendingDownloads() {
        for item in items where item.isPaused { resume(item) }
    }

    /// Removes the item from the library. Downloads this app made are deleted with it.
    func remove(_ item: DownloadItem, deleteFile: Bool = true) {
        item.downloadTask?.cancel()
        if let partial = item.partialURL { try? FileManager.default.removeItem(at: partial) }
        let folder = item.unpackedFolder
        let archive = item.archiveURL
        let ownsArchive = archive.map { $0.path.hasPrefix(downloadsFolder.path) } ?? false
        Task.detached {
            if let folder { try? FileManager.default.removeItem(at: folder) }
            if deleteFile, ownsArchive, let archive { try? FileManager.default.trashItem(at: archive, resultingItemURL: nil) }
        }
        items.removeAll { $0.id == item.id }
        saveLibrary()
    }

    // MARK: Installing from the library

    /// Installs (or reinstalls) a library item, unpacking it first if needed. Mods with optional
    /// components open the options window, pre-filled with the last choices.
    func install(_ item: DownloadItem, chooseOptions: Bool = false) {
        if item.phase == .ready, item.packages.count == 1, item.packages[0].canInstall {
            decideInstall(item, userRequested: true, chooseOptions: chooseOptions)
        } else if item.archiveURL != nil {
            Task { await unpack(item, userRequested: true, chooseOptions: chooseOptions) }
        }
    }

    /// The library item that installed `mod`'s folder, if it's still in the library.
    func libraryItem(for mod: InstalledMod, game: LEGame) -> DownloadItem? {
        items(for: game).first { item in
            item.archiveURL != nil && item.dlcFolders.contains { $0.caseInsensitiveCompare(mod.dlcName) == .orderedSame }
        }
    }

    /// Reopens the options window for an installed mod and reinstalls it with the new choices.
    func changeOptions(for mod: InstalledMod, game: LEGame) {
        guard let item = libraryItem(for: mod, game: game) else {
            library.errorMessage = "\(mod.displayName) isn't in your library, so its options can't be changed here. Download it again, then use Change Options."
            return
        }
        install(item, chooseOptions: true)
    }

    // MARK: Options window

    private func requestOptions(for package: ModPackage, item: DownloadItem) {
        let request = OptionsRequest(item: item, package: package)
        item.phase = .ready
        item.attentionReasons = ["Choose this mod's options to install it."]
        if optionsRequest == nil {
            optionsRequest = request
        } else if !pendingOptionRequests.contains(where: { $0.item.id == item.id }) && optionsRequest?.item.id != item.id {
            pendingOptionRequests.append(request)
        }
    }

    /// Called by the options window: install with these choices.
    func confirmOptions(_ request: OptionsRequest, choices: [String: Bool]) {
        request.item.chosenOptions = choices
        install(request.package, from: request.item, choices: choices)
        installLauncherAddOns(of: request.item, besides: request.package)
    }

    /// Called once the options window has closed (installed or cancelled): show the next one.
    func optionsWindowClosed() {
        Task { @MainActor in
            guard optionsRequest == nil, !pendingOptionRequests.isEmpty else { return }
            optionsRequest = pendingOptionRequests.removeFirst()
        }
    }

    // MARK: Pipeline

    private func download(_ item: DownloadItem, link: NXMLink) async {
        guard let apiKey = NexusKeychain.load() else {
            item.phase = .failed("Connect your Nexus Mods account first (bottom of the sidebar), then click Retry.")
            return
        }
        if link.gameDomain != NexusClient.legendaryEditionDomain {
            item.phase = .failed("This link is for a different game on Nexus Mods (\(link.gameDomain)).")
            return
        }
        do {
            item.phase = .fetchingInfo
            item.status = "Getting mod details…"
            async let mod = try? NexusClient.modInfo(for: link, apiKey: apiKey)
            async let file = try? NexusClient.fileInfo(for: link, apiKey: apiKey)
            let (modInfo, fileInfo) = await (mod, file)
            if let name = modInfo?.name { item.title = name }
            item.subtitle = [fileInfo?.name, fileInfo?.version.map { "v\($0)" }, modInfo?.author.map { "by \($0)" }]
                .compactMap(\.self).joined(separator: " · ")
            item.imageURL = modInfo?.pictureURL
            item.bytesExpected = fileInfo?.sizeInBytes ?? 0

            let url = try await NexusClient.downloadURL(for: link, apiKey: apiKey)
            item.phase = .downloading
            item.status = nil
            let fileName = fileInfo?.fileName ?? url.lastPathComponent
            item.archiveURL = try await downloadFile(from: url, named: fileName, for: item)
            item.partialURL = nil
            item.destinationURL = nil
            savePendingDownloads()
            saveLibrary()
            await unpack(item, userRequested: false)
        } catch {
            if item.isFailed { return } // cancelled
            if item.partialURL != nil {
                // Keep what's downloaded; Resume (or relaunching) continues from here.
                item.phase = .paused("Download stopped: \(error.localizedDescription)")
                savePendingDownloads()
            } else {
                item.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Streams the download straight into the downloads folder on the game's drive (a download
    /// task would stage the whole file in the Mac's temporary folder first). Written as `.part`
    /// and renamed when complete, so an interrupted download is never mistaken for a finished
    /// archive; an existing `.part` is continued with an HTTP range request.
    private func downloadFile(from url: URL, named fileName: String, for item: DownloadItem) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: downloadsFolder, withIntermediateDirectories: true)
        let destination = item.destinationURL ?? Self.uniqueURL(for: fileName, in: downloadsFolder)
        let partial = item.partialURL ?? destination.appendingPathExtension("part")
        item.destinationURL = destination
        item.partialURL = partial
        savePendingDownloads()

        let offset = (try? fm.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        item.lastSample = nil
        item.bytesPerSecond = 0
        let expectedFromNexus = item.bytesExpected
        try await FileDownloader.download(from: url, to: partial, resumingFrom: offset, onStart: { task in
            Task { @MainActor in item.downloadTask = task }
        }, onProgress: { received, reported in
            Task { @MainActor in
                item.recordProgress(received: received)
                // Prefer the server's length; otherwise use the size Nexus Mods reported.
                if reported > 0 { item.bytesExpected = reported } else if item.bytesExpected == 0 { item.bytesExpected = expectedFromNexus }
                item.progress = item.bytesExpected > 0 ? min(Double(received) / Double(item.bytesExpected), 1) : nil
            }
        })
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: partial, to: destination)
        return destination
    }

    // MARK: Unfinished downloads

    private struct PendingDownload: Codable {
        let id: UUID
        let modID: Int
        let fileID: Int
        let key: String?
        let expires: String?
        let title: String
        let subtitle: String?
        let imageURL: URL?
        let partialPath: String
        let destinationPath: String
        let bytesExpected: Int64
        let addedAt: Date
    }

    private static var pendingFile: URL {
        URL.applicationSupportDirectory.appending(path: "LEModManager/Downloads.json")
    }

    private func savePendingDownloads() {
        let pending = items.compactMap { item -> PendingDownload? in
            guard case .nexus(let link) = item.source, let partial = item.partialURL, let destination = item.destinationURL else { return nil }
            return PendingDownload(
                id: item.id, modID: link.modID, fileID: link.fileID, key: link.key, expires: link.expires,
                title: item.title, subtitle: item.subtitle, imageURL: item.imageURL,
                partialPath: partial.path, destinationPath: destination.path,
                bytesExpected: item.bytesExpected, addedAt: item.addedAt
            )
        }
        try? FileManager.default.createDirectory(at: Self.pendingFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(pending).write(to: Self.pendingFile, options: .atomic)
    }

    private func loadPendingDownloads() {
        guard let data = try? Data(contentsOf: Self.pendingFile),
              let pending = try? JSONDecoder().decode([PendingDownload].self, from: data) else { return }
        for entry in pending where !items.contains(where: { $0.id == entry.id }) {
            let link = NXMLink(modID: entry.modID, fileID: entry.fileID, key: entry.key, expires: entry.expires)
            let item = DownloadItem(id: entry.id, source: .nexus(link), title: entry.title, addedAt: entry.addedAt)
            item.subtitle = entry.subtitle
            item.imageURL = entry.imageURL
            item.partialURL = URL(filePath: entry.partialPath)
            item.destinationURL = URL(filePath: entry.destinationPath)
            item.bytesExpected = entry.bytesExpected
            item.bytesReceived = (try? FileManager.default.attributesOfItem(atPath: entry.partialPath)[.size] as? Int64) ?? 0
            item.progress = entry.bytesExpected > 0 ? Double(item.bytesReceived) / Double(entry.bytesExpected) : nil
            item.phase = .paused("Resuming…")
            items.insert(item, at: 0)
        }
    }

    @discardableResult
    private func unpack(_ item: DownloadItem, userRequested: Bool, chooseOptions: Bool = false, decide: Bool = true) async -> Bool {
        guard let archive = item.archiveURL else { return false }
        guard FileManager.default.fileExists(atPath: archive.path) else {
            item.phase = .failed("The downloaded file is no longer at \(archive.path).")
            return false
        }
        item.phase = .unpacking
        item.progress = nil
        item.status = "Unpacking…"
        do {
            let folder: URL
            if PathResolver.isDirectory(archive) {
                folder = archive
            } else {
                folder = try await ArchiveExtractor.extract(archive, into: unpackFolder)
                item.unpackedFolder = folder
            }
            item.status = "Reading mod information…"
            let results = await ModService.findMods(in: folder)
            let packages = results.compactMap { try? $0.get() }
            guard !packages.isEmpty else {
                let failure = results.compactMap { result -> String? in
                    if case .failure(let error) = result { return error.localizedDescription }
                    return nil
                }.first
                item.phase = .failed(failure ?? "This download isn't packaged for ME3Tweaks Mod Manager (it has no moddesc.ini), so it can't be installed automatically.")
                return false
            }
            item.packages = packages
            item.installedPackageIDs = []
            item.game = packages.compactMap(\.game).first
            if item.dlcFolders.isEmpty || item.installedAt == nil {
                // Until it's installed, assume the base folders; the install records the real ones.
                item.dlcFolders = packages.flatMap { $0.jobs.map(\.destinationName) }
            }
            if item.subtitle == nil || item.subtitle?.isEmpty == true, packages.count == 1 {
                let package = packages[0]
                item.title = package.name
                item.subtitle = [package.version.isEmpty ? nil : "v\(package.version)", "by \(package.developer)"]
                    .compactMap(\.self).joined(separator: " · ")
            }
            item.status = nil
            saveLibrary()
            if decide { decideInstall(item, userRequested: userRequested, chooseOptions: chooseOptions) }
            return true
        } catch {
            item.phase = .failed(error.localizedDescription)
            return false
        }
    }

    /// Installs straight away when there's exactly one installable mod and nothing needs a decision.
    /// Mods with choices open the options window. A missing required mod makes the item wait:
    /// the requirement is installed first if it's in the library, and the item installs itself
    /// once it's in. Warnings alone don't stop an install the user asked for.
    private func decideInstall(_ item: DownloadItem, userRequested: Bool, chooseOptions: Bool = false) {
        let installable = item.packages.filter(\.canInstall)
        // Launcher add-ons (e.g. the LE2 Patch's launcher video fix) install along with the main mod.
        let primary = installable.filter { !$0.targetsLauncher }
        var blockers: [String] = []
        var warnings: [String] = []
        item.waitingFor = []
        if installable.isEmpty {
            blockers.append(item.packages.first?.blockingIssues.first ?? "This mod can't be installed.")
        } else if primary.count > 1 || (primary.isEmpty && installable.count > 1) {
            blockers.append("This download contains \(item.packages.count) mods. Choose which to install.")
        } else {
            let package = primary.first ?? installable[0]
            warnings += package.warnings
            if let game = package.game, !library.isInstalled(game) {
                blockers.append("\(game.displayName) isn't installed in your game folder.")
            }
            let missing = library.missingRequirements(for: package)
            if !missing.isEmpty {
                item.waitingFor = missing
                item.attentionReasons = []
                lookUpRequirements(missing, game: package.game)
                item.phase = .ready
                installRequirements(missing, for: package.game)
                return
            }
            let incompatible = library.incompatibilities(for: package)
            if !incompatible.isEmpty { warnings.append("Incompatible with installed \(incompatible.joined(separator: ", ")).") }
        }
        item.attentionReasons = blockers + warnings
        item.phase = .ready
        guard blockers.isEmpty, let package = primary.first ?? installable.first else { return }
        let automatic = UserDefaults.standard.bool(forKey: Self.autoInstallKey) && warnings.isEmpty
        guard userRequested || automatic || chooseOptions else { return }
        if package.hasChoices {
            requestOptions(for: package, item: item)
        } else {
            install(package, from: item, choices: item.chosenOptions)
            installLauncherAddOns(of: item, besides: package)
        }
    }

    /// Queues the item's launcher mods that come with `main` (and aren't installed yet).
    private func installLauncherAddOns(of item: DownloadItem, besides main: ModPackage) {
        guard !main.targetsLauncher else { return }
        for addOn in item.packages where addOn.targetsLauncher && addOn.canInstall && !item.installedPackageIDs.contains(addOn.id) {
            install(addOn, from: item, choices: [:])
        }
    }

    /// Starts installing library items that provide the given DLC folders.
    private func installRequirements(_ names: [String], for game: LEGame?) {
        for name in names {
            let provider = items.first { candidate in
                candidate.game == game && !isInstalled(candidate) && !candidate.isActive && !candidate.isFailed && candidate.waitingFor.isEmpty
                    && candidate.dlcFolders.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            }
            if let provider { install(provider) }
        }
    }

    /// Mod names for required DLC folders, from ME3Tweaks' mod directory (e.g. DLC_MOD_LE2PATCH →
    /// "Unofficial LE2 Patch"). Filled in as lookups complete.
    private(set) var requirementInfo: [String: ModDirectory.Entry] = [:]

    func lookUpRequirements(_ names: [String], game: LEGame?) {
        guard let game else { return }
        for name in names where requirementInfo[name.lowercased()] == nil {
            Task {
                if let entry = await ModDirectory.entry(for: name, game: game) {
                    requirementInfo[name.lowercased()] = entry
                }
            }
        }
    }

    /// Whether a required DLC folder is already on its way (downloading or installing).
    func isComing(_ name: String, game: LEGame?) -> Bool {
        let nexusID = requirementInfo[name.lowercased()]?.nexusModID
        return items.contains { item in
            item.isActive && (item.dlcFolders.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
                || (nexusID != nil && item.nexusModID == nexusID))
        }
    }

    /// Gets a required mod: installs it from the library if it's there, otherwise downloads it
    /// (Premium) or opens its Nexus Mods Files page for "Mod Manager Download" (free accounts).
    /// Whatever was waiting for it installs itself afterwards.
    func getRequirement(_ name: String, game: LEGame?) async {
        if let provider = items.first(where: { $0.game == game && !isInstalled($0) && $0.dlcFolders.contains { $0.caseInsensitiveCompare(name) == .orderedSame } && $0.archiveURL != nil }) {
            install(provider)
            return
        }
        guard let game else { return }
        let entry: ModDirectory.Entry?
        if let cached = requirementInfo[name.lowercased()] {
            entry = cached
        } else {
            entry = await ModDirectory.entry(for: name, game: game)
            if let entry { requirementInfo[name.lowercased()] = entry }
        }
        guard let modID = entry?.nexusModID else {
            library.errorMessage = "Couldn't find where to download \(entry?.name ?? name). Search for it on Nexus Mods and click Mod Manager Download."
            return
        }
        if nexusUser?.isPremium == true, let apiKey = NexusKeychain.load(),
           let file = Self.newestMatchingFile(in: (try? await NexusClient.files(modID: modID, apiKey: apiKey)) ?? [], installedFileID: nil, game: game) {
            startDownload(NXMLink(modID: modID, fileID: file.fileID), title: entry?.name)
        } else {
            NSWorkspace.shared.open(NexusClient.filesPageURL(modID: modID))
        }
    }

    /// After an install, items waiting for a requirement check again.
    private func recheckWaitingItems() {
        for item in items where !item.waitingFor.isEmpty && item.phase == .ready {
            decideInstall(item, userRequested: true)
        }
    }

    /// Queues an install. Installs run one at a time because they share the game's merged files.
    func install(_ package: ModPackage, from item: DownloadItem, choices: [String: Bool]? = nil) {
        item.phase = .installing
        item.status = "Waiting for other installs…"
        installQueue.append((item, package, choices ?? item.chosenOptions))
        Task { await processInstallQueue() }
    }

    private func processInstallQueue() async {
        guard !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }
        while !installQueue.isEmpty {
            let (item, package, choices) = installQueue.removeFirst()
            await installNow(package, from: item, choices: choices)
            recheckWaitingItems()
        }
    }

    /// Installs one package of `item` right away and records the result on the item.
    /// Returns the error message if it failed.
    @discardableResult
    private func installNow(_ package: ModPackage, from item: DownloadItem, choices: [String: Bool]) async -> String? {
        item.phase = .installing
        item.status = "Installing into \(package.game?.displayName ?? "the game")…"
        defer { item.status = nil }
        let previousFolders = item.installedAt != nil && !package.targetsLauncher ? item.dlcFolders : []
        switch await library.install(package, choices: choices, replacing: previousFolders) {
            case .failure(let error):
                item.phase = .failed(error.message)
                return error.message
            case .success(let result):
                if !package.targetsLauncher {
                    // Launcher add-ons have no options or DLC folders; keep the main mod's.
                    item.chosenOptions = choices
                    item.dlcFolders = result.dlcFolders
                }
                item.waitingFor = []
                item.installedPackageIDs.insert(package.id)
                item.installedAt = .now
                item.attentionReasons = []
                let remaining = item.packages.filter { $0.canInstall && !item.installedPackageIDs.contains($0.id) }
                item.phase = remaining.isEmpty ? .installed : .ready
                if remaining.isEmpty, let folder = item.unpackedFolder {
                    // The archive stays in the library for reinstalling; the unpacked copy isn't needed.
                    item.unpackedFolder = nil
                    Task.detached { try? FileManager.default.removeItem(at: folder) }
                }
                updates.removeValue(forKey: item.dlcFolders.first?.lowercased() ?? "")
                saveLibrary()
                return nil
        }
    }

    // MARK: Updates

    /// Compares installed mods that came from Nexus Mods with the newest version of the same file.
    /// One Nexus page can hold separate files per game (e.g. "Kasumi Eye Tweak (LE2)" v1.2 and
    /// "(LE3)" v1.1), so the mod page's overall version isn't used. When the right file can't be
    /// identified, no update is reported rather than a false one.
    func checkForUpdates() async {
        guard let apiKey = NexusKeychain.load(), !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }
        var found: [String: ModUpdate] = [:]
        var filesByMod: [Int: [NexusClient.ModFile]] = [:]
        for game in LEGame.allCases {
            for mod in library.mods[game] ?? [] {
                guard let modID = mod.meta?.nexusUpdateCode, modID > 0, !mod.version.isEmpty else { continue }
                if filesByMod[modID] == nil {
                    filesByMod[modID] = (try? await NexusClient.files(modID: modID, apiKey: apiKey)) ?? []
                }
                let installedFileID: Int? = {
                    if case .nexus(let link) = libraryItem(for: mod, game: game)?.source { return link.fileID }
                    return nil
                }()
                guard let latest = Self.newestMatchingFile(in: filesByMod[modID] ?? [], installedFileID: installedFileID, game: game),
                      let latestVersion = latest.version, Self.isNewer(latestVersion, than: mod.version) else { continue }
                found[mod.dlcName.lowercased()] = ModUpdate(modID: modID, fileID: latest.fileID, installedVersion: mod.version, latestVersion: latestVersion)
            }
        }
        updates = found
    }

    /// The newest main file in the same "line" as the installed one: same file name as the file
    /// that was downloaded, else the one main file tagged for this game, else the only main file.
    nonisolated static func newestMatchingFile(in files: [NexusClient.ModFile], installedFileID: Int?, game: LEGame) -> NexusClient.ModFile? {
        let main = files.filter { $0.categoryName?.uppercased() == "MAIN" }
        func normalized(_ name: String?) -> String { (name ?? "").lowercased().trimmingCharacters(in: .whitespaces) }
        func newest(_ candidates: [NexusClient.ModFile]) -> NexusClient.ModFile? {
            candidates.max { ($0.uploadedTimestamp ?? 0) < ($1.uploadedTimestamp ?? 0) }
        }
        if let installedFileID, let installed = files.first(where: { $0.fileID == installedFileID }) {
            return newest(main.filter { normalized($0.name) == normalized(installed.name) })
        }
        let tags: [LEGame: [String]] = [
            .le1: ["le1", "me1", "mele1", "me1le", "mass effect 1", "mass effect legendary edition 1"],
            .le2: ["le2", "me2", "mele2", "me2le", "mass effect 2"],
            .le3: ["le3", "me3", "mele3", "me3le", "mass effect 3"],
        ]
        func tagged(_ file: NexusClient.ModFile, _ game: LEGame) -> Bool {
            let name = normalized(file.name)
            return (tags[game] ?? []).contains { tag in
                name.range(of: "(^|[^a-z0-9])\(tag)([^a-z0-9]|$)", options: .regularExpression) != nil
            }
        }
        let otherGames = LEGame.allCases.filter { $0 != game }
        let forThisGame = main.filter { file in tagged(file, game) && !otherGames.contains { tagged(file, $0) } }
        if !forThisGame.isEmpty {
            // Several tagged lines (e.g. different variants) can't be told apart safely.
            let names = Set(forThisGame.map { normalized($0.name) })
            return names.count == 1 ? newest(forThisGame) : nil
        }
        let names = Set(main.map { normalized($0.name) })
        return names.count == 1 ? newest(main) : nil
    }

    /// Premium accounts download the newer file directly; free accounts are sent to the mod's
    /// Files page to click "Mod Manager Download", which comes back here.
    func downloadUpdate(_ update: ModUpdate) async {
        if nexusUser?.isPremium == true {
            startDownload(NXMLink(modID: update.modID, fileID: update.fileID))
        } else {
            NSWorkspace.shared.open(NexusClient.filesPageURL(modID: update.modID))
        }
    }

    nonisolated static func isNewer(_ latest: String, than installed: String) -> Bool {
        let clean: (String) -> String = { $0.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")) }
        return clean(latest).compare(clean(installed), options: .numeric) == .orderedDescending
    }

    // MARK: Library persistence

    private struct LibraryEntry: Codable {
        let id: UUID
        let title: String
        let subtitle: String?
        let imageURL: URL?
        let archivePath: String
        let addedAt: Date
        let game: String?
        let dlcFolders: [String]
        let installedAt: Date?
        let nexusModID: Int?
        let nexusFileID: Int?
        var chosenOptions: [String: Bool]?
    }

    private func saveLibrary() {
        let entries = items.compactMap { item -> LibraryEntry? in
            guard let archive = item.archiveURL, !item.isFailed else { return nil }
            var fileID: Int?
            if case .nexus(let link) = item.source { fileID = link.fileID }
            return LibraryEntry(
                id: item.id, title: item.title, subtitle: item.subtitle, imageURL: item.imageURL,
                archivePath: archive.path, addedAt: item.addedAt, game: item.game?.rawValue,
                dlcFolders: item.dlcFolders, installedAt: item.installedAt,
                nexusModID: item.nexusModID, nexusFileID: fileID,
                chosenOptions: item.chosenOptions.isEmpty ? nil : item.chosenOptions
            )
        }
        do {
            try FileManager.default.createDirectory(at: Self.libraryFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: Self.libraryFile, options: .atomic)
        } catch {
            library.errorMessage = "Couldn't save the mod library: \(error.localizedDescription)"
        }
    }

    private func loadLibrary() {
        guard let data = try? Data(contentsOf: Self.libraryFile),
              let entries = try? JSONDecoder().decode([LibraryEntry].self, from: data) else { return }
        items = entries.compactMap { entry in
            let archive = URL(filePath: entry.archivePath)
            guard FileManager.default.fileExists(atPath: archive.path) else { return nil }
            let source: DownloadItem.Source = if let modID = entry.nexusModID, let fileID = entry.nexusFileID {
                .nexus(NXMLink(modID: modID, fileID: fileID))
            } else {
                .file(archive)
            }
            let item = DownloadItem(id: entry.id, source: source, title: entry.title, addedAt: entry.addedAt)
            item.subtitle = entry.subtitle
            item.imageURL = entry.imageURL
            item.archiveURL = archive
            item.game = entry.game.flatMap(LEGame.init(rawValue:))
            item.dlcFolders = entry.dlcFolders
            item.installedAt = entry.installedAt
            item.chosenOptions = entry.chosenOptions ?? [:]
            item.phase = .stored
            return item
        }
    }

    // MARK: ~/Downloads watcher

    /// Picks up mod archives downloaded manually (e.g. with "Manual Download" on Nexus Mods).
    func startWatchingDownloadsFolder() {
        guard downloadsWatcher == nil, UserDefaults.standard.bool(forKey: Self.watchDownloadsKey) else { return }
        let fd = open(URL.downloadsDirectory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in await self?.scanDownloadsFolder() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        downloadsWatcher = source
        Task { await scanDownloadsFolder() }
    }

    func stopWatchingDownloadsFolder() {
        downloadsWatcher?.cancel()
        downloadsWatcher = nil
    }

    /// Adds recent archives in ~/Downloads that contain a moddesc.ini and haven't been seen before.
    private func scanDownloadsFolder() async {
        let candidates = await Self.recentArchives(in: URL.downloadsDirectory)
        var seen = Set(UserDefaults.standard.stringArray(forKey: Self.seenArchivesKey) ?? [])
        for (url, signature) in candidates where !seen.contains(signature) {
            seen.insert(signature)
            if await ArchiveExtractor.containsModdesc(url) {
                add(fileURL: url)
            }
        }
        UserDefaults.standard.set(Array(seen.suffix(500)), forKey: Self.seenArchivesKey)
    }

    /// Archives modified in the last day whose size has stopped changing (i.e. finished downloading).
    @concurrent
    private static func recentArchives(in folder: URL) async -> [(URL, String)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        let cutoff = Date.now.addingTimeInterval(-24 * 60 * 60)
        var results: [(URL, String)] = []
        for file in files where ArchiveExtractor.supportedExtensions.contains(file.pathExtension.lowercased()) {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  let modified = values.contentModificationDate, modified > cutoff,
                  let size = values.fileSize, size > 0 else { continue }
            // Skip files still being written.
            try? await Task.sleep(for: .milliseconds(300))
            guard (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) == size else { continue }
            results.append((file, "\(file.path)|\(size)"))
        }
        return results
    }

    // MARK: Helpers

    private static func uniqueURL(for fileName: String, in folder: URL) -> URL {
        let safeName = fileName.replacingOccurrences(of: "/", with: "-")
        var candidate = folder.appending(path: safeName)
        let base = (safeName as NSString).deletingPathExtension
        let ext = (safeName as NSString).pathExtension
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}

/// Writes an HTTP download to a file as data arrives, reporting bytes received and the expected
/// length (0 if the server doesn't say).
nonisolated private final class FileDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var expected: Int64 = 0
    private var lastReport = Date.distantPast
    private var continuation: CheckedContinuation<Void, Error>?

    private let resumeOffset: Int64

    private init(destination: URL, resumeOffset: Int64, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.resumeOffset = resumeOffset
        self.onProgress = onProgress
    }

    static func download(
        from url: URL,
        to destination: URL,
        resumingFrom offset: Int64 = 0,
        onStart: @escaping @Sendable (URLSessionTask) -> Void,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let downloader = FileDownloader(destination: destination, resumeOffset: offset, onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: downloader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        try await withCheckedThrowingContinuation { continuation in
            downloader.continuation = continuation
            let task = session.dataTask(with: request)
            onStart(task)
            task.resume()
        }
    }

    private var refusedStatus: Int?
    /// The server said the requested range is past the end: the .part file is already complete.
    private var alreadyComplete = false

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 416, resumeOffset > 0 {
            alreadyComplete = true
            return .cancel
        }
        guard (200..<300).contains(status) else {
            refusedStatus = status
            return .cancel
        }
        let length = max(response.expectedContentLength, 0)
        if status == 206, resumeOffset > 0, let handle = try? FileHandle(forWritingTo: destination) {
            // Continue the partial file.
            _ = try? handle.seekToEnd()
            self.handle = handle
            received = resumeOffset
            expected = length > 0 ? resumeOffset + length : 0
        } else {
            // Fresh download (or the server ignored the range): start the file over.
            guard FileManager.default.createFile(atPath: destination.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: destination) else { return .cancel }
            self.handle = handle
            received = 0
            expected = length
        }
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
        } catch {
            dataTask.cancel()
            finish(error)
            return
        }
        received += Int64(data.count)
        // Throttle UI updates to a few per second.
        if Date.now.timeIntervalSince(lastReport) > 0.2 {
            lastReport = .now
            onProgress(received, expected)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if alreadyComplete {
            finish(nil)
            return
        }
        if let refusedStatus {
            // We cancelled because the server answered with an error.
            finish(NexusClient.NexusError(message: "The download server refused the file (HTTP \(refusedStatus)). Try the download again from Nexus Mods."))
            return
        }
        onProgress(received, expected)
        finish(error)
    }

    private func finish(_ error: Error?) {
        try? handle?.close()
        handle = nil
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

/// Steps of a Rebuild Mods run, for its progress window.
@Observable
final class RebuildProgress: Identifiable {
    enum Status: Equatable {
        case waiting, working, done
        case failed(String)
    }

    struct Step: Identifiable {
        let id = UUID()
        let title: String
        var status: Status = .waiting
    }

    let id = UUID()
    let game: LEGame
    var steps: [Step]
    var isFinished = false

    init(game: LEGame, steps: [String]) {
        self.game = game
        self.steps = steps.map { Step(title: $0) }
    }

    var failures: Int { steps.filter { if case .failed = $0.status { true } else { false } }.count }

    func start(_ index: Int) { steps[index].status = .working }
    func finish(_ index: Int) { steps[index].status = .done }
    func fail(_ index: Int, _ message: String) { steps[index].status = .failed(message) }
}
