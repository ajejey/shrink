import AVFoundation
import ShrinkCore
import SwiftUI

/// Shrink Pro's sending options: use the whole limit, the format, the picture size, 60 fps and every
/// detail. Saved in the App Group so the share sheet uses them too. Without Pro every job uses
/// `.standard`, whatever is saved, so a lapsed yearly plan quietly goes back to the usual settings.
struct SendingOptions: Equatable {
    enum Format: String, CaseIterable, Identifiable {
        case h264, hevc

        var id: String { rawValue }

        var title: String {
            switch self {
            case .h264: return "Plays everywhere (H.264)"
            case .hevc: return "Sharper at the same size (HEVC)"
            }
        }

        var short: String {
            switch self {
            case .h264: return "H.264"
            case .hevc: return "HEVC"
            }
        }
    }

    /// The picture's long side. "1080p" is 1920 on the long side, upright or sideways.
    enum PictureSize: Int, CaseIterable, Identifiable {
        case sharpest = 0
        case uhd = 3840
        case fullHD = 1920
        case hd = 1280
        case sd = 854

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .sharpest: return "Sharpest that fits"
            case .uhd: return "4K"
            case .fullHD: return "1080p"
            case .hd: return "720p"
            case .sd: return "480p"
            }
        }
    }

    var usesWholeLimit = false
    var format: Format = .h264
    var pictureSize: PictureSize = .sharpest
    var keepsSixtyFPS = false
    var keepsAllDetails = false

    static let standard = SendingOptions()

    /// Where each option is saved (App Group defaults).
    enum Key {
        static let wholeLimit = "sendWholeLimit"
        static let format = "sendFormat"
        static let pictureSize = "sendPictureSize"
        static let sixtyFPS = "sendSixtyFPS"
        static let allDetails = "sendAllDetails"
    }

    /// What's saved, Pro or not (for the options screen and its summary).
    static var saved: SendingOptions {
        let defaults = AppSettings.defaults
        var options = SendingOptions()
        options.usesWholeLimit = defaults.bool(forKey: Key.wholeLimit)
        options.format = Format(rawValue: defaults.string(forKey: Key.format) ?? "") ?? .h264
        options.pictureSize = PictureSize(rawValue: defaults.integer(forKey: Key.pictureSize)) ?? .sharpest
        options.keepsSixtyFPS = defaults.bool(forKey: Key.sixtyFPS)
        options.keepsAllDetails = defaults.bool(forKey: Key.allDetails)
        return options
    }

    /// What a job uses right now: the saved options with Pro, the usual ones without.
    static var current: SendingOptions { AppSettings.isPro ? saved : .standard }

    /// Writes these as the saved options (CI screenshots of the options screen).
    func save() {
        let defaults = AppSettings.defaults
        defaults.set(usesWholeLimit, forKey: Key.wholeLimit)
        defaults.set(format.rawValue, forKey: Key.format)
        defaults.set(pictureSize.rawValue, forKey: Key.pictureSize)
        defaults.set(keepsSixtyFPS, forKey: Key.sixtyFPS)
        defaults.set(keepsAllDetails, forKey: Key.allDetails)
    }

    var sizeChoices: SizeChoices {
        SizeChoices(exactSize: usesWholeLimit,
                    longSide: pictureSize == .sharpest ? nil : pictureSize.rawValue,
                    keepsHighFrameRate: keepsSixtyFPS,
                    hevc: format == .hevc)
    }

    /// The video options for one file. The single job and Send several at once both build theirs
    /// here, so they can't drift apart.
    func video(targetBytes: Int64, removeLocation: Bool, timeRange: CMTimeRange?) -> VideoShrinkOptions {
        VideoShrinkOptions(targetBytes: targetBytes, removeLocation: removeLocation, timeRange: timeRange,
                           choices: sizeChoices, keepsAllDetails: keepsAllDetails)
    }

    /// One photo as a JPEG under the limit, with these options.
    func photo(at source: URL, to output: URL, targetBytes: Int64?, removeLocation: Bool) throws -> PhotoShrinkResult {
        try PhotoShrinker.shrink(imageAt: source, to: output, targetBytes: targetBytes,
                                 removeLocation: removeLocation, keepsAllDetails: keepsAllDetails)
    }

    /// "HEVC · 720p · Whole limit": what's changed from the usual, or "Usual settings".
    var summary: String {
        var parts: [String] = []
        if format != .h264 { parts.append(format.short) }
        if pictureSize != .sharpest { parts.append(pictureSize.title) }
        if keepsSixtyFPS { parts.append("60 fps") }
        if usesWholeLimit { parts.append("Whole limit") }
        if keepsAllDetails { parts.append("All details") }
        return parts.isEmpty ? "Usual settings" : parts.joined(separator: " · ")
    }
}

// MARK: - The Pro screen, from shared screens

/// Why the Pro screen opened, so its headline matches what the person tapped.
enum ProReason {
    case freeUp, several, options
}

/// Opens the app's Pro screen from screens the share sheet shares. The share sheet sets none:
/// Pro is bought in the app.
struct ProScreen {
    let make: @MainActor (ProReason) -> AnyView
}

private struct ProScreenKey: EnvironmentKey {
    static let defaultValue: ProScreen? = nil
}

extension EnvironmentValues {
    var proScreen: ProScreen? {
        get { self[ProScreenKey.self] }
        set { self[ProScreenKey.self] = newValue }
    }
}

// MARK: - Screens

/// "Sending options": Pro's choices for how files are made. Without Pro they're shown greyed under a
/// Get Pro button (in the share sheet, a line saying Pro comes from the app), so it's clear what Pro
/// adds before anyone pays.
struct SendingOptionsView: View {
    /// Off when it's pushed inside Settings, which has its own Done.
    var showsDone = true
    /// CI screenshots: Pro on or off without the App Store.
    var previewPro: Bool? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.proScreen) private var proScreen
    @AppStorage(AppSettings.proKey, store: AppSettings.defaults) private var proUnlocked = false
    @AppStorage(SendingOptions.Key.wholeLimit, store: AppSettings.defaults) private var wholeLimit = false
    @AppStorage(SendingOptions.Key.format, store: AppSettings.defaults) private var format = SendingOptions.Format.h264
    @AppStorage(SendingOptions.Key.pictureSize, store: AppSettings.defaults) private var pictureSize = SendingOptions.PictureSize.sharpest
    @AppStorage(SendingOptions.Key.sixtyFPS, store: AppSettings.defaults) private var sixtyFPS = false
    @AppStorage(SendingOptions.Key.allDetails, store: AppSettings.defaults) private var allDetails = false
    @State private var showPro = false

    private var isPro: Bool { previewPro ?? proUnlocked }

    var body: some View {
        List {
            if !isPro {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("These come with Shrink Pro")
                            .font(.headline)
                        Text("Sending one file at a time stays free, with the usual settings.")
                            .foregroundStyle(.secondary)
                        if proScreen != nil {
                            Button {
                                showPro = true
                            } label: {
                                Text("Get Pro").font(.headline).frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        } else {
                            Text("Open the Shrink app to get Pro.")
                                .font(.subheadline)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }

            Group {
                Section {
                    Toggle("Use the whole limit", isOn: $wholeLimit)
                } footer: {
                    Text("The file comes out just under the limit, as sharp as that size allows. It can take an extra pass.")
                }

                Section {
                    Picker("Format", selection: $format) {
                        ForEach(SendingOptions.Format.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Format")
                } footer: {
                    Text("HEVC looks better at the same size, but some Windows PCs, Android phones and websites can't play it.")
                }

                Section {
                    Picker("Picture size", selection: $pictureSize) {
                        ForEach(SendingOptions.PictureSize.allCases) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Picture size")
                } footer: {
                    Text("A smaller picture gets more detail in each pixel. A picture is never made bigger than the video's own.")
                }

                Section {
                    Toggle("Keep 60 fps", isOn: $sixtyFPS)
                } footer: {
                    Text("Smoother motion for games and sports. Without it, a tight limit drops to 30 fps so each frame stays sharper.")
                }

                Section {
                    Toggle("Keep all the details", isOn: $allDetails)
                } footer: {
                    Text("Camera, lens, date and the rest of the file's details. Videos come out as .mov files to hold them all; a few websites only take .mp4. The place still follows Remove location in Settings.")
                }
            }
            .disabled(!isPro)
        }
        .navigationTitle("Sending options")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDone {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showPro) {
            proScreen?.make(.options)
        }
    }
}

/// The trim screen's way into Sending options: what's set, or "Pro" before Pro.
struct SendingOptionsRow: View {
    let isPro: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("Sending options")
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if isPro {
                    Text(SendingOptions.saved.summary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Pro")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(.tint)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
