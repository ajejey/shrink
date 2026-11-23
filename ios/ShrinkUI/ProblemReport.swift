import SwiftUI
import UIKit

/// Where reports go: the support inbox's Google Apps Script (support/report-inbox.gs). Release builds get
/// its URL from the SHRINK_REPORT_URL build setting (a GitHub secret, so it isn't in the public code).
/// Local and test builds have none, and every "Report a problem" button stays hidden then.
enum SupportContact {
    /// Shown when a report can't be sent, and on the support page.
    static let email = "useshrink.support@gmail.com"

    static let reportURL: URL? = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "ShrinkReportURL") as? String,
              value.hasPrefix("https://"), let url = URL(string: value) else { return nil }
        return url
    }()
}

/// "Report a problem": what the person writes, plus what Shrink knows (app and iOS version, iPhone model,
/// the job, the error), sent to the support inbox only when they tap Send. Never a video, a photo or a
/// file name.
struct ProblemReport {
    /// "Compress for Discord (20 MB)".
    var job: String?
    /// The message the person saw.
    var problem: String?
    /// After a crash: iOS's summary of it (CrashReports.swift), shown on the form like everything else.
    var crash: String? = nil

    struct Detail: Hashable {
        let label: String
        let value: String
    }

    /// What goes with the person's words, listed on the form before they send.
    @MainActor var details: [Detail] {
        var rows = [
            Detail(label: "App", value: "Shrink \(Self.appVersion)"),
            Detail(label: "iPhone", value: "\(Self.deviceModel), iOS \(UIDevice.current.systemVersion)"),
        ]
        if let job { rows.append(Detail(label: "Job", value: job)) }
        if let problem { rows.append(Detail(label: "What went wrong", value: problem)) }
        if let crash { rows.append(Detail(label: "Crash details", value: crash)) }
        return rows
    }

    /// Posts the report. Apps Script answers through a redirect, which URLSession follows; the final
    /// page says {"ok":true} once the report is in the sheet.
    @MainActor func send(message: String, replyTo: String) async throws {
        guard let url = SupportContact.reportURL else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "app": "Shrink",
            "message": message,
            "replyTo": replyTo,
            "version": Self.appVersion,
            "device": Self.deviceModel,
            "ios": UIDevice.current.systemVersion,
            "job": job ?? "",
            // The inbox has one column for what went wrong; a crash's summary goes there too.
            "error": [problem, crash].compactMap { $0 }.joined(separator: "\n\n"),
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              reply["ok"] as? Bool == true else {
            throw URLError(.badServerResponse)
        }
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
}

/// The form: what happened, an optional email for a reply, and exactly what goes with it.
struct ReportProblemView: View {
    let report: ProblemReport
    /// For CI screenshots: the screen after a report went through.
    var showsSent = false
    /// Runs once the report is in (a crash report is then not offered again).
    var onSent: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var replyTo = ""
    @State private var sending = false
    @State private var failed = false
    @State private var sent = false
    @FocusState private var writing: Bool

    /// A crash report can go without words: its details say what happened.
    private var canSend: Bool {
        (!message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || report.crash != nil) && !sending
    }

    var body: some View {
        NavigationStack {
            Group {
                if sent || showsSent {
                    ContentUnavailableView {
                        Label("Report sent", systemImage: "checkmark.circle.fill")
                    } description: {
                        Text("Thank you. Every report is read, and if you left your email, you'll get a reply.")
                    }
                } else {
                    form
                }
            }
            .navigationTitle("Report a problem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if sent || showsSent {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if sending {
                            ProgressView()
                        } else {
                            Button("Send") { send() }
                                .disabled(!canSend)
                        }
                    }
                }
            }
        }
    }

    private var form: some View {
        Form {
            Section("What happened?") {
                TextField("Tell us what went wrong", text: $message, axis: .vertical)
                    .lineLimit(5...12)
                    .focused($writing)
            }
            Section {
                TextField("Your email", text: $replyTo)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Want a reply?")
            } footer: {
                Text("Optional. Only used to answer you.")
            }
            Section {
                ForEach(report.details, id: \.self) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.label).font(.subheadline).foregroundStyle(.secondary)
                        Text(row.value)
                    }
                }
            } header: {
                Text("Sent with your message")
            } footer: {
                Text("Never your videos, photos or their names.")
            }
            if failed {
                Section {
                    Text("Couldn't send it. Check your connection and tap Send again.")
                        .foregroundStyle(.red)
                    // Plain, selectable text: the share sheet can't open the mail app.
                    Text("Or email it to \(SupportContact.email)")
                        .textSelection(.enabled)
                }
            }
        }
        .onAppear { writing = true }
    }

    private func send() {
        sending = true
        failed = false
        let typed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = typed.isEmpty && report.crash != nil ? "(Crash report, nothing written)" : typed
        let email = replyTo.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await report.send(message: text, replyTo: email)
                sent = true
                onSent?()
            } catch {
                failed = true
            }
            sending = false
        }
    }
}
