import Security
import StoreKit
import SwiftUI

/// Shrink Pro: unlimited Free up space, Send several at once and the sending options. Pay once ($39.99)
/// or yearly ($19.99), as App Store Connect sets the prices. No weekly plan, no trial that charges later.
/// Sending one file at a time is free for everyone, always.
@Observable
@MainActor
final class Store {
    static let shared = Store()

    /// The products as App Store Connect names them. Prices come from the App Store, never from here.
    static let lifetimeID = "com.useshrink.app.pro.lifetime"
    static let yearlyID = "com.useshrink.app.pro.yearly"

    private(set) var isPro = false
    private(set) var lifetime: Product?
    private(set) var yearly: Product?
    /// The products couldn't be loaded (offline, or not set up in App Store Connect yet).
    private(set) var unavailable = false
    var purchasing = false
    var message: String?
    /// For CI screenshots: the plan's prices, with no App Store behind them.
    private(set) var previewPrices = false

    private var updates: Task<Void, Never>?

    init() {
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                    await self?.refreshEntitlements()
                }
            }
        }
    }

    func load() async {
        await refreshEntitlements()
        guard lifetime == nil, !previewPrices else { return }
        do {
            let products = try await Product.products(for: [Self.lifetimeID, Self.yearlyID])
            lifetime = products.first { $0.id == Self.lifetimeID }
            yearly = products.first { $0.id == Self.yearlyID }
            unavailable = lifetime == nil && yearly == nil
        } catch {
            unavailable = true
        }
    }

    func refreshEntitlements() async {
        var pro = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.revocationDate == nil,
               [Self.lifetimeID, Self.yearlyID].contains(transaction.productID) {
                pro = true
            }
        }
        if !previewPrices {
            isPro = pro
            // The share sheet and the shared screens read Pro from the App Group.
            AppSettings.setPro(pro)
        }
    }

    func buy(_ product: Product) async {
        purchasing = true
        defer { purchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                if case .verified(let transaction) = result {
                    await transaction.finish()
                    await refreshEntitlements()
                } else {
                    message = "The App Store couldn't confirm that purchase. Nothing was charged twice; try Restore purchase."
                }
            case .pending:
                message = "Waiting for approval. Pro turns on as soon as it's approved."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = "The purchase didn't go through. \(error.localizedDescription)"
        }
    }

    /// Asks the App Store for this Apple Account's purchases (a new iPhone, or after reinstalling).
    func restore() async {
        purchasing = true
        defer { purchasing = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            message = isPro ? "Pro is on. Thank you!" : "No Pro purchase found for this Apple Account."
        } catch {
            message = "Couldn't reach the App Store. \(error.localizedDescription)"
        }
    }

    /// The Pro screen frozen for CI screenshots.
    static func preview() -> Store {
        let store = Store()
        store.previewPrices = true
        return store
    }
}

/// The free allowance: the first 5 GB freed is free, for life. Kept in the Keychain so deleting and
/// reinstalling the app doesn't reset it. Pro removes the limit.
enum FreeAllowance {
    static let totalBytes: Int64 = 5_000_000_000
    private static let account = "freedBytes"

    static var usedBytes: Int64 { Keychain.read(account).flatMap(Int64.init) ?? 0 }
    static var leftBytes: Int64 { max(0, totalBytes - usedBytes) }

    static func use(_ bytes: Int64) {
        Keychain.write(account, String(usedBytes + max(0, bytes)))
    }
}

/// A few small strings in the Keychain, for this app only.
enum Keychain {
    private static let service = "com.useshrink.app"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ account: String, _ value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
