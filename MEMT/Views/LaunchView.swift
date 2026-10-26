import SwiftUI

/// The launcher home screen: one card per game with its art and a Play button.
struct LaunchView: View {
    @Environment(ModLibrary.self) private var library
    @Binding var selection: SidebarItem?
    @AppStorage("launchResumesLastSave") private var resumeLastSave = false
    @AppStorage(GameLauncher.preferredMethodKey) private var preferredMethod = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                HStack(spacing: 20) {
                    ForEach(LEGame.allCases) { game in
                        GameLaunchCard(game: game, resume: resumeLastSave) {
                            selection = .game(game)
                        }
                    }
                }
                footer
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        // A background takes the scroll view's size, so the aspect-filled art can't widen the page.
        .background { background }
        .navigationTitle("Launch")
    }

    @ViewBuilder
    private var background: some View {
        ZStack {
            if let hero = SteamArt.image(.hero) {
                Color.black
                    .overlay {
                        Image(nsImage: hero)
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 30)
                    }
                    .overlay(Color.black.opacity(0.65))
                    .clipped()
            } else {
                SpaceBackdrop()
            }
            ScanLines()
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(spacing: 10) {
            if let logo = SteamArt.image(.logo) {
                Image(nsImage: logo)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 300)
                    .shadow(color: .black.opacity(0.6), radius: 20)
                    .accessibilityLabel("Mass Effect Legendary Edition")
            } else {
                RelayEmblem(size: 110)
                Text("Mass Effect").meHeading(size: 40)
                Text("Legendary Edition").meLabel().foregroundStyle(MEStyle.n7Red)
            }
            N7Stripe()
        }
        .padding(.top, 8)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Toggle("Continue my last save", isOn: $resumeLastSave)
                .toggleStyle(.switch)
                .tint(MEStyle.n7Red)
                .help("Skips the main menu and loads your most recent save.")
            if let method = GameLauncher.currentMethod() {
                Label("Starts through \(method.displayName) · mods are loaded automatically", systemImage: "gamecontroller.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Label("Install Steam (or Steam in a CrossOver bottle) to start the games from here.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(MEStyle.omniOrange)
            }
        }
        .padding(16)
        .glassEffect(in: .rect(cornerRadius: 16))
    }
}

/// A tall game card: key art, title, mod status and a Play button.
private struct GameLaunchCard: View {
    @Environment(ModLibrary.self) private var library
    @Environment(DownloadManager.self) private var downloads
    let game: LEGame
    let resume: Bool
    let manage: () -> Void
    @State private var isHovered = false

    private var artAlignment: Alignment {
        switch game {
        case .le1: .leading
        case .le2: .center
        case .le3: .trailing
        }
    }

    private var statusText: String {
        guard library.isInstalled(game) else { return "Not installed" }
        let count = library.modCount(for: game, enabledOnly: true) + downloads.gameFileMods(for: game).count
        let turnedOff = library.modCount(for: game) - library.modCount(for: game, enabledOnly: true)
        let active = count == 0 ? "No mods active" : count == 1 ? "1 mod active" : "\(count) mods active"
        // Make disabled mods obvious, so a vanilla-looking game isn't a surprise.
        return turnedOff == 0 ? active : "\(active) · \(turnedOff) turned off"
    }

    var body: some View {
        let tint = MEStyle.tint(for: game)
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                GameArt(game: game)
                    .clipped()
                // The art overflows the card before clipping; keep it from catching the mouse
                // over the neighbouring cards.
                .allowsHitTesting(false)
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 6) {
                    Text(MEStyle.codename(for: game))
                        .font(.system(size: 54, weight: .black))
                        .fontWidth(.expanded)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .foregroundStyle(tint)
                        .shadow(color: tint.opacity(0.6), radius: 12)
                    Text(game.displayName).meHeading(size: 17)
                    N7Stripe(color: tint, height: 4)
                }
                .padding(18)
            }
            .frame(height: 230)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Circle().fill(library.isInstalled(game) ? Color.green : Color.secondary).frame(width: 7, height: 7)
                    Text(statusText).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Mods", action: manage)
                        .buttonStyle(.borderless)
                        .font(.callout)
                        .disabled(!library.isInstalled(game))
                }
                Button {
                    Task { await library.launch(game, resume: resume) }
                } label: {
                    Label(resume ? "Continue" : "Play", systemImage: "play.fill")
                        .font(.headline)
                        .fontWidth(.expanded)
                        .textCase(.uppercase)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(tint)
                .controlSize(.extraLarge)
                .disabled(!library.isInstalled(game) || library.activity != nil)
            }
            .padding(16)
        }
        .background(MEStyle.panel.opacity(0.9))
        .clipShape(.rect(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(tint.opacity(isHovered ? 0.9 : 0.3), lineWidth: isHovered ? 2 : 1)
        )
        .shadow(color: tint.opacity(isHovered ? 0.45 : 0.15), radius: isHovered ? 24 : 10)
        .scaleEffect(isHovered ? 1.02 : 1)
        .animation(.snappy, value: isHovered)
        .contentShape(.rect(cornerRadius: 20))
        .onHover { isHovered = $0 }
        .opacity(library.isInstalled(game) ? 1 : 0.55)
    }
}
