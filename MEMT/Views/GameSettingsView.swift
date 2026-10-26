import SwiftUI

/// Per-game settings: the launcher's language/voice/subtitles/rumble, and game config values
/// (only the ones this game's config actually has). Changes apply when you press Apply.
struct GameSettingsView: View {
    @Environment(ModLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    let game: LEGame

    @State private var gameValues: [String: String] = [:]   // current values read from the game
    @State private var overrides: [String: String] = [:]    // the user's choices
    @State private var launcher = LauncherSettings()
    @State private var launcherFiles: [URL] = []
    @State private var isLoading = true
    @State private var isApplying = false
    @State private var message: String?

    private var available: [GameTweak] { GameTweak.all.filter { gameValues[$0.id] != nil } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3").font(.title2).foregroundStyle(MEStyle.tint(for: game))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(game.displayName) Settings").meHeading(size: 18)
                    Text("Changes are applied on top of the game's config and kept when mods are reinstalled.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Form {
                Section("Launcher (all three games)") {
                    if launcherFiles.isEmpty {
                        Text("The launcher's settings file appears after the Legendary Edition launcher has run once.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Language", selection: $launcher.language) {
                            ForEach(LauncherSettings.languages, id: \.code) { Text($0.name).tag($0.code) }
                        }
                        Toggle("English voices (with other languages)", isOn: $launcher.englishVoiceOver)
                        Picker("Subtitle size", selection: $launcher.subtitleSize) {
                            ForEach(LauncherSettings.subtitleSizes, id: \.self) { Text("\($0)").tag($0) }
                        }
                        Toggle("Controller rumble", isOn: $launcher.rumble)
                    }
                }

                if isLoading {
                    Section { ProgressView("Reading \(game.displayName)'s config…") }
                } else if available.isEmpty {
                    Section { Text("Couldn't read \(game.displayName)'s config.").foregroundStyle(.secondary) }
                } else {
                    ForEach(["Graphics", "Controls"], id: \.self) { group in
                        let tweaks = available.filter { $0.group == group }
                        if !tweaks.isEmpty {
                            Section(group) {
                                ForEach(tweaks) { tweak in row(for: tweak) }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Reset to Game Defaults") {
                    overrides = [:]
                }
                .disabled(overrides.isEmpty || isApplying)
                Button("Close") { dismiss() }
                Button(isApplying ? "Applying…" : "Apply") { Task { await apply() } }
                    .buttonStyle(.glassProminent)
                    .disabled(isApplying || isLoading || library.activity != nil)
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
        .task { await load() }
    }

    @ViewBuilder
    private func row(for tweak: GameTweak) -> some View {
        let current = overrides[tweak.id] ?? gameValues[tweak.id] ?? ""
        switch tweak.kind {
        case .toggle:
            Toggle(isOn: Binding(
                get: { current.lowercased() == "true" },
                set: { on in overrides[tweak.id] = Self.boolString(on, like: gameValues[tweak.id]) }
            )) {
                label(for: tweak)
            }
        case .choice(let options):
            Picker(selection: Binding(get: { current }, set: { overrides[tweak.id] = $0 })) {
                ForEach(Array(Set(options + [current])).sorted { (options.firstIndex(of: $0) ?? 99) < (options.firstIndex(of: $1) ?? 99) }, id: \.self) {
                    Text($0).tag($0)
                }
            } label: {
                label(for: tweak)
            }
        }
    }

    private func label(for tweak: GameTweak) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(tweak.title)
                if overrides[tweak.id] != nil {
                    Text("changed").font(.caption2).foregroundStyle(MEStyle.omniOrange)
                }
            }
            Text(tweak.detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Keeps the game's own spelling of booleans ("True"/"true"/"TRUE").
    private static func boolString(_ value: Bool, like existing: String?) -> String {
        let word = value ? "true" : "false"
        guard let existing else { return value ? "True" : "False" }
        if existing == existing.uppercased() { return word.uppercased() }
        if existing.first?.isUppercase == true { return word.capitalized }
        return word
    }

    private func load() async {
        overrides = GameSettingsStore.overrides(for: game)
        guard let install = library.install else { return }
        launcherFiles = GameLauncher.launcherConfigFiles(for: install)
        if let first = launcherFiles.first { launcher = LauncherSettings(contentsOf: first) }
        let entries = GameTweak.all.map(\.entry)
        if let values = try? await HelperRunner.readConfig(game: game, gameDirectory: install.gameDirectory(game), entries: entries) {
            var byID: [String: String] = [:]
            for tweak in GameTweak.all {
                if let value = values[tweak.entry]?.last { byID[tweak.id] = value }
            }
            // The config read shows values with the user's settings applied; drop overrides equal to
            // nothing so "changed" only marks real changes.
            gameValues = byID
        }
        isLoading = false
    }

    private func apply() async {
        guard let install = library.install else { return }
        isApplying = true
        defer { isApplying = false }
        do {
            for file in launcherFiles { try launcher.write(to: file) }
            GameSettingsStore.save(overrides, for: game)
            try await GameSettingsStore.apply(for: game, in: install) { _ in }
            message = "Applied. Start the game to see the changes."
        } catch {
            message = "Couldn't apply: \(error.localizedDescription)"
        }
    }
}
