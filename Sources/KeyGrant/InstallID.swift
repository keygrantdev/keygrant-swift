import Foundation

#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit
#endif

/// The Keychain service an iPhone's or iPad's install id is kept under, one item a product (its
/// account the product slug): contract 4.1.
let installIdService = "dev.keygrant.install"

/// What an iPhone or iPad is to KeyGrant (contract 4.1): an install id kept as the text of a stash
/// item, its Keychain item on iOS and iPadOS (`keychain(product:)`). It survives the app being
/// deleted and installed again; a phone has no machine id an app may read, and no host name worth
/// the name.
enum InstallId {
    /// The id `item` holds. The first read that finds none writes one, `seed()` upper-cased, and the
    /// id is then what the item holds: when another read wrote one first, theirs. Throws when the
    /// item cannot be read or written (a device locked since it started), never handing back the
    /// seed in its place, so a device has one id.
    static func read(_ item: some StashItem, seed: () async -> String) async throws -> String {
        let stored = try await item.data()
        if let id = text(stored) { return id }
        let value = Data(await seed().uppercased().utf8)
        do {
            // An item holding no text is replaced, as a trial stash replaces one holding no start.
            if stored == nil { try await item.add(value) } else { try await item.update(value) }
        } catch {
            // Another read wrote one first: that one is the install's.
            guard let id = text(try await item.data()) else { throw error }
            return id
        }
        guard let id = text(try await item.data()) else { throw InstallIdNotKept() }
        return id
    }

    /// What a new install id is written from: the device's `identifierForVendor` (`vendor`), else,
    /// when iOS gives none (the device not yet unlocked since it started, say), a random UUID.
    static func seed(vendor: String?) -> String {
        vendor ?? UUID().uuidString
    }

    /// The text an item's data holds, or nil when it holds none.
    private static func text(_ data: Data?) -> String? {
        guard let data, let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }
}

/// An install id was written, and then was not there to read back.
struct InstallIdNotKept: Error, Sendable {}

#if canImport(Security)
extension InstallId {
    /// The Keychain item `product`'s install id is kept in: service `installIdService`, account the
    /// product slug, in the data protection keychain (on iOS and iPadOS accessible after first
    /// unlock on this device only, so neither iCloud nor a backup restored onto another device
    /// carries it: `KeychainItem`).
    static func item(product: String) -> KeychainItem {
        KeychainItem(service: installIdService, account: product, keychain: .dataProtection)
    }
}
#endif

// Not in a Mac Catalyst app, which reads the Mac's id: on a Mac, the data protection keychain needs
// a provisioning profile not every app is signed with.
#if os(iOS) && !targetEnvironment(macCatalyst)
extension InstallId {
    /// This iPhone's or iPad's install id for `product`: its Keychain item (`item(product:)`),
    /// written the first time from `identifierForVendor`, else a random UUID (`seed(vendor:)`).
    static func keychain(product: String) async throws -> String {
        return try await read(item(product: product)) {
            let vendor = await MainActor.run { UIDevice.current.identifierForVendor?.uuidString }
            return seed(vendor: vendor)
        }
    }
}
#endif
