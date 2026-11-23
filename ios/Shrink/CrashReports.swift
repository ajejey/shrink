import Foundation
import MetricKit

/// Crash details from iOS (MetricKit). After Shrink crashes, iOS hands over a report the next time it
/// runs; Home then offers to send it through Report a problem. Nothing leaves the phone unless the
/// person taps Send, and the form shows exactly what goes. No file names or contents are in it: only
/// what kind of crash it was and where in the app's code.
@Observable
@MainActor
final class CrashReports: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReports()

    /// A crash not yet sent or waved away: a plain summary, ready for the report.
    private(set) var pending: String?

    private static let pendingKey = "crashPending"
    /// The newest crash already handled, so iOS handing the same report over again doesn't bring it back.
    private static let handledKey = "crashHandledUntil"

    override init() {
        super.init()
        pending = AppSettings.defaults.string(forKey: Self.pendingKey)
    }

    func start() {
        MXMetricManager.shared.add(self)
        take(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        Task { @MainActor in self.take(payloads) }
    }

    /// Sent, or "Not now": either way it's not offered again.
    func clear() {
        pending = nil
        AppSettings.defaults.removeObject(forKey: Self.pendingKey)
    }

    private func take(_ payloads: [MXDiagnosticPayload]) {
        let handled = AppSettings.defaults.double(forKey: Self.handledKey)
        let crashes = payloads
            .filter { $0.timeStampEnd.timeIntervalSince1970 > handled }
            .flatMap { payload in (payload.crashDiagnostics ?? []).map { (payload.timeStampEnd, $0) } }
        guard let latest = crashes.max(by: { $0.0 < $1.0 }) else { return }
        let (when, crash) = latest
        AppSettings.defaults.set(when.timeIntervalSince1970, forKey: Self.handledKey)
        let summary = Self.summary(of: crash, at: when)
        pending = summary
        AppSettings.defaults.set(summary, forKey: Self.pendingKey)
    }

    /// "Shrink closed unexpectedly on 23 Nov 2026 at 10:42. Signal 11 (SIGSEGV), exception type 1…"
    /// then the top of the crashed thread's stack as binary + offset.
    static func summary(of crash: MXCrashDiagnostic, at date: Date) -> String {
        var lines = ["Shrink closed unexpectedly on \(date.formatted(date: .abbreviated, time: .shortened))."]
        var what: [String] = []
        if let signal = crash.signal?.int32Value { what.append("signal \(signal)\(signalName(signal))") }
        if let type = crash.exceptionType { what.append("exception type \(type)") }
        if let code = crash.exceptionCode { what.append("code \(code)") }
        if !what.isEmpty { lines.append(what.joined(separator: ", ").capitalizedFirst + ".") }
        if let reason = crash.terminationReason, !reason.isEmpty { lines.append("Reason: \(reason.prefix(300))") }
        let version = crash.metaData.applicationBuildVersion
        lines.append("Build \(version), \(crash.metaData.osVersion).")
        let frames = topFrames(crash.callStackTree.jsonRepresentation(), limit: 12)
        if !frames.isEmpty { lines.append("Stack: " + frames.joined(separator: " < ")) }
        return lines.joined(separator: "\n")
    }

    private static func signalName(_ signal: Int32) -> String {
        switch signal {
        case 4: return " (SIGILL)"
        case 5: return " (SIGTRAP)"
        case 6: return " (SIGABRT)"
        case 9: return " (SIGKILL)"
        case 10: return " (SIGBUS)"
        case 11: return " (SIGSEGV)"
        default: return ""
        }
    }

    /// The crashed thread's frames, innermost first, as "binary+offset".
    static func topFrames(_ json: Data, limit: Int) -> [String] {
        guard let tree = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let stacks = tree["callStacks"] as? [[String: Any]] else { return [] }
        let stack = stacks.first { $0["threadAttributed"] as? Bool == true } ?? stacks.first
        var frames: [String] = []
        var level = (stack?["callStackRootFrames"] as? [[String: Any]])?.first
        while let frame = level, frames.count < limit {
            let binary = frame["binaryName"] as? String ?? "?"
            let offset = (frame["offsetIntoBinaryTextSegment"] as? NSNumber)?.intValue ?? 0
            frames.append("\(binary)+\(offset)")
            level = (frame["subFrames"] as? [[String: Any]])?.first
        }
        return frames
    }

    /// For CI screenshots: a summary as `summary(of:at:)` writes one.
    static let previewSummary = """
        Shrink closed unexpectedly on 23 Nov 2026 at 10:42.
        Signal 11 (SIGSEGV), exception type 1, code 0.
        Build 2611231042, iPhone OS 26.1 (23B85).
        Stack: Shrink+482312 < ShrinkCore+91844 < AVFCore+30212 < libdispatch.dylib+15880
        """
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
