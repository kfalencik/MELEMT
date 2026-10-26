import SwiftUI

/// The install options window: a mod's optional components, with pick-one groups, on/off
/// options, and options that apply automatically shown with the reason.
struct InstallOptionsView: View {
    @Environment(ModLibrary.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    let request: DownloadManager.OptionsRequest

    @State private var choices: [String: Bool] = [:]

    private var package: ModPackage { request.package }
    private var states: [String: ModOptionState] { library.optionStates(for: package, choices: choices) }

    /// Groups (pick one) and single options in moddesc order, sorted like M3 (SortIndex first).
    private var sections: [OptionSection] {
        var result: [OptionSection] = []
        var seenGroups = Set<String>()
        for option in package.options where !option.hidden {
            if let group = option.group {
                guard !seenGroups.contains(group) else { continue }
                seenGroups.insert(group)
                result.append(.group(name: group, options: package.options.filter { $0.group == group && !$0.hidden }))
            } else {
                result.append(.single(option))
            }
        }
        return result.sorted { ($0.sortIndex ?? Int.max) < ($1.sortIndex ?? Int.max) }
    }

    var body: some View {
        let tint = package.game.map(MEStyle.tint(for:)) ?? MEStyle.n7Red
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Install Options").meLabel().foregroundStyle(tint)
                Text(package.name).meHeading(size: 22)
                HStack(spacing: 8) {
                    if let game = package.game { GameChip(game: game) }
                    Text([package.version.isEmpty ? nil : "v\(package.version)", "by \(package.developer)"].compactMap(\.self).joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
                N7Stripe(color: tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(sections) { section in
                        switch section {
                        case .group(let name, let options):
                            GroupCard(name: name, options: options, states: states, package: package, selection: groupBinding(options))
                        case .single(let option):
                            OptionCard(option: option, state: states[option.id], package: package, isOn: toggleBinding(option))
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }

            Divider()
            HStack {
                Text("Your choices are remembered. Change them later with Change Options on the installed mod.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Install") {
                    downloads.confirmOptions(request, choices: choices)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .tint(tint)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 640, height: 600)
        .onAppear { choices = request.item.chosenOptions }
        .onDisappear { downloads.optionsWindowClosed() }
        .preferredColorScheme(.dark)
    }

    private func toggleBinding(_ option: ModOption) -> Binding<Bool> {
        Binding(
            get: { states[option.id]?.selected ?? false },
            set: { choices[option.id] = $0 }
        )
    }

    private func groupBinding(_ options: [ModOption]) -> Binding<String> {
        Binding(
            get: { options.first { states[$0.id]?.selected == true }?.id ?? "" },
            set: { chosen in
                for option in options { choices[option.id] = option.id == chosen }
            }
        )
    }
}

private enum OptionSection: Identifiable {
    case group(name: String, options: [ModOption])
    case single(ModOption)

    var id: String {
        switch self {
        case .group(let name, _): "group:\(name)"
        case .single(let option): option.id
        }
    }

    var sortIndex: Int? {
        switch self {
        case .group(_, let options): options.compactMap(\.sortIndex).min()
        case .single(let option): option.sortIndex
        }
    }
}

/// A pick-one group: radio buttons, with each option's description and picture.
private struct GroupCard: View {
    let name: String
    let options: [ModOption]
    let states: [String: ModOptionState]
    let package: ModPackage
    @Binding var selection: String

    private var locked: Bool { !options.contains { states[$0.id]?.selectable == true } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(name).font(.headline)
            Picker(name, selection: $selection) {
                ForEach(options) { option in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.name)
                        if !option.details.isEmpty {
                            Text(option.details).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tag(option.id)
                    .disabled(states[option.id]?.selectable == false || states[option.id]?.notApplicable == true)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(locked)
            if let image = options.first(where: { $0.id == selection })?.imageName.flatMap({ OptionImage.load($0, in: package) }) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 160).clipShape(.rect(cornerRadius: 8))
            }
            if locked {
                Label("Chosen automatically for your setup.", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MEStyle.panel, in: .rect(cornerRadius: 12))
    }
}

/// A single option: a switch if the user can change it, otherwise a locked row that says
/// whether it applies.
private struct OptionCard: View {
    let option: ModOption
    let state: ModOptionState?
    let package: ModPackage
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if state?.selectable == true {
                Toggle(option.name, isOn: $isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
            } else {
                Image(systemName: state?.selected == true ? "checkmark.circle.fill" : "minus.circle")
                    .font(.title3)
                    .foregroundStyle(state?.selected == true ? .green : .secondary)
                    .frame(width: 38)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(option.name).font(.headline).foregroundStyle(state?.notApplicable == true ? .secondary : .primary)
                if !option.details.isEmpty {
                    Text(option.details).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if state?.selectable != true {
                    Text(lockedText).font(.caption.weight(.medium)).foregroundStyle(state?.selected == true ? .green : .secondary)
                }
                if let image = option.imageName.flatMap({ OptionImage.load($0, in: package) }) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 140).clipShape(.rect(cornerRadius: 8))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(MEStyle.panel, in: .rect(cornerRadius: 12))
    }

    private var lockedText: String {
        if state?.selected == true {
            return option.applicableText ?? (option.isAlways ? "Always installed" : "Applied automatically for your setup")
        }
        return option.notApplicableText ?? "Not available with your current mods"
    }
}

/// Option pictures live in the mod's M3Images folder.
private enum OptionImage {
    static func load(_ name: String, in package: ModPackage) -> NSImage? {
        PathResolver.resolve("M3Images/\(name.replacingOccurrences(of: "\\", with: "/"))", in: package.rootURL)
            .flatMap { NSImage(contentsOf: $0) }
    }
}
