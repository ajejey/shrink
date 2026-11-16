import SwiftUI
import UIKit

/// Where "Report a problem" emails go. nil until the support address exists, and every
/// "Report a problem" button stays hidden until then.
enum SupportContact {
    static let email: String? = nil
}

/// "Report a problem": an email draft in the person's own mail app, with what Shrink knows filled in
/// (app and iOS version, iPhone model, the job, the error). Never the file or its name. No server.
struct ProblemReport {
    /// "Compress for Discord (20 MB)".
    var job: String?
    /// The message the person saw.
    var problem: String?

    /// A mailto: link, or nil while there's no support address.
    @MainActor var mailtoURL: URL? {
        guard let email = SupportContact.email else { return nil }
        let subject = Self.encoded("Shrink: problem report")
        return URL(string: "mailto:\(email)?subject=\(subject)&body=\(Self.encoded(text))")
    }

    @MainActor var text: String {
        var lines = [
            "What happened? Write it here.", "", "",
            "-- Filled in by Shrink --",
            "App: Shrink \(Self.appVersion)",
            "iPhone: \(Self.deviceModel), iOS \(UIDevice.current.systemVersion)",
        ]
        if let job { lines.append("Job: \(job)") }
        if let problem { lines.append("What went wrong: \(problem)") }
        return lines.joined(separator: "\n")
    }

    /// "1.0 (1)".
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// The model code ("iPhone14,5"), which names the exact iPhone.
    static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Everything but letters and digits escaped, so "&", "+" and new lines survive in any mail app.
    private static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }
}

private struct CanReportProblemKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True in the app. The share sheet can't open the mail app, so it doesn't offer it.
    var canReportProblem: Bool {
        get { self[CanReportProblemKey.self] }
        set { self[CanReportProblemKey.self] = newValue }
    }
}
