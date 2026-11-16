import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Shrink" in the share sheet of Photos, WhatsApp, Files and the rest: the same job as the app
/// (pick where it's going, trim, shrink, send), done right there without opening the app.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel(context: extensionContext)
        let host = UIHostingController(rootView: ShareRootView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        model.load()
    }
}

/// The shared file, once it's copied somewhere we can read it.
@Observable
@MainActor
final class ShareModel {
    enum State {
        case loading
        case ready(url: URL, isVideo: Bool)
        case failed(String)
    }

    var state: State = .loading
    private weak var context: NSExtensionContext?
    private var copied: URL?

    init(context: NSExtensionContext?) {
        self.context = context
    }

    func load() {
        let providers = (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let video = providers.first { $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier) }
        let photo = providers.first { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        guard let provider = video ?? photo else {
            state = .failed("Shrink works with one video or one photo at a time.")
            return
        }
        let isVideo = video != nil
        let type = isVideo ? UTType.movie : UTType.image
        provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { [weak self] url, error in
            // The file only exists until this returns, so copy it first.
            var copy: URL?
            if let url {
                let target = FileManager.default.temporaryDirectory
                    .appendingPathComponent("shared-\(UUID().uuidString)")
                    .appendingPathExtension(url.pathExtension)
                if (try? FileManager.default.copyItem(at: url, to: target)) != nil { copy = target }
            }
            Task { @MainActor in
                guard let self else { return }
                if let copy {
                    self.copied = copy
                    self.state = .ready(url: copy, isVideo: isVideo)
                } else {
                    self.state = .failed("Couldn't open it. \(error?.localizedDescription ?? "")")
                }
            }
        }
    }

    /// Closes the share sheet, removing our copy of the file.
    func finish() {
        if let copied { try? FileManager.default.removeItem(at: copied) }
        context?.completeRequest(returningItems: nil)
    }
}

struct ShareRootView: View {
    let model: ShareModel
    @State private var job = ShrinkJob()

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .loading:
                    VStack(spacing: 16) {
                        ProgressView().controlSize(.large)
                        Text("Opening…").font(.title3)
                    }
                case .ready(let url, let isVideo):
                    DestinationList(kind: isVideo ? .video : .photo) { destination in
                        // The switch is in the app's Settings (shared through the App Group).
                        job.open(url: url, isVideo: isVideo, destination: destination,
                                 removeLocation: AppSettings.removeLocation)
                    }
                case .failed(let message):
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.orange)
                        Text(message)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                }
            }
            .navigationTitle("Shrink")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.finish() }
                }
            }
        }
        .fullScreenCover(isPresented: $job.isShowing) {
            ShrinkJobView(job: job)
        }
        // Done after a finished job closes the share sheet; Cancel mid-way goes back to the list.
        .onChange(of: job.isShowing) { _, showing in
            if !showing, job.isFinished, case .done = job.phase { model.finish() }
        }
    }
}
