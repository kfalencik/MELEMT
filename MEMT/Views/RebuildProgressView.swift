import SwiftUI

/// Shows each step of Rebuild Mods as it runs: restoring the original files, then each mod in order.
struct RebuildProgressView: View {
    let progress: RebuildProgress
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.title2)
                    .foregroundStyle(MEStyle.tint(for: progress.game))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rebuilding \(progress.game.displayName)").meHeading(size: 18)
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                }
            }
            N7Stripe(color: MEStyle.tint(for: progress.game))

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(progress.steps.enumerated()), id: \.element.id) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            icon(for: step.status)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(index == 0 ? "" : "\(index). ")\(step.title)")
                                    .font(.body.weight(step.status == .working ? .semibold : .regular))
                                if case .failed(let message) = step.status {
                                    Text(message).font(.caption).foregroundStyle(MEStyle.n7Red)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 160, maxHeight: 320)

            HStack {
                Spacer()
                Button(progress.isFinished ? "Done" : "Working…", action: close)
                    .buttonStyle(.glassProminent)
                    .disabled(!progress.isFinished)
            }
        }
        .padding(24)
        .frame(width: 480)
        .interactiveDismissDisabled(!progress.isFinished)
    }

    private var summary: String {
        if !progress.isFinished { return "Restoring original files and reinstalling each mod in load order." }
        return progress.failures == 0 ? "Everything was reinstalled cleanly." : "Finished with \(progress.failures) problem\(progress.failures == 1 ? "" : "s"). See below."
    }

    @ViewBuilder
    private func icon(for status: RebuildProgress.Status) -> some View {
        switch status {
        case .waiting: Image(systemName: "circle").foregroundStyle(.secondary)
        case .working: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(MEStyle.n7Red)
        }
    }
}
