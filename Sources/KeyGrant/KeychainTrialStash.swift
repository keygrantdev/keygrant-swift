#if canImport(Security)
import Foundation
import Security

/// A registry stash in the Keychain: the trial start kept as a generic-password item, which
/// survives the app being deleted (the Apple analogue of the Windows registry stash), so a
/// reinstall cannot restart a trial. The default on iOS and iPadOS, where every app has the data
/// protection keychain; on a Mac (a Mac Catalyst app's included), opt in by giving it as
/// `LicenseAdapters.registry`.
///
/// It only ever moves the start earlier, and writes only on what it could read: an item that
/// cannot be read is left alone (`StashedTrialStart`). A failure (a keychain that is locked, an app
/// without the entitlement the data protection keychain needs) costs nothing: the SDK reads it as
/// no stash, and the trial falls back on the server's record and the state file.
public struct KeychainTrialStash: RegistryStash {
    /// Which keychain holds the item.
    public enum Keychain: Sendable, Hashable {
        /// The data protection keychain: no access prompts, ever. Needs an app with an application
        /// identifier (an App Store app, or one signed with a provisioning profile).
        case dataProtection
        /// The login keychain: any native Mac app, but an item made by one signature may prompt when
        /// a build signed differently (an ad-hoc development build) reads it. A Mac Catalyst app has
        /// only the data protection keychain, so there this needs the application identifier
        /// `dataProtection` does.
        case login
    }

    public let service: String
    public let account: String
    public let keychain: Keychain

    /// A stash for `product`, under `service` (one per vendor is plenty).
    public init(product: String, service: String = "dev.keygrant.trial", keychain: Keychain = .dataProtection) {
        self.service = service
        account = product
        self.keychain = keychain
    }

    /// How long a read or a write may hold its caller. The SDK bounds no registry stash (its own
    /// calls wait for one), and this one is the default on iOS, so it bounds itself: past it, a read
    /// is no stash, as when the Keychain is locked, and a write is left to finish on its own.
    static let callTimeout: TimeInterval = 5

    public func readTrialStart() async throws -> Int? {
        try await StashedTrialStart.read(item, within: Self.callTimeout, on: SystemTicker())
    }

    public func writeTrialStart(_ ms: Int) async throws {
        try await StashedTrialStart.write(ms, to: item, within: Self.callTimeout, on: SystemTicker())
    }

    private var item: KeychainItem {
        KeychainItem(service: service, account: account, keychain: keychain)
    }
}

/// The generic-password item a `KeychainTrialStash` keeps its start in, through the Keychain's
/// own calls.
struct KeychainItem: StashItem {
    let service: String
    let account: String
    let keychain: KeychainTrialStash.Keychain

    // Each call runs on a thread of its own (`blocking`), as a file's do: the Keychain's calls block
    // for as long as its daemon takes, and a bound can then abandon one.

    func data() async throws -> Data? {
        try await blocking { try copyData() }
    }

    func add(_ data: Data) async throws {
        try await blocking { try addItem(data) }
    }

    func update(_ data: Data) async throws {
        try await blocking { try updateItem(data) }
    }

    private func copyData() throws -> Data? {
        var query = itemQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        // An item with no data holds no start: replaced by the next write.
        return result as? Data ?? Data()
    }

    private func addItem(_ data: Data) throws {
        var item = itemQuery()
        item[kSecValueData as String] = data
        if let accessible { item[kSecAttrAccessible as String] = accessible }
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func updateItem(_ data: Data) throws {
        let change = [kSecValueData as String: data]
        let status = SecItemUpdate(itemQuery() as CFDictionary, change as CFDictionary)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// When a new item may be read. On iOS and iPadOS, whichever keychain is named (a phone has one):
    /// after the device's first unlock, on this device only, so neither iCloud nor a backup restored
    /// onto another device carries it (contract 4.1). On a Mac (a Mac Catalyst app's included), after
    /// the first unlock for `.dataProtection`, and the keychain's own default for `.login`.
    var accessible: CFString? {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #else
        return keychain == .dataProtection ? kSecAttrAccessibleAfterFirstUnlock : nil
        #endif
    }

    private func itemQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if keychain == .dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }
}

/// A Keychain call that failed, with its `OSStatus`.
public struct KeychainError: Error, Sendable, Hashable {
    public let status: OSStatus
}
#endif
