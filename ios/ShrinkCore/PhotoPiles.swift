import Foundation

/// Photo cleanup's piles and the rules that sort a library into them. Pure logic: the app reads Photos
/// and Vision and passes the facts in, so every rule here is tested without a library.
public enum PileKind: String, CaseIterable, Codable, Sendable {
    /// The very same picture more than once (same pixels). The only pile that comes pre-picked.
    case duplicates
    /// Several shots of one moment, taken close together. The best one is suggested to keep.
    case similar
    case screenshots
    case screenRecordings
    /// Burst photos: keep the shots picked (by the person, or by iPhone), drop the rest.
    case bursts
    /// Live Photos whose moving part can go, keeping the still photo.
    case livePhotos
    /// Memes, forwards and downloads: pictures with no camera details in the file.
    case downloads
    /// Blurry, dark and accidental shots (Vision's aesthetics score, iOS 18 and later).
    case blurry
    /// Receipts, whiteboards and documents (Vision's utility flag, iOS 18 and later).
    case utility

    /// Shown as groups (some kept, the rest offered) rather than a flat list.
    public var isGrouped: Bool { self == .duplicates || self == .similar || self == .bursts }
}

/// A picture's Vision feature print, scaled so its biggest value is 127 and stored as one signed byte
/// per value (768 bytes for Vision's current prints), so a whole library's prints fit in a small cache.
/// Scaling doesn't change the angle between two prints, which is all `distance` uses.
public struct FeatureVector: Codable, Hashable, Sendable {
    public let bytes: Data

    public init(bytes: Data) {
        self.bytes = bytes
    }

    public init?(values: [Float]) {
        let peak = values.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0, peak.isFinite else { return nil }
        bytes = Data(values.map { value in
            UInt8(bitPattern: Int8(clamping: Int((value / peak * 127).rounded())))
        })
    }

    /// The distance between the two prints once both are scaled to length 1: 0 for the same picture,
    /// growing as they differ, at most 2.
    public func distance(to other: FeatureVector) -> Float {
        guard bytes.count == other.bytes.count, !bytes.isEmpty else { return 2 }
        var dot = 0, ownSquares = 0, otherSquares = 0
        bytes.withUnsafeBytes { (own: UnsafeRawBufferPointer) in
            other.bytes.withUnsafeBytes { (theirs: UnsafeRawBufferPointer) in
                let a = own.bindMemory(to: Int8.self)
                let b = theirs.bindMemory(to: Int8.self)
                for index in 0..<a.count {
                    let x = Int(a[index]), y = Int(b[index])
                    dot += x * y
                    ownSquares += x * x
                    otherSquares += y * y
                }
            }
        }
        guard ownSquares > 0, otherSquares > 0 else { return 2 }
        let cosine = Double(dot) / (Double(ownSquares).squareRoot() * Double(otherSquares).squareRoot())
        return Float(max(0, 2 - 2 * cosine).squareRoot())
    }
}

/// Several shots of one moment: the 12 photos of one sunset.
public enum SimilarShots {
    public struct Shot: Sendable {
        public let id: String
        public let date: Date
        public let vector: FeatureVector

        public init(id: String, date: Date, vector: FeatureVector) {
            self.id = id
            self.date = date
            self.vector = vector
        }
    }

    /// How close two prints must be to count as the same moment. A starting point: check it against
    /// real libraries (Report a problem, reviews) and move it.
    public static let defaultDistance: Float = 0.5
    /// The longest pause between two shots of the same moment.
    public static let defaultGap: TimeInterval = 180

    /// Shots taken one after another (each within `maxGap` of the one before), each close to both the
    /// group's first shot and the one before it, so a group can't drift from one scene to the next.
    /// Only groups of two or more, each in time order.
    public static func groups(_ shots: [Shot], maxGap: TimeInterval = defaultGap,
                              maxDistance: Float = defaultDistance) -> [[Shot]] {
        let sorted = shots.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
        var groups: [[Shot]] = []
        var current: [Shot] = []
        for shot in sorted {
            if let first = current.first, let last = current.last,
               shot.date.timeIntervalSince(last.date) <= maxGap,
               shot.vector.distance(to: last.vector) <= maxDistance,
               shot.vector.distance(to: first.vector) <= maxDistance {
                current.append(shot)
            } else {
                if current.count >= 2 { groups.append(current) }
                current = [shot]
            }
        }
        if current.count >= 2 { groups.append(current) }
        return groups
    }
}

/// The very same picture saved more than once.
public enum Duplicates {
    public struct Candidate: Sendable {
        public let id: String
        public let width: Int
        public let height: Int
        /// `PhotoLook.differenceHash` of a small copy.
        public let hash: UInt64

        public init(id: String, width: Int, height: Int, hash: UInt64) {
            self.id = id
            self.width = width
            self.height = height
            self.hash = hash
        }
    }

    /// Possibly the same picture: same size and the same difference hash. Each group still has to be
    /// confirmed pixel by pixel (`confirmed`) before anything is called a duplicate.
    public static func candidates(_ photos: [Candidate]) -> [[String]] {
        Dictionary(grouping: photos) { "\($0.width)x\($0.height)-\($0.hash)" }
            .values
            .filter { $0.count >= 2 }
            .map { $0.map(\.id).sorted() }
            .sorted { $0[0] < $1[0] }
    }

    /// Groups whose pixel fingerprints (`PhotoLook.pixelHash`) match exactly. id → fingerprint.
    public static func confirmed(_ fingerprints: [String: String]) -> [[String]] {
        Dictionary(grouping: fingerprints.keys) { fingerprints[$0] ?? "" }
            .filter { !$0.key.isEmpty && $0.value.count >= 2 }
            .values
            .map { $0.sorted() }
            .sorted { $0[0] < $1[0] }
    }
}

/// What decides which photo of a group stays.
public struct KeepFacts: Sendable {
    public let id: String
    public let date: Date?
    public let isFavorite: Bool
    public let albumCount: Int
    public let pixels: Int
    public let bytes: Int64
    /// Vision's aesthetics score, −1 to 1 (iOS 18 and later).
    public let score: Float?

    public init(id: String, date: Date?, isFavorite: Bool = false, albumCount: Int = 0, pixels: Int = 0,
                bytes: Int64 = 0, score: Float? = nil) {
        self.id = id
        self.date = date
        self.isFavorite = isFavorite
        self.albumCount = albumCount
        self.pixels = pixels
        self.bytes = bytes
        self.score = score
    }
}

public enum Keeper {
    /// Copies of one picture: keep the favorite, then the one in the most albums, then the oldest
    /// (usually the first one saved).
    public static func forDuplicates(_ copies: [KeepFacts]) -> String? {
        copies.min { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            if a.albumCount != b.albumCount { return a.albumCount > b.albumCount }
            let dateA = a.date ?? .distantFuture, dateB = b.date ?? .distantFuture
            if dateA != dateB { return dateA < dateB }
            return a.id < b.id
        }?.id
    }

    /// Shots of one moment: suggest the favorite, then the best Vision score, then the most pixels,
    /// then the biggest file, then the first taken.
    public static func bestShot(_ shots: [KeepFacts]) -> String? {
        shots.min { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            if let scoreA = a.score, let scoreB = b.score, scoreA != scoreB { return scoreA > scoreB }
            if a.pixels != b.pixels { return a.pixels > b.pixels }
            if a.bytes != b.bytes { return a.bytes > b.bytes }
            let dateA = a.date ?? .distantFuture, dateB = b.date ?? .distantFuture
            if dateA != dateB { return dateA < dateB }
            return a.id < b.id
        }?.id
    }
}

/// Burst photos.
public enum Bursts {
    public struct Member: Sendable {
        public let id: String
        public let date: Date?
        /// The person picked it in Photos.
        public let userPick: Bool
        /// iPhone suggested it.
        public let autoPick: Bool
        /// The one Photos shows for the whole burst.
        public let representative: Bool

        public init(id: String, date: Date?, userPick: Bool, autoPick: Bool, representative: Bool) {
            self.id = id
            self.date = date
            self.userPick = userPick
            self.autoPick = autoPick
            self.representative = representative
        }
    }

    /// The shots to keep from one burst: the person's picks; without any, the one Photos shows for the
    /// burst; without that, iPhone's picks; failing all, the first shot.
    public static func keep(_ members: [Member]) -> Set<String> {
        let picked = members.filter(\.userPick)
        if !picked.isEmpty { return Set(picked.map(\.id)) }
        if let shown = members.first(where: \.representative) { return [shown.id] }
        let suggested = members.filter(\.autoPick)
        if !suggested.isEmpty { return Set(suggested.map(\.id)) }
        let first = members.min { ($0.date ?? .distantFuture, $0.id) < ($1.date ?? .distantFuture, $1.id) }
        return first.map { [$0.id] } ?? []
    }
}

public enum PhotoQuality {
    /// Below this Vision aesthetics score (−1 to 1) a photo goes in Blurry, dark and accidental.
    /// A starting point to check against real libraries.
    public static let poorScore: Float = -0.3

    /// Utility pictures (receipts, whiteboards) score low by nature, so they have their own pile.
    public static func isPoor(score: Float, isUtility: Bool) -> Bool {
        !isUtility && score < poorScore
    }
}

public enum Months {
    /// Items by the month they were taken, newest month first and newest first inside each month.
    /// Undated items come last.
    public static func sections<T>(_ items: [T], calendar: Calendar = .current,
                                   date: (T) -> Date?) -> [(start: Date?, items: [T])] {
        var byMonth: [Date: [T]] = [:]
        var undated: [T] = []
        for item in items {
            guard let taken = date(item),
                  let start = calendar.dateInterval(of: .month, for: taken)?.start else {
                undated.append(item)
                continue
            }
            byMonth[start, default: []].append(item)
        }
        var sections: [(start: Date?, items: [T])] = byMonth.keys.sorted(by: >).map { start in
            let sorted = (byMonth[start] ?? []).sorted { (date($0) ?? .distantPast) > (date($1) ?? .distantPast) }
            return (start: Optional(start), items: sorted)
        }
        if !undated.isEmpty { sections.append((start: nil, items: undated)) }
        return sections
    }
}

public enum Allowance {
    /// What fits in `left` bytes, biggest saving first (all of it when `unlimited`).
    public static func fitting<T>(_ items: [T], left: Int64, unlimited: Bool, saving: (T) -> Int64) -> [T] {
        let sorted = items.sorted { saving($0) > saving($1) }
        guard !unlimited else { return sorted }
        var room = left
        var list: [T] = []
        for item in sorted where saving(item) <= room {
            list.append(item)
            room -= saving(item)
        }
        return list
    }
}
