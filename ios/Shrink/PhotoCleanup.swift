import ImageIO
import Photos
import ShrinkCore
import SwiftUI
import UIKit

/// Clean up photos: sorts the library into piles (duplicates, similar shots, screenshots, screen
/// recordings, bursts, Live Photos, memes and downloads, blurry shots, receipts), keeps the person's
/// picks, and (PhotoCleanupRun.swift) sends them to Recently Deleted after one check screen and iOS's
/// own prompt. Nothing is picked for them except exact duplicates.
///
/// Two passes. The first reads only Photos' records (types, dates, sizes) and fills the quick piles in
/// seconds. The second looks at each photo (a small copy through Vision, and the file's camera
/// details) and fills the rest. What it learns is saved, so next time only new photos are looked at.
@Observable
@MainActor
final class PhotoCleanup {
    enum Scan: Equatable {
        case notStarted
        case listing(checked: Int, total: Int)
        /// The quick piles are ready; the closer look is going.
        case looking(done: Int, total: Int)
        case finished
    }

    var scan: Scan = .notStarted
    private(set) var piles: [PileKind: Pile] = [:]
    /// Everything the piles offer, without counting a photo twice: what Home says they could free.
    private(set) var mayFree: Int64 = 0
    /// To go to Recently Deleted.
    var picked: Set<String> = []
    /// Live Photos to turn into still photos.
    var stills: Set<String> = []
    var run: CleanupRun = .idle
    @ObservationIgnored var runTask: Task<Void, Never>?
    /// Set when a finished run closes: Home pops back to itself.
    var requestsHome = false
    var lastRunFreed: Int64 = 0
    /// Shares Photos access with Free up space, and takes Live Photos whose stills are saved but whose
    /// originals iOS was told to keep (its "originals still in your library" row moves them later).
    let freeUp: FreeUpSpace
    private(set) var isPreview = false
    /// Every item in any pile, by id.
    private(set) var items: [String: CleanupItem] = [:]
    /// A duplicate that may go → the copy that stays (it takes over the albums and favorite).
    private(set) var keeperFor: [String: String] = [:]
    @ObservationIgnored private var records: [PhotoRecord] = []
    @ObservationIgnored private var recordings: [CleanupItem] = []
    @ObservationIgnored private var notes: [String: PhotoNotes] = [:]
    /// Exact duplicates already picked once, so un-picking one sticks after the piles refresh.
    @ObservationIgnored private var autoPicked: Set<String> = []
    @ObservationIgnored private var lookTask: Task<Void, Never>?

    init(freeUp: FreeUpSpace) {
        self.freeUp = freeUp
    }

    /// iOS 18 and later can tell blurry shots and receipts apart (Vision's aesthetics score).
    nonisolated static var qualityAvailable: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    var isLooking: Bool {
        if case .looking = scan { return true }
        return false
    }

    /// The piles to show, in order: those with something in them, plus those still filling in.
    var visibleKinds: [PileKind] {
        PileKind.allCases.filter { kind in
            if (kind == .blurry || kind == .utility) && !Self.qualityAvailable { return false }
            if let pile = piles[kind], pile.count > 0 { return true }
            return isLooking && kind.needsCloserLook
        }
    }

    // MARK: - Picks

    /// Each photo once, even when it's in two piles.
    var pickedItems: [CleanupItem] { picked.compactMap { items[$0] } }
    /// Live Photos to turn into stills, unless they're going altogether.
    var stillItems: [CleanupItem] { stills.subtracting(picked).compactMap { items[$0] } }
    var pickedCount: Int { picked.count + stills.subtracting(picked).count }
    var pickedSaving: Int64 {
        pickedItems.reduce(0) { $0 + $1.bytes } + stillItems.reduce(0) { $0 + $1.stillSaving }
    }

    struct Planned {
        let deletes: [CleanupItem]
        let stills: [CleanupItem]
        var count: Int { deletes.count + stills.count }
        var saving: Int64 { deletes.reduce(0) { $0 + $1.bytes } + stills.reduce(0) { $0 + $1.stillSaving } }
        /// Thumbnails for the check screen: what goes, then what becomes a still.
        var all: [CleanupItem] { deletes + stills }
    }

    /// What a run will do: everything picked with Pro, otherwise what fits in the free allowance
    /// (biggest saving first). Photo cleanup and video shrinking share the one free 5 GB.
    var planned: Planned {
        let choices = pickedItems.map { (item: $0, still: false) } + stillItems.map { (item: $0, still: true) }
        let fit = Allowance.fitting(choices, left: FreeAllowance.leftBytes, unlimited: Store.shared.isPro) {
            $0.still ? $0.item.stillSaving : $0.item.bytes
        }
        return Planned(deletes: fit.filter { !$0.still }.map { $0.item }, stills: fit.filter { $0.still }.map { $0.item })
    }

    var isOverAllowance: Bool { !Store.shared.isPro && pickedSaving > FreeAllowance.leftBytes }

    func isPicked(_ item: CleanupItem, in kind: PileKind) -> Bool {
        kind == .livePhotos ? stills.contains(item.id) || picked.contains(item.id) : picked.contains(item.id)
    }

    /// In the Live Photos pile a tap means "keep just the photo"; everywhere else, "delete".
    func toggle(_ item: CleanupItem, in kind: PileKind) {
        if kind == .livePhotos {
            if picked.contains(item.id) { picked.remove(item.id) } else { stills.formSymmetricDifference([item.id]) }
        } else {
            picked.formSymmetricDifference([item.id])
        }
    }

    func set(_ item: CleanupItem, in kind: PileKind, picked isPicked: Bool) {
        guard self.isPicked(item, in: kind) != isPicked else { return }
        toggle(item, in: kind)
    }

    func allPicked(_ kind: PileKind) -> Bool {
        guard let offered = piles[kind]?.offered, !offered.isEmpty else { return false }
        return offered.allSatisfy { isPicked($0, in: kind) }
    }

    func pickAll(_ kind: PileKind) {
        for item in piles[kind]?.offered ?? [] { set(item, in: kind, picked: true) }
    }

    func clearPicks(_ kind: PileKind) {
        for item in piles[kind]?.offered ?? [] { set(item, in: kind, picked: false) }
    }

    func pickedCount(in kind: PileKind) -> Int {
        (piles[kind]?.offered ?? []).filter { isPicked($0, in: kind) }.count
    }

    // MARK: - Scan

    /// Home: the quick pass once Photos access is allowed, so the card can say what photos could free.
    func refreshAndListIfNeeded() async {
        guard !isPreview, freeUp.access == .full || freeUp.access == .limited, scan == .notStarted else { return }
        await list()
    }

    /// The Clean up photos screen: the quick pass if it hasn't run, then the closer look.
    func start() async {
        guard !isPreview, freeUp.access == .full || freeUp.access == .limited else { return }
        if scan == .notStarted { await list() }
        lookCloser()
    }

    /// The first pass: Photos' records only.
    private func list() async {
        if case .listing = scan { return }
        scan = .listing(checked: 0, total: 0)
        var saved = notes
        if saved.isEmpty {
            saved = await Task.detached(priority: .utility) { NotesStore.load() }.value
        }
        let excluded = Set(freeUp.pendingOriginals.map(\.id))
        let found = await Task.detached(priority: .userInitiated) {
            Self.readLibrary(notes: saved, excluding: excluded) { checked, total in
                Task { @MainActor [weak self] in
                    guard let self, case .listing = self.scan else { return }
                    self.scan = .listing(checked: checked, total: total)
                }
            }
        }.value
        records = found.records
        recordings = found.recordings
        notes = found.notes
        await rebuildPiles()
        let waiting = records.filter { needsLook($0) }.count
        scan = waiting == 0 ? .finished : .looking(done: 0, total: waiting)
    }

    /// Photos that get the closer look: not screenshots (their own pile), not the burst shots that are
    /// dropped anyway, and not ones already looked at.
    private func needsLook(_ record: PhotoRecord) -> Bool {
        guard !record.screenshot, notes[record.id]?.looked != true else { return false }
        return record.burst == nil || record.representsBurst || record.userPick
    }

    /// The second pass, in batches, refreshing the piles as it goes. Keeps going while Shrink is open.
    private func lookCloser() {
        guard !isPreview, lookTask == nil else { return }
        let todo = records.filter { needsLook($0) }.map(\.id)
        let surelyCamera = Set(records.filter(\.surelyCamera).map(\.id))
        lookTask = Task { [weak self] in
            let batch = 120
            var done = 0
            var start = 0
            while start < todo.count {
                if Task.isCancelled { break }
                let chunk = Array(todo[start..<min(start + batch, todo.count)])
                start += batch
                let looked = await Task.detached(priority: .utility) {
                    Self.look(at: chunk, surelyCamera: surelyCamera)
                }.value
                guard let self else { return }
                for id in chunk {
                    self.notes[id]?.apply(looked[id])
                }
                done += chunk.count
                self.scan = .looking(done: done, total: todo.count)
                if done % (batch * 5) < batch || done == todo.count {
                    await self.rebuildPiles()
                    self.saveNotes()
                }
            }
            guard let self else { return }
            await self.confirmDuplicates()
            await self.rebuildPiles()
            self.saveNotes()
            self.scan = .finished
            self.lookTask = nil
        }
    }

    private func saveNotes() {
        let snapshot = notes
        Task.detached(priority: .utility) { NotesStore.save(snapshot) }
    }

    /// Duplicate candidates (same size, same hash) checked pixel by pixel. Only these files are read whole.
    private func confirmDuplicates() async {
        let candidates = Duplicates.candidates(records.compactMap { record in
            guard let hash = notes[record.id]?.hash else { return nil }
            return Duplicates.Candidate(id: record.id, width: record.width, height: record.height,
                                        hash: UInt64(bitPattern: hash))
        })
        let ids = candidates.flatMap { $0 }.filter { notes[$0]?.pixels == nil }
        guard !ids.isEmpty else { return }
        let hashes = await Task.detached(priority: .utility) { Self.pixelHashes(ids) }.value
        for (id, hash) in hashes { notes[id]?.pixels = hash }
    }

    private func rebuildPiles() async {
        let input = (records, recordings, notes)
        let built = await Task.detached(priority: .userInitiated) {
            Self.buildPiles(records: input.0, recordings: input.1, notes: input.2, qualityAvailable: Self.qualityAvailable)
        }.value
        apply(built)
    }

    private func apply(_ built: BuiltPiles) {
        piles = built.piles
        items = built.items
        keeperFor = built.keeperFor
        mayFree = built.mayFree
        // Exact duplicates come pre-picked, once each.
        let fresh = Set(keeperFor.keys).subtracting(autoPicked)
        picked.formUnion(fresh)
        autoPicked.formUnion(fresh)
        picked = picked.filter { items[$0] != nil }
        stills = stills.filter { items[$0] != nil }
    }

    /// After a run: what went leaves the piles.
    func removeFromPiles(_ ids: Set<String>) async {
        records.removeAll { ids.contains($0.id) }
        recordings.removeAll { ids.contains($0.id) }
        for id in ids { notes[id] = nil }
        picked.subtract(ids)
        stills.subtract(ids)
        await rebuildPiles()
        saveNotes()
    }

    // MARK: - Reading Photos (off the main thread)

    /// Every photo's record (and every screen recording), with sizes from the saved notes when the
    /// photo hasn't changed since.
    nonisolated private static func readLibrary(notes: [String: PhotoNotes], excluding: Set<String>,
                                                progress: @escaping (Int, Int) -> Void)
        -> (records: [PhotoRecord], recordings: [CleanupItem], notes: [String: PhotoNotes]) {
        let options = PHFetchOptions()
        options.includeAllBurstAssets = true
        options.includeAssetSourceTypes = [.typeUserLibrary]
        let photos = PHAsset.fetchAssets(with: .image, options: options)
        let videoOptions = PHFetchOptions()
        videoOptions.includeAssetSourceTypes = [.typeUserLibrary]
        let videos = PHAsset.fetchAssets(with: .video, options: videoOptions)
        let total = photos.count + videos.count
        var records: [PhotoRecord] = []
        records.reserveCapacity(photos.count)
        var fresh: [String: PhotoNotes] = [:]
        for index in 0..<photos.count {
            if index % 200 == 0 { progress(index, total) }
            autoreleasepool {
                let asset = photos.object(at: index)
                let id = asset.localIdentifier
                guard !excluding.contains(id) else { return }
                var note = notes[id] ?? PhotoNotes(width: asset.pixelWidth, height: asset.pixelHeight)
                if note.width != asset.pixelWidth || note.height != asset.pixelHeight {
                    // Cropped or replaced: look at it again.
                    note = PhotoNotes(width: asset.pixelWidth, height: asset.pixelHeight)
                }
                if note.bytes < 0 || note.modified != asset.modificationDate {
                    let sizes = Self.sizes(of: asset)
                    note.bytes = sizes.total
                    note.stillSaving = sizes.stillSaving
                    note.modified = asset.modificationDate
                }
                fresh[id] = note
                let subtypes = asset.mediaSubtypes
                let live = subtypes.contains(.photoLive) && asset.playbackStyle == .livePhoto
                records.append(PhotoRecord(
                    id: id, created: asset.creationDate, width: asset.pixelWidth, height: asset.pixelHeight,
                    bytes: note.bytes, favorite: asset.isFavorite, screenshot: subtypes.contains(.photoScreenshot),
                    live: live, stillSaving: live ? note.stillSaving : 0, burst: asset.burstIdentifier,
                    userPick: asset.burstSelectionTypes.contains(.userPick),
                    autoPick: asset.burstSelectionTypes.contains(.autoPick),
                    representsBurst: asset.representsBurst,
                    surelyCamera: asset.location != nil || live || asset.burstIdentifier != nil
                        || subtypes.contains(.photoDepthEffect) || subtypes.contains(.photoHDR)
                        || subtypes.contains(.photoPanorama)
                ))
            }
        }
        var recordings: [CleanupItem] = []
        for index in 0..<videos.count {
            if index % 200 == 0 { progress(photos.count + index, total) }
            let asset = videos.object(at: index)
            guard asset.mediaSubtypes.contains(.videoScreenRecording), !excluding.contains(asset.localIdentifier) else { continue }
            let bytes = Self.sizes(of: asset).total
            guard bytes > 0 else { continue }
            recordings.append(CleanupItem(id: asset.localIdentifier, created: asset.creationDate, bytes: bytes,
                                          isVideo: true, duration: asset.duration, isFavorite: asset.isFavorite,
                                          stillSaving: 0))
        }
        progress(total, total)
        return (records, recordings, fresh)
    }

    /// Photos doesn't publish file sizes; each resource record carries one under "fileSize" (as Free up
    /// space reads videos). For a Live Photo, what turning it into a still frees: everything but the
    /// photo it keeps.
    nonisolated static func sizes(of asset: PHAsset) -> (total: Int64, stillSaving: Int64) {
        let resources = PHAssetResource.assetResources(for: asset)
        var total: Int64 = 0, photo: Int64 = 0, fullSize: Int64 = 0
        var hasMotion = false
        for resource in resources {
            let bytes = (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
            total += bytes
            switch resource.type {
            case .photo: photo = bytes
            case .fullSizePhoto: fullSize = bytes
            case .pairedVideo: hasMotion = true
            default: break
            }
        }
        let kept = fullSize > 0 ? fullSize : photo
        return (total, hasMotion && kept > 0 ? max(0, total - kept) : 0)
    }

    struct LookResult: Sendable {
        var hash: Int64?
        var vector: Data?
        var score: Float?
        var utility: Bool?
        var camera: Bool?
    }

    /// The closer look at a batch: a small copy (Photos keeps one on the iPhone even for iCloud photos)
    /// through Vision, and the original file's camera details when it's on the iPhone. Nothing is
    /// downloaded from iCloud for this.
    nonisolated private static func look(at ids: [String], surelyCamera: Set<String>) -> [String: LookResult] {
        PhotoLook.checkVision()
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        let manager = PHImageManager.default()
        let imageOptions = PHImageRequestOptions()
        imageOptions.isSynchronous = true
        imageOptions.deliveryMode = .highQualityFormat
        imageOptions.resizeMode = .fast
        imageOptions.isNetworkAccessAllowed = false
        imageOptions.version = .current
        let dataOptions = PHImageRequestOptions()
        dataOptions.isSynchronous = true
        dataOptions.isNetworkAccessAllowed = false
        dataOptions.version = .original
        var results: [String: LookResult] = [:]
        assets.enumerateObjects { asset, _, _ in
            autoreleasepool {
                let result = Carried(LookResult())
                manager.requestImage(for: asset, targetSize: CGSize(width: 360, height: 360), contentMode: .aspectFit,
                                     options: imageOptions) { image, _ in
                    guard let image, let picture = image.cgImage else { return }
                    let orientation = CGImagePropertyOrientation(image.imageOrientation)
                    result.value.hash = PhotoLook.differenceHash(picture).map { Int64(bitPattern: $0) }
                    result.value.vector = (try? PhotoLook.featureVector(picture, orientation: orientation))?.bytes
                    if let quality = try? PhotoLook.quality(picture, orientation: orientation) {
                        result.value.score = quality.score
                        result.value.utility = quality.isUtility
                    }
                }
                if surelyCamera.contains(asset.localIdentifier) {
                    result.value.camera = true
                } else {
                    manager.requestImageDataAndOrientation(for: asset, options: dataOptions) { data, _, _, _ in
                        if let data { result.value.camera = PhotoLook.hasCameraDetails(data) }
                    }
                }
                results[asset.localIdentifier] = result.value
            }
        }
        return results
    }

    /// Each candidate's whole picture, decoded and fingerprinted. Skipped (nil) when it's only in iCloud.
    nonisolated private static func pixelHashes(_ ids: [String]) -> [String: String] {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.isNetworkAccessAllowed = false
        options.version = .current
        let hashes = Carried([String: String]())
        assets.enumerateObjects { asset, _, _ in
            autoreleasepool {
                let id = asset.localIdentifier
                PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, orientation, _ in
                    guard let data, let picture = PhotoLook.decode(data), let hash = PhotoLook.pixelHash(picture) else { return }
                    hashes.value[id] = "\(hash)-\(orientation.rawValue)"
                }
            }
        }
        return hashes.value
    }

    // MARK: - Piles (off the main thread)

    struct BuiltPiles: Sendable {
        var piles: [PileKind: Pile] = [:]
        var items: [String: CleanupItem] = [:]
        var keeperFor: [String: String] = [:]
        var mayFree: Int64 = 0
    }

    nonisolated static func buildPiles(records: [PhotoRecord], recordings: [CleanupItem],
                                       notes: [String: PhotoNotes], qualityAvailable: Bool) -> BuiltPiles {
        var built = BuiltPiles()
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func item(_ record: PhotoRecord) -> CleanupItem {
            CleanupItem(id: record.id, created: record.created, bytes: record.bytes, isVideo: false, duration: 0,
                        isFavorite: record.favorite, stillSaving: record.stillSaving)
        }
        func newestFirst(_ list: [CleanupItem]) -> [CleanupItem] {
            list.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
        }
        func facts(_ record: PhotoRecord, albums: Int = 0) -> KeepFacts {
            KeepFacts(id: record.id, date: record.created, isFavorite: record.favorite, albumCount: albums,
                      pixels: record.width * record.height, bytes: record.bytes, score: notes[record.id]?.score)
        }
        var piles: [PileKind: Pile] = [:]

        piles[.screenshots] = Pile(kind: .screenshots, items: newestFirst(records.filter(\.screenshot).map(item)))
        piles[.screenRecordings] = Pile(kind: .screenRecordings, items: newestFirst(recordings))
        piles[.livePhotos] = Pile(kind: .livePhotos, items: newestFirst(records.filter { $0.live && $0.stillSaving > 0 }.map(item)))
        piles[.downloads] = Pile(kind: .downloads, items: newestFirst(records.filter {
            !$0.screenshot && notes[$0.id]?.camera == false
        }.map(item)))
        if qualityAvailable {
            piles[.blurry] = Pile(kind: .blurry, items: newestFirst(records.filter { record in
                guard !record.screenshot, let note = notes[record.id], let score = note.score else { return false }
                return PhotoQuality.isPoor(score: score, isUtility: note.utility ?? false)
            }.map(item)))
            piles[.utility] = Pile(kind: .utility, items: newestFirst(records.filter {
                !$0.screenshot && notes[$0.id]?.utility == true
            }.map(item)))
        }

        // Bursts: keep the picks, offer the rest.
        var burstExtras: Set<String> = []
        var burstGroups: [CleanupGroup] = []
        for (burst, members) in Dictionary(grouping: records.filter { $0.burst != nil }, by: { $0.burst ?? "" }) {
            guard members.count >= 2 else { continue }
            let keep = Bursts.keep(members.map {
                Bursts.Member(id: $0.id, date: $0.created, userPick: $0.userPick, autoPick: $0.autoPick,
                              representative: $0.representsBurst)
            })
            let sorted = members.sorted { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
            guard sorted.contains(where: { !keep.contains($0.id) }) else { continue }
            burstExtras.formUnion(sorted.map(\.id).filter { !keep.contains($0) })
            burstGroups.append(CleanupGroup(id: burst, keeps: keep, items: sorted.map(item)))
        }
        piles[.bursts] = Pile(kind: .bursts, groups: burstGroups.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) })

        // Exact duplicates: same pixels. The copy that stays takes over the others' albums and favorite.
        var fingerprints: [String: String] = [:]
        for record in records { if let pixels = notes[record.id]?.pixels { fingerprints[record.id] = pixels } }
        var duplicateGroups: [CleanupGroup] = []
        var duplicateExtras: Set<String> = []
        for ids in Duplicates.confirmed(fingerprints) {
            let members = ids.compactMap { byID[$0] }
            guard members.count >= 2 else { continue }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            var albums: [String: Int] = [:]
            assets.enumerateObjects { asset, _, _ in
                albums[asset.localIdentifier] = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil).count
            }
            guard let keeper = Keeper.forDuplicates(members.map { facts($0, albums: albums[$0.id] ?? 0) }) else { continue }
            let ordered = members.sorted { a, b in
                if a.id == b.id { return false }
                if a.id == keeper { return true }
                if b.id == keeper { return false }
                return a.id < b.id
            }
            for member in ordered where member.id != keeper {
                built.keeperFor[member.id] = keeper
                duplicateExtras.insert(member.id)
            }
            duplicateGroups.append(CleanupGroup(id: "dup-\(keeper)", keeps: [keeper], items: ordered.map(item)))
        }
        piles[.duplicates] = Pile(kind: .duplicates, groups: duplicateGroups.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) })

        // Similar shots: one moment, several shots; the best one suggested to keep.
        let shots: [SimilarShots.Shot] = records.compactMap { record in
            guard !record.screenshot, !duplicateExtras.contains(record.id), !burstExtras.contains(record.id),
                  let date = record.created, let vector = notes[record.id]?.vector else { return nil }
            return SimilarShots.Shot(id: record.id, date: date, vector: FeatureVector(bytes: vector))
        }
        var similarGroups: [CleanupGroup] = []
        for group in SimilarShots.groups(shots) {
            let members = group.compactMap { byID[$0.id] }
            guard members.count >= 2, let best = Keeper.bestShot(members.map { facts($0) }) else { continue }
            similarGroups.append(CleanupGroup(id: "similar-\(members[0].id)", keeps: [best], items: members.map(item)))
        }
        piles[.similar] = Pile(kind: .similar, groups: similarGroups.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) })

        // What it could all free, each photo once.
        var counted: Set<String> = []
        var mayFree: Int64 = 0
        for (kind, pile) in piles where kind != .livePhotos {
            for item in pile.offered where counted.insert(item.id).inserted { mayFree += item.bytes }
        }
        for item in piles[.livePhotos]?.items ?? [] where !counted.contains(item.id) { mayFree += item.stillSaving }

        for pile in piles.values {
            for item in pile.items { built.items[item.id] = item }
            for group in pile.groups { for item in group.items { built.items[item.id] = item } }
        }
        built.piles = piles
        built.mayFree = mayFree
        return built
    }
}

/// One photo or recording a pile offers.
struct CleanupItem: Identifiable, Hashable, Sendable {
    /// The Photos library's id for it.
    let id: String
    let created: Date?
    /// The whole thing, every file Photos keeps for it.
    let bytes: Int64
    let isVideo: Bool
    let duration: Double
    let isFavorite: Bool
    /// Live Photos: what turning it into a still photo frees.
    let stillSaving: Int64
}

/// Duplicates, similar shots or a burst: the ones that stay, and the rest.
struct CleanupGroup: Identifiable, Hashable, Sendable {
    let id: String
    let keeps: Set<String>
    /// In time order (duplicates: the one that stays first).
    let items: [CleanupItem]
    var extras: [CleanupItem] { items.filter { !keeps.contains($0.id) } }
    var date: Date? { items.first?.created }
}

struct Pile: Sendable {
    let kind: PileKind
    /// Flat piles, newest first.
    var items: [CleanupItem] = []
    /// Grouped piles, newest first.
    var groups: [CleanupGroup] = []

    /// What could go: every item of a flat pile, the extras of a grouped one.
    var offered: [CleanupItem] { kind.isGrouped ? groups.flatMap(\.extras) : items }
    var count: Int { offered.count }
    var bytes: Int64 {
        kind == .livePhotos ? items.reduce(0) { $0 + $1.stillSaving } : offered.reduce(0) { $0 + $1.bytes }
    }
}

/// What the quick pass reads about each photo.
struct PhotoRecord: Sendable {
    let id: String
    let created: Date?
    let width: Int
    let height: Int
    let bytes: Int64
    let favorite: Bool
    let screenshot: Bool
    let live: Bool
    let stillSaving: Int64
    let burst: String?
    let userPick: Bool
    let autoPick: Bool
    let representsBurst: Bool
    /// Only a camera makes these (or records a place), so there's no need to read the file for camera details.
    let surelyCamera: Bool
}

/// What photo cleanup learned about one photo, kept between launches.
struct PhotoNotes: Codable, Sendable {
    var modified: Date?
    var width: Int
    var height: Int
    /// -1 until read.
    var bytes: Int64 = -1
    var stillSaving: Int64 = 0
    var looked = false
    /// Difference hash, as its bit pattern.
    var hash: Int64?
    var vector: Data?
    var score: Float?
    var utility: Bool?
    var camera: Bool?
    /// Pixel fingerprint, only for possible duplicates.
    var pixels: String?

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    mutating func apply(_ result: PhotoCleanup.LookResult?) {
        looked = true
        guard let result else { return }
        hash = result.hash
        vector = result.vector
        score = result.score
        utility = result.utility
        camera = result.camera
    }
}

/// The notes in Application Support (not Caches: iOS clears Caches exactly when space runs low, which is
/// when someone opens a cleanup app).
enum NotesStore {
    private static var url: URL? {
        guard let folder = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true) else { return nil }
        return folder.appendingPathComponent("photo-notes.plist")
    }

    static func load() -> [String: PhotoNotes] {
        guard let url, let data = try? Data(contentsOf: url),
              let notes = try? PropertyListDecoder().decode([String: PhotoNotes].self, from: data) else { return [:] }
        return notes
    }

    static func save(_ notes: [String: PhotoNotes]) {
        guard let url else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(notes) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

extension PileKind {
    /// What the pile is, in the person's words.
    var title: String {
        switch self {
        case .duplicates: "Duplicates"
        case .similar: "Similar shots"
        case .screenshots: "Screenshots"
        case .screenRecordings: "Screen recordings"
        case .bursts: "Bursts"
        case .livePhotos: "Live Photos"
        case .downloads: "Memes, forwards and downloads"
        case .blurry: "Blurry, dark and accidental"
        case .utility: "Receipts and whiteboards"
        }
    }

    /// One line under the title on the pile's screen.
    var explanation: String {
        switch self {
        case .duplicates: "The very same picture saved more than once. The copy that stays keeps the albums and favorite of the ones that go."
        case .similar: "Several shots of one moment. The best one is marked; pick the others you don't need."
        case .screenshots: "Screenshots you've taken, newest first."
        case .screenRecordings: "Recordings of your screen, newest first."
        case .bursts: "Burst shots. The ones you or iPhone picked stay; the rest can go."
        case .livePhotos: "Keep just the photo and drop the moving part. The photo keeps its date, place, favorite and albums."
        case .downloads: "Pictures saved from chats and the web: no camera took them."
        case .blurry: "Photos that came out blurry, dark or by accident."
        case .utility: "Receipts, documents and whiteboards you photographed."
        }
    }

    var icon: String {
        switch self {
        case .duplicates: "square.on.square"
        case .similar: "square.stack.3d.up"
        case .screenshots: "camera.viewfinder"
        case .screenRecordings: "record.circle"
        case .bursts: "square.stack"
        case .livePhotos: "livephoto"
        case .downloads: "arrow.down.circle"
        case .blurry: "eye.slash"
        case .utility: "doc.text"
        }
    }

    /// Filled in by the closer look rather than the quick pass.
    var needsCloserLook: Bool {
        switch self {
        case .duplicates, .similar, .downloads, .blurry, .utility: true
        default: false
        }
    }
}

/// Carries a value out of a Photos callback (the requests here are synchronous, so it's read after).
final class Carried<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

// MARK: - Screenshots

extension PhotoCleanup {
    /// Clean up photos frozen in one state, for CI screenshots. No library is read; the pictures are
    /// made up (PreviewArt).
    static func preview(access: FreeUpSpace.Access = .full, looking: Bool = false,
                        freeUp: FreeUpSpace? = nil) -> PhotoCleanup {
        let model = PhotoCleanup(freeUp: freeUp ?? .preview(access: access))
        model.isPreview = true
        model.scan = access == .notAsked ? .notStarted : (looking ? .looking(done: 4_210, total: 12_000) : .finished)
        let day: TimeInterval = 86_400
        var counter = 0
        func items(_ count: Int, every spacing: TimeInterval, from start: TimeInterval, bytes: Int64,
                   video: Bool = false, still: Int64 = 0) -> [CleanupItem] {
            (0..<count).map { step in
                counter += 1
                return CleanupItem(id: "preview-p\(counter)",
                                   created: Date(timeIntervalSinceNow: -(start + Double(step) * spacing)),
                                   bytes: bytes + Int64((counter * 7_919) % 900_000), isVideo: video,
                                   duration: video ? Double(30 + counter % 200) : 0, isFavorite: counter % 17 == 0,
                                   stillSaving: still)
            }
        }
        func group(_ count: Int, at start: TimeInterval, bytes: Int64, keep: Int = 0) -> CleanupGroup {
            let list = items(count, every: 8, from: start, bytes: bytes)
            return CleanupGroup(id: "preview-g\(counter)", keeps: [list[keep].id], items: list)
        }
        let duplicates = [group(2, at: 3 * day, bytes: 3_100_000), group(3, at: 40 * day, bytes: 2_400_000)]
        let screenshots = items(42, every: 1.7 * day, from: 0.2 * day, bytes: 1_100_000)
        let live = items(30, every: 2.5 * day, from: 0.5 * day, bytes: 4_600_000, still: 2_300_000)
        var piles: [PileKind: Pile] = [:]
        piles[.screenshots] = Pile(kind: .screenshots, items: screenshots)
        piles[.screenRecordings] = Pile(kind: .screenRecordings,
                                        items: items(3, every: 20 * day, from: 5 * day, bytes: 180_000_000, video: true))
        piles[.bursts] = Pile(kind: .bursts, groups: [group(9, at: 14 * day, bytes: 2_200_000, keep: 4)])
        piles[.livePhotos] = Pile(kind: .livePhotos, items: live)
        piles[.downloads] = Pile(kind: .downloads, items: items(looking ? 6 : 25, every: 3 * day, from: day, bytes: 400_000))
        if !looking {
            piles[.duplicates] = Pile(kind: .duplicates, groups: duplicates)
            piles[.similar] = Pile(kind: .similar, groups: [
                group(6, at: day, bytes: 3_400_000, keep: 2),
                group(4, at: 9 * day, bytes: 2_900_000, keep: 1),
                group(5, at: 33 * day, bytes: 3_800_000),
            ])
            if qualityAvailable {
                piles[.blurry] = Pile(kind: .blurry, items: items(12, every: 6 * day, from: 2 * day, bytes: 2_600_000))
                piles[.utility] = Pile(kind: .utility, items: items(9, every: 8 * day, from: 4 * day, bytes: 1_900_000))
            }
            for group in duplicates {
                for extra in group.extras { model.keeperFor[extra.id] = group.keeps.first }
            }
            model.picked = Set(duplicates.flatMap(\.extras).map(\.id))
        }
        model.picked.formUnion(screenshots.prefix(6).map(\.id))
        model.stills = Set(live.prefix(2).map(\.id))
        model.piles = piles
        var all: [String: CleanupItem] = [:]
        for pile in piles.values {
            for item in pile.items { all[item.id] = item }
            for group in pile.groups { for item in group.items { all[item.id] = item } }
        }
        model.items = all
        model.mayFree = piles.filter { $0.key != .livePhotos }.values.reduce(Int64(0)) { $0 + $1.bytes }
            + (piles[.livePhotos]?.bytes ?? 0)
        return model
    }

    /// The run screen frozen in one state.
    static func previewRun(_ state: String) -> PhotoCleanup {
        let model = preview()
        switch state {
        case "cleanup-done":
            model.run = .finished(CleanupSummary(deleted: 46, stills: 12, freedBytes: 1_840_000_000, declined: false,
                                                 problems: []))
        case "cleanup-declined":
            model.run = .finished(CleanupSummary(deleted: 0, stills: 3, freedBytes: 0, declined: true, problems: []))
        default:
            model.run = .working(done: 3, count: 12)
        }
        return model
    }
}
