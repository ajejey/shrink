import PhotosUI
import ShrinkCore

/// Where the file is going: a preset from presets.json, a limit the person typed, or "make it a JPG".
struct Destination: Identifiable, Hashable {
    let id: String
    /// The job in the person's words: "Compress for Discord".
    let title: String
    /// The place alone ("Discord", "JPG"), for Home's one-tap buttons.
    let shortTitle: String
    /// nil means no size limit (converting to JPG only).
    let limitBytes: Int64?
    /// "20 MB", written the way the platform writes its limit.
    let limitLabel: String?
    let takesVideos: Bool
    let takesPhotos: Bool

    init(preset: Preset) {
        id = preset.id
        title = preset.title
        shortTitle = preset.short ?? preset.title
        limitBytes = preset.limitBytes
        limitLabel = preset.limitLabel
        takesVideos = preset.appliesToVideo
        takesPhotos = preset.appliesToPhoto
    }

    init(id: String, title: String, shortTitle: String, limitBytes: Int64?, limitLabel: String?,
         takesVideos: Bool, takesPhotos: Bool) {
        self.id = id
        self.title = title
        self.shortTitle = shortTitle
        self.limitBytes = limitBytes
        self.limitLabel = limitLabel
        self.takesVideos = takesVideos
        self.takesPhotos = takesPhotos
    }

    /// Every preset with a limit, in the file's order.
    static let presets: [Destination] = Presets.all.filter { $0.limitBytes != nil }.map(Destination.init(preset:))

    /// HEIC photos from an iPhone, made into JPGs that open on Windows, Android and every website.
    static let jpg = Destination(id: "jpg", title: "Convert a photo to JPG", shortTitle: "JPG", limitBytes: nil,
                                 limitLabel: nil, takesVideos: false, takesPhotos: true)

    /// A limit the person typed, for a form or site that states its own ("Max file size: 2 MB").
    static func typed(_ limit: TypedLimit) -> Destination {
        Destination(id: "typed-\(limit.bytes)", title: "Under \(limit.label)", shortTitle: "Under \(limit.label)",
                    limitBytes: limit.bytes, limitLabel: limit.label, takesVideos: true, takesPhotos: true)
    }

    /// A preset or "Convert a photo to JPG" by its id; nil for typed limits and anything since removed.
    static func find(id: String) -> Destination? {
        if id == jpg.id { return jpg }
        return presets.first { $0.id == id }
    }

    /// What the Photos picker shows for this destination.
    var pickerFilter: PHPickerFilter {
        switch (takesVideos, takesPhotos) {
        case (true, false): return .videos
        case (false, true): return .images
        default: return .any(of: [.videos, .images])
        }
    }
}

/// A size limit typed as a number and a unit. Decimal units (1 MB = 1,000,000 bytes), so the file
/// also fits sites that mean the slightly bigger 1,048,576.
struct TypedLimit: Equatable {
    enum Unit: String, CaseIterable, Identifiable {
        case kb = "KB", mb = "MB", gb = "GB"
        var id: String { rawValue }
        var bytes: Double {
            switch self {
            case .kb: return 1_000
            case .mb: return 1_000_000
            case .gb: return 1_000_000_000
            }
        }
    }

    let amount: Double
    let unit: Unit

    var bytes: Int64 { Int64((amount * unit.bytes).rounded(.down)) }
    /// "2 MB", "1.5 GB", "500 KB".
    var label: String {
        let number = amount.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
        return "\(number) \(unit.rawValue)"
    }

    /// Reads what the person typed ("2", "1.5", "1,5"). nil when it isn't a usable limit.
    init?(text: String, unit: Unit) {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let amount = Double(cleaned), amount.isFinite, amount > 0 else { return nil }
        // Below 10 KB nothing useful fits; above 4 GB is no limit for anything we make.
        let bytes = amount * unit.bytes
        guard bytes >= 10_000, bytes <= 4_000_000_000 else { return nil }
        self.amount = amount
        self.unit = unit
    }
}
