import ShrinkCore
import SwiftUI
import UIKit

/// Send several at once: opening the pick, the check before anything starts, the work, and the
/// finished files with one Send all.
struct BatchSendView: View {
    let model: BatchSend
    @State private var showReport = false
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .opening(let done, let total):
                    VStack(spacing: 16) {
                        ProgressView().controlSize(.large)
                        Text(total > 1 ? "Opening \(min(done + 1, total)) of \(total)…" : "Opening…")
                            .font(.title3)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .checking:
                    check
                case .working:
                    working
                case .finished:
                    finished
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(model.destination?.title ?? "Send several at once")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.phase == .finished {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { model.close() }
                    }
                }
                if model.phase != .finished {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { model.close() }
                    }
                }
            }
        }
    }

    private var limit: String { model.destination?.limitLabel ?? "the limit" }

    // MARK: - Check

    private var check: some View {
        List {
            Section {
                ForEach(model.items) { item in
                    BatchRow(item: item, limit: limit, together: model.together, showsFit: true)
                        .deleteDisabled(item.state != .waiting)
                }
                .onDelete { offsets in
                    let ids = offsets.map { model.items[$0].id }
                    for id in ids { model.remove(id) }
                }
            } header: {
                Text("Check before shrinking")
                    .font(.title.bold())
                    .foregroundStyle(Color.primary)
                    .textCase(nil)
                    .padding(.bottom, 8)
            } footer: {
                Text("Swipe left on one to leave it out.")
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                checkLine
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    model.startShrinking()
                } label: {
                    Text("Shrink \(BatchSend.count(model.going))")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canStart)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    /// Whether they fit, in plain words, with what to do when they don't.
    @ViewBuilder private var checkLine: some View {
        let going = model.going
        let tooBig = model.tooBig
        let soft = going.contains { $0.share?.fit == .soft }
        if model.destination?.limitBytes == nil {
            status("Each photo becomes a JPG.", icon: "checkmark.circle.fill", color: .green)
        } else if model.together {
            if going.isEmpty && tooBig.isEmpty {
                status("Nothing left to send.", icon: "xmark.circle.fill", color: .red)
            } else if !tooBig.isEmpty {
                status("Too much video for one \(limit) email. Leave some out to make room.",
                       icon: "xmark.circle.fill", color: .red)
            } else if soft {
                status("They all fit in one \(limit) email, but the videos will look soft. Leave some out to make them sharper.",
                       icon: "exclamationmark.circle.fill", color: .orange)
            } else {
                status("They all fit in one \(limit) email and stay sharp.", icon: "checkmark.circle.fill", color: .green)
            }
        } else if going.isEmpty {
            status("None of these fit under \(limit). Send them one at a time to trim them.",
                   icon: "xmark.circle.fill", color: .red)
        } else if !tooBig.isEmpty {
            status(tooBig.count == 1 ? "1 is too long for \(limit) and stays out. Send it on its own to trim it."
                                     : "\(tooBig.count) are too long for \(limit) and stay out. Send those on their own to trim them.",
                   icon: "exclamationmark.circle.fill", color: .orange)
        } else if soft {
            status("Each one fits under \(limit). The long ones will look soft.",
                   icon: "exclamationmark.circle.fill", color: .orange)
        } else {
            status("Each one fits under \(limit) and stays sharp.", icon: "checkmark.circle.fill", color: .green)
        }
    }

    /// The words in the normal text color (readable), the meaning in the icon's color.
    private func status(_ text: String, icon: String, color: Color) -> some View {
        Label {
            Text(text).fontWeight(.medium)
        } icon: {
            Image(systemName: icon).foregroundStyle(color)
        }
    }

    // MARK: - Working

    private var working: some View {
        let total = model.runItems.count
        let current = min(model.finishedInRun + 1, max(total, 1))
        return List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Shrinking \(current) of \(total)")
                        .font(.title2.bold())
                        .monospacedDigit()
                    ProgressView(value: model.overallProgress)
                        .scaleEffect(x: 1, y: 3, anchor: .center)
                        .padding(.vertical, 6)
                    Text("Keep Shrink open until it's done.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
            Section {
                ForEach(model.runItems) { item in
                    BatchRow(item: item, limit: limit, together: model.together, showsFit: false)
                }
            }
        }
    }

    // MARK: - Finished

    private var finished: some View {
        let made = model.madeFiles
        let failed = model.items.filter(\.isFailed)
        return List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: made.isEmpty ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(made.isEmpty ? Color.orange : Color.green)
                    Text(made.isEmpty ? "Couldn't shrink these" : "Ready to send")
                        .font(.largeTitle.bold())
                    if !made.isEmpty {
                        Text(totalLine(count: made.count, bytes: model.madeBytes))
                            .font(.title3)
                            .multilineTextAlignment(.center)
                    }
                    if !made.isEmpty, model.together, model.destination?.limitBytes != nil {
                        Text("Under the \(limit) email limit, all together")
                            .foregroundStyle(.secondary)
                    }
                    if !made.isEmpty, model.destination?.limitBytes != nil, !model.together {
                        Text("Each one under the \(limit) limit")
                            .foregroundStyle(.secondary)
                    }
                    if model.destination?.limitBytes != nil, AppSettings.removeLocation {
                        Label("Location removed", systemImage: "location.slash")
                            .font(.subheadline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color(.secondarySystemBackground), in: Capsule())
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(model.items) { item in
                    BatchRow(item: item, limit: limit, together: model.together, showsFit: false)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                if !made.isEmpty {
                    Button {
                        showShare = true
                    } label: {
                        Label(made.count == 1 ? "Send it" : "Send all \(made.count)", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .sheet(isPresented: $showShare) {
                        ShareSheet(items: made.map { $0.url })
                            .presentationDetents([.medium, .large])
                            .ignoresSafeArea()
                    }
                }
                if !model.retryable.isEmpty {
                    Button {
                        model.retryFailed()
                    } label: {
                        Text(model.retryable.count == 1 ? "Try the one that didn't work again"
                                                        : "Try the \(model.retryable.count) that didn't work again")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                if !failed.isEmpty, SupportContact.reportURL != nil {
                    Button("Report a problem") { showReport = true }
                        .frame(minHeight: 44)
                        .sheet(isPresented: $showReport) {
                            ReportProblemView(report: ProblemReport(job: reportJob, problem: reportProblem(failed)))
                        }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    /// "2 files, 23.4 MB in all".
    private func totalLine(count: Int, bytes: Int64) -> String {
        count == 1 ? "1 file, \(SizeFormat.string(bytes))" : "\(count) files, \(SizeFormat.string(bytes)) in all"
    }

    private var reportJob: String {
        let title = model.destination?.title ?? "Send several at once"
        return "Send several at once: \(title) (\(limit))"
    }

    private func reportProblem(_ failed: [BatchSend.Item]) -> String {
        failed.compactMap { item in
            if case .failed(let why) = item.state { return "\(item.isVideo ? "A video" : "A photo"): \(why)" }
            return nil
        }.joined(separator: "\n")
    }
}

/// iOS's own share sheet for all the finished files at once.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// One file in the batch: its small picture, its length and size, and how it's doing.
private struct BatchRow: View {
    let item: BatchSend.Item
    let limit: String
    let together: Bool
    /// On the check screen: whether it fits. Later: how its work is going.
    let showsFit: Bool

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.tertiarySystemFill))
            if let image = item.thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: item.isVideo ? "video" : "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    /// "1:05 · 61.5 MB", or for a finished file "17.9 MB, was 61.5 MB".
    private var detail: String {
        let original = SizeFormat.string(item.bytes)
        if case .done(_, let bytes) = item.state {
            return item.bytes > 0 ? "\(SizeFormat.string(bytes)), was \(original)" : SizeFormat.string(bytes)
        }
        if let seconds = item.seconds { return "\(Clock.string(seconds)) · \(original)" }
        return item.bytes > 0 ? "Photo · \(original)" : "Photo"
    }

    /// A short reason under the details, when there is one.
    private var note: String? {
        switch item.state {
        case .failed(let why):
            return why
        case .waiting where showsFit && item.share?.fit == .doesNotFit:
            return together ? nil : "Too long for \(limit). Send it on its own to trim it."
        case .waiting where showsFit && item.share?.fit == .soft:
            return "Fits, but will look soft"
        default:
            return nil
        }
    }

    @ViewBuilder private var trailing: some View {
        switch item.state {
        case .waiting:
            if showsFit {
                switch item.share?.fit {
                case .sharp?:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        .accessibilityLabel("Fits")
                case .soft?:
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        .accessibilityLabel("Fits, looks soft")
                case .doesNotFit?:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        .accessibilityLabel("Doesn't fit")
                case nil:
                    EmptyView()
                }
            } else {
                Text("Waiting").font(.subheadline).foregroundStyle(.secondary)
            }
        case .working(let value):
            if let value {
                Text("\(Int(value * 100))%")
                    .font(.headline)
                    .monospacedDigit()
            } else {
                ProgressView()
            }
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                .accessibilityLabel("Done")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .accessibilityLabel("Didn't work")
        }
    }
}
