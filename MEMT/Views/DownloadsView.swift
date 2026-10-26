import SwiftUI

/// Downloads only: files being fetched from Nexus Mods (or that failed to download). As soon as a
/// download finishes and its game is known, it moves to that game's page, where it's unpacked and installed.
struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloads
    @Binding var isAddingMods: Bool
    @Binding var isConnectingNexus: Bool

    private var downloading: [DownloadItem] { downloads.items.filter(\.isDownloadStage) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if !downloads.hasAPIKey {
                    ConnectNexusCard(isConnectingNexus: $isConnectingNexus)
                }
                if downloading.isEmpty {
                    emptyState
                } else {
                    section("Downloading", tint: MEStyle.allianceBlue, items: downloading)
                }
                if downloads.items.contains(where: { !$0.isDownloadStage }) {
                    finishedNote
                }
            }
            .padding(24)
        }
        .navigationTitle("Downloads")
        .toolbar {
            ToolbarItem {
                Button("Add Mod…", systemImage: "plus") { isAddingMods = true }
            }
            ToolbarItem {
                Button("Show Downloads Folder", systemImage: "folder") {
                    let folder = downloads.downloadsFolder
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(folder)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Requisitions").meLabel().foregroundStyle(MEStyle.n7Red)
                Text("Downloads").meHeading(size: 26)
                Text("Mods download here, then move to their game's page to be unpacked and installed.")
                    .foregroundStyle(.white.opacity(0.75))
                N7Stripe()
            }
            Spacer()
            RelayEmblem(size: 90)
        }
        .padding(22)
        .background {
            ZStack {
                SpaceBackdrop(tint: MEStyle.n7Red)
                ScanLines()
            }
            .clipShape(.rect(cornerRadius: 16))
        }
    }

    private func section(_ title: String, tint: Color, items: [DownloadItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, tint: tint)
            ForEach(items) { DownloadCard(item: $0) }
        }
    }

    /// Where finished downloads went.
    private var finishedNote: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
            Text("Finished downloads are on each game's page: Mass Effect, Mass Effect 2 and Mass Effect 3 in the sidebar.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MEStyle.panel, in: .rect(cornerRadius: 12))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
            Text("Nothing downloading").font(.title3.bold())
            Text("Find a mod on Nexus Mods, open its **Files** tab and click **Mod Manager Download**. It downloads here and installs into the right game. Mods you save to your Downloads folder show up here too.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
            Link("Browse Mass Effect Legendary Edition Mods", destination: NexusClient.legendaryEditionModsURL)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: Cards

struct DownloadCard: View {
    @Environment(DownloadManager.self) private var downloads
    let item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                ModThumbnail(url: item.imageURL, game: item.game, width: 96, height: 60)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(item.title).font(.headline).lineLimit(2)
                        if let game = item.game {
                            GameChip(game: game)
                        }
                    }
                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    phaseView
                }
                Spacer(minLength: 0)
                actions
            }

            if item.phase == .ready, !item.waitingFor.isEmpty {
                ForEach(item.waitingFor, id: \.self) { name in
                    RequirementRow(name: name, game: item.game)
                }
            }

            if item.phase == .ready {
                ForEach(item.attentionReasons, id: \.self) { reason in
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(MEStyle.omniOrange)
                }
                if item.packages.count > 1 || !item.attentionReasons.isEmpty {
                    ForEach(item.packages) { package in
                        PackageSummary(item: item, package: package)
                    }
                }
            }
        }
        .padding(16)
        .background(MEStyle.panel, in: .rect(cornerRadius: 14))
        .overlay(alignment: .leading) {
            if let game = item.game {
                UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14)
                    .fill(MEStyle.tint(for: game))
                    .frame(width: 4)
            }
        }
    }

    @ViewBuilder
    private var phaseView: some View {
        switch item.phase {
        case .stored:
            Text(downloads.isInstalled(item) ? "Installed" : "Not installed")
                .font(.caption.weight(.medium))
                .foregroundStyle(downloads.isInstalled(item) ? .green : .secondary)
        case .fetchingInfo, .unpacking, .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(item.status ?? "Working…").font(.caption).foregroundStyle(.secondary)
            }
        case .paused(let message):
            VStack(alignment: .leading, spacing: 4) {
                if let progress = item.progress {
                    ProgressView(value: progress).tint(.secondary)
                }
                Text(sizeText).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Label(message, systemImage: "pause.circle.fill")
                    .font(.caption)
                    .foregroundStyle(MEStyle.omniOrange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 420, alignment: .leading)
        case .downloading:
            VStack(alignment: .leading, spacing: 4) {
                if let progress = item.progress {
                    ProgressView(value: progress).tint(item.game.map(MEStyle.tint(for:)) ?? .accentColor)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(sizeText).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .frame(maxWidth: 360)
        case .ready:
            Text(item.attentionReasons.isEmpty ? "Ready to install" : "Waiting for you")
                .font(.caption.weight(.medium))
                .foregroundStyle(item.attentionReasons.isEmpty ? Color.secondary : MEStyle.omniOrange)
        case .installed:
            Label("Installed into \(item.game?.displayName ?? "the game")", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            switch item.phase {
            case .paused:
                Button("Resume") { downloads.resume(item) }
                    .buttonStyle(.glassProminent)
                Button("Cancel") { downloads.cancel(item) }
                    .buttonStyle(.glass)
                    .tint(.white.opacity(0.12))
            case .downloading, .fetchingInfo:
                Button("Cancel") { downloads.cancel(item) }
                    .buttonStyle(.glass)
                    .tint(.white.opacity(0.12))
            case .stored, .installed:
                if item.archiveURL != nil {
                    Button(downloads.isInstalled(item) ? "Reinstall" : "Install") { downloads.install(item) }
                        .buttonStyle(downloads.isInstalled(item) ? AnyPrimitiveButtonStyle(.glass) : AnyPrimitiveButtonStyle(.glassProminent))
                }
            case .failed:
                Button("Retry") { downloads.retry(item) }
                    .buttonStyle(.glassProminent)
            case .ready where item.packages.count == 1 && item.attentionReasons.isEmpty:
                Button("Install") { downloads.install(item) }
                    .buttonStyle(.glassProminent)
            default:
                EmptyView()
            }
            Menu {
                if let archive = item.archiveURL {
                    Button("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([archive])
                    }
                }
                if let modID = item.nexusModID {
                    Button("Open on Nexus Mods", systemImage: "safari") {
                        NSWorkspace.shared.open(NexusClient.filesPageURL(modID: modID))
                    }
                }
                Divider()
                Button("Remove from Library", systemImage: "trash", role: .destructive) { downloads.remove(item) }
                    .disabled(item.phase == .installing)
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var sizeText: String {
        let received = ByteCountFormatter.string(fromByteCount: item.bytesReceived, countStyle: .file)
        var parts = [item.bytesExpected > 0
            ? "\(received) of \(ByteCountFormatter.string(fromByteCount: item.bytesExpected, countStyle: .file))"
            : received]
        if item.phase == .downloading, item.bytesPerSecond > 1 {
            parts.append("\(ByteCountFormatter.string(fromByteCount: Int64(item.bytesPerSecond), countStyle: .file))/s")
        }
        if let seconds = item.secondsRemaining {
            parts.append(Self.timeLeft(seconds))
        }
        return parts.joined(separator: " · ")
    }

    private static func timeLeft(_ seconds: Double) -> String {
        if seconds < 60 { return "less than a minute left" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.maximumUnitCount = 2
        return "about \(formatter.string(from: seconds) ?? "") left"
    }
}

/// One mod inside a download, shown when the user needs to choose or confirm.
private struct PackageSummary: View {
    @Environment(ModLibrary.self) private var library
    @Environment(DownloadManager.self) private var downloads
    let item: DownloadItem
    let package: ModPackage

    var body: some View {
        let isDone = item.installedPackageIDs.contains(package.id)
        let gameMissing = package.game.map { !library.isInstalled($0) } ?? true

        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(package.name).font(.subheadline.bold())
                    if let game = package.game { GameChip(game: game) }
                }
                if !package.description.isEmpty {
                    Text(package.description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                if !package.asiMods.isEmpty {
                    Label("Also installs \(package.asiMods.count == 1 ? "an ASI mod" : "\(package.asiMods.count) ASI mods") from ME3Tweaks", systemImage: "puzzlepiece.extension")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if package.modifiesBasegame {
                    Label("Changes game files (backed up first)", systemImage: "externaldrive.badge.checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(package.blockingIssues, id: \.self) { issue in
                    Label(issue, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            if isDone {
                Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(package.hasChoices ? "Choose Options…" : "Install Anyway") {
                    if package.hasChoices && item.packages.count == 1 {
                        downloads.install(item, chooseOptions: true)
                    } else {
                        downloads.install(package, from: item)
                    }
                }
                    .buttonStyle(.glass)
                    .disabled(!package.canInstall || gameMissing || item.phase == .installing)
            }
        }
        .padding(12)
        .background(.black.opacity(0.25), in: .rect(cornerRadius: 10))
    }
}

/// A mod this download needs first, with a one-click way to get it.
private struct RequirementRow: View {
    @Environment(DownloadManager.self) private var downloads
    let name: String
    let game: LEGame?

    private var displayName: String { downloads.requirementInfo[name.lowercased()]?.name ?? name }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "link.badge.plus")
                .foregroundStyle(MEStyle.omniOrange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Needs \(displayName) first").font(.callout.weight(.semibold))
                Text(downloads.isComing(name, game: game)
                     ? "Downloading now. This mod installs automatically as soon as it's in."
                     : "This mod installs automatically once \(displayName) is installed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if downloads.isComing(name, game: game) {
                ProgressView().controlSize(.small)
            } else {
                Button("Get \(displayName)") {
                    Task { await downloads.getRequirement(name, game: game) }
                }
                .buttonStyle(.glassProminent)
                .tint(MEStyle.omniOrange)
                .help(downloads.nexusUser?.isPremium == true
                      ? "Downloads and installs it, then this mod."
                      : "Opens its Files page on Nexus Mods. Click Mod Manager Download there.")
            }
        }
        .padding(12)
        .background(MEStyle.omniOrange.opacity(0.12), in: .rect(cornerRadius: 10))
    }
}

struct GameChip: View {
    let game: LEGame

    var body: some View {
        Text(MEStyle.codename(for: game))
            .font(.caption2.weight(.heavy))
            .fontWidth(.expanded)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(MEStyle.tint(for: game).opacity(0.25), in: .capsule)
            .foregroundStyle(MEStyle.tint(for: game))
            .help("For \(game.displayName)")
    }
}

private struct ConnectNexusCard: View {
    @Binding var isConnectingNexus: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "link.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Connect your Nexus Mods account").font(.headline)
                Text("Then the \"Mod Manager Download\" button on Nexus Mods downloads and installs mods here in one click.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Connect") { isConnectingNexus = true }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 14))
    }
}

/// Lets a button switch between glass styles at runtime.
struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
