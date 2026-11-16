import ShrinkCore
import SwiftUI

/// The whole screen for one job: pick the part to send, watch it shrink, then send it.
struct ShrinkJobView: View {
    let job: ShrinkJob
    @Environment(\.canReportProblem) private var canReportProblem

    var body: some View {
        NavigationStack {
            Group {
                if case .choosing(let video) = job.phase {
                    TrimView(video: video, targetBytes: job.targetBytes ?? 0, limitLabel: job.limitLabel) { part in
                        job.shrink(part: part)
                    }
                } else {
                    status
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
            .navigationTitle(job.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if job.isFinished {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { job.close() }
                    }
                }
                if !job.isFinished {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { job.close() }
                    }
                }
            }
        }
    }

    /// Opening, shrinking, done or failed.
    private var status: some View {
        VStack(spacing: 20) {
            Spacer()
            switch job.phase {
            case .opening, .choosing:
                ProgressView()
                    .controlSize(.large)
                Text(job.kind == .photo ? "Opening the photo…" : "Opening the video…")
                    .font(.title3)
            case .shrinking where job.kind == .photo:
                // Photos take a second or two: no percentage to follow.
                ProgressView()
                    .controlSize(.large)
                Text(job.targetBytes == nil ? "Making it a JPG…" : "Shrinking your photo…")
                    .font(.title2.bold())
            case .shrinking(let value):
                Text("Shrinking your video")
                    .font(.title2.bold())
                Text("\(Int(value * 100))%")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.default, value: Int(value * 100))
                ProgressView(value: value)
                    .scaleEffect(x: 1, y: 3, anchor: .center)
                    .padding(.horizontal, 8)
                Text("Keep Shrink open until it's done.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            case .done(let result):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.green)
                Text("Ready to send")
                    .font(.largeTitle.bold())
                VStack(spacing: 6) {
                    Text(sizeLine(result))
                        .font(.title3)
                    if let limit = job.limitLabel {
                        Text("Under the \(limit) limit")
                            .foregroundStyle(.secondary)
                    }
                }
                if job.removeLocation {
                    // The location switch lives in Settings now, so say when it did its job.
                    Label("Location removed", systemImage: "location.slash")
                        .font(.subheadline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                        .padding(.top, 6)
                }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.orange)
                Text("Couldn't shrink this one")
                    .font(.title2.bold())
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if case .done(let result) = job.phase {
                ShareLink(item: result.url) {
                    Label("Send it", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            if case .failed(let message) = job.phase {
                VStack(spacing: 10) {
                    if job.offersAnother {
                        Button {
                            job.pickAnother()
                        } label: {
                            Text(job.kind == .photo ? "Pick another photo" : "Pick another video")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    if canReportProblem,
                       let url = ProblemReport(job: job.jobDescription, problem: message).mailtoURL {
                        Link(destination: url) {
                            Text("Report a problem")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
            }
        }
        .padding(24)
    }

    /// "19.0 MB, was 61.5 MB": both sizes written the same way.
    private func sizeLine(_ result: ShrinkJob.Finished) -> String {
        let now = SizeFormat.string(result.bytes)
        guard let original = result.originalBytes, original > 0 else { return now }
        return "\(now), was \(SizeFormat.string(original))"
    }
}
