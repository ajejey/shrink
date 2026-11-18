import ShrinkCore
import SwiftUI

/// Clean up photos while it works and when it's done: saving stills, iOS's prompt, then "Space freed".
struct PhotoCleanupRunView: View {
    let model: PhotoCleanup
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Group {
                switch model.run {
                case .idle:
                    EmptyView()
                case .working(let done, let count):
                    VStack(spacing: 18) {
                        Spacer()
                        Text("Saving still photos")
                            .font(.title2.bold())
                        Text("Photo \(min(done + 1, count)) of \(count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        ProgressView(value: Double(done), total: Double(max(count, 1)))
                            .scaleEffect(x: 1, y: 3, anchor: .center)
                            .padding(.horizontal, 8)
                        Text("Each Live Photo gets a still copy with the same date, place and albums, checked before the Live Photo can go. Keep Shrink open.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .multilineTextAlignment(.center)
                    .padding(24)
                case .deleting:
                    VStack(spacing: 16) {
                        ProgressView().controlSize(.large)
                        Text("Waiting for iPhone to confirm…")
                            .font(.title3)
                    }
                    .padding(24)
                case .finished(let summary):
                    finished(summary)
                case .failed(let message):
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.title3)
                    }
                    .multilineTextAlignment(.center)
                    .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
            .navigationTitle("Clean up photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isFinished {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { model.closeRun() }
                    }
                }
                if isFailed {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Back") { model.cancelRun() }
                    }
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private var isFinished: Bool {
        if case .finished = model.run { return true }
        return false
    }

    private var isFailed: Bool {
        if case .failed = model.run { return true }
        return false
    }

    @ViewBuilder private func finished(_ summary: CleanupSummary) -> some View {
        let things = summary.deleted + summary.stills
        ScrollView {
            VStack(spacing: 14) {
                if summary.declined {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.orange)
                    Text("Nothing was deleted")
                        .font(.title.bold())
                    Text(summary.stills > 0
                         ? "iPhone asked to confirm and the answer was no. The still photos are saved, and the Live Photos are still in your library too. Free up space on Home can move them to Recently Deleted later."
                         : "iPhone asked to confirm and the answer was no, so everything is still in your library. Your picks are kept if you change your mind.")
                        .foregroundStyle(.secondary)
                } else if things > 0 {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(.green)
                    Text("Space freed")
                        .font(.largeTitle.bold())
                    Text("About \(SizeFormat.string(summary.freedBytes)) from \(things == 1 ? "1 photo" : "\(things.formatted()) photos")")
                        .font(.title3)
                    if summary.stills > 0 {
                        Text(summary.stills == 1 ? "1 Live Photo is now a still photo."
                                                 : "\(summary.stills.formatted()) Live Photos are now still photos.")
                            .foregroundStyle(.secondary)
                    }
                    Text("It comes back when Recently Deleted is emptied.")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Get the space back now")
                            .font(.headline)
                        Text("In Photos, open Albums, then Recently Deleted. Tap Select, then Delete All. Apps aren't allowed to do this for you.")
                            .font(.subheadline)
                        Button {
                            if let url = URL(string: "photos-redirect://") { openURL(url) }
                        } label: {
                            Text("Open Photos").font(.headline).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.top, 10)
                    AllowanceBar()
                        .padding(.top, 6)
                } else {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.secondary)
                    Text("Nothing was cleaned up")
                        .font(.title.bold())
                }
                if let problem = summary.problems.first {
                    Text(summary.problems.count == 1 ? problem
                                                     : "\(summary.problems.count) things went wrong. The first: \(problem)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .padding(24)
            .padding(.top, 24)
        }
    }
}
