import Foundation
import Testing

@testable import KeyGrant

#if canImport(Security)
import Security
#endif

/// An iPhone's install id, as the Keychain keeps it (`identifierForVendor`'s text), and the
/// fingerprint it gives.
let INSTALL_ID = "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"
let PHONE = hashFingerprint("machine-id|ios:" + INSTALL_ID)

/// The install id's rules (`InstallId`, contract 4.1), on an item in memory: the Keychain's own
/// calls are iOS's, and these hold whatever the item is kept in.
@Suite("the install id an iPhone or iPad keeps", suiteTimeLimit)
struct InstallIdTests {
    @Test func writesTheSeedUpperCasedTheFirstTimeAndKeepsItAfter() async throws {
        let item = MemoryStashItem()
        #expect(try await InstallId.read(item) { INSTALL_ID.lowercased() } == INSTALL_ID)
        #expect(item.writes == ["add \(INSTALL_ID)"])
        // Kept: the seed is not asked for again, whatever it would say now.
        let asked = Counter()
        #expect(try await InstallId.read(item) { asked.next(); return "ANOTHER" } == INSTALL_ID)
        #expect(asked.count == 0 && item.writes.count == 1)
    }

    @Test func seedsFromTheVendorIdElseARandomVersion4UUID() throws {
        #expect(InstallId.seed(vendor: INSTALL_ID) == INSTALL_ID)
        let first = InstallId.seed(vendor: nil)
        let second = InstallId.seed(vendor: nil)
        #expect(UUID(uuidString: first) != nil && first != second)
        #expect(first.split(separator: "-").dropFirst(2).first?.first == "4")
    }

    @Test func takesTheIdAnotherReadWroteFirst() async throws {
        let item = MemoryStashItem()
        item.refuseWrites(landing: "THEIRS")
        #expect(try await InstallId.read(item) { INSTALL_ID } == "THEIRS")
        #expect(item.text == "THEIRS" && item.writes.isEmpty)
    }

    @Test func replacesAnItemThatHoldsNoId() async throws {
        let item = MemoryStashItem("")
        #expect(try await InstallId.read(item) { "seed" } == "SEED")
        #expect(item.writes == ["update SEED"])
    }

    @Test func throwsRatherThanAnswerTheSeedWhenTheItemCannotBeRead() async throws {
        // A device locked since it started: no id, and nothing written over what it holds.
        let locked = MemoryStashItem("KEPT")
        locked.failReads()
        await #expect(throws: MemoryStashItem.Unreadable.self) { try await InstallId.read(locked) { INSTALL_ID } }
        #expect(locked.writes.isEmpty)
        // Written, then not read back.
        let written = MemoryStashItem()
        written.failReads(after: 1)
        await #expect(throws: MemoryStashItem.Unreadable.self) { try await InstallId.read(written) { INSTALL_ID } }
        #expect(written.writes == ["add \(INSTALL_ID)"] && written.reads == 2)
        // Written, and read back holding no id.
        await #expect(throws: InstallIdNotKept.self) { try await InstallId.read(MemoryStashItem()) { "" } }
    }

    @Test func throwsRatherThanAnswerTheSeedWhenTheItemCannotBeWritten() async throws {
        // An add refused, with no id there after it: the add's own error.
        let refused = MemoryStashItem()
        refused.refuseWrites()
        await #expect(throws: MemoryStashItem.Refused.self) { try await InstallId.read(refused) { INSTALL_ID } }
        #expect(refused.text == nil)
        // An item holding no id whose update is refused: the same.
        let empty = MemoryStashItem("")
        empty.refuseWrites()
        await #expect(throws: MemoryStashItem.Refused.self) { try await InstallId.read(empty) { INSTALL_ID } }
        // A write refused, and the read after it failing: that read's error.
        let lost = MemoryStashItem()
        lost.refuseWrites()
        lost.failReads(after: 1)
        await #expect(throws: MemoryStashItem.Unreadable.self) { try await InstallId.read(lost) { INSTALL_ID } }
        #expect(lost.reads == 2)
    }

    @Test func keepsTheKeychainItemsTheDartSDKKeeps() {
        // Shared with the Dart SDK's plugin on iOS (contract 4.1): renaming one gives every iPhone a
        // new id, and so a second seat.
        #expect(installIdService == "dev.keygrant.install")
        #if canImport(Security)
        let install = InstallId.item(product: "sluice")
        #expect(install.service == "dev.keygrant.install" && install.account == "sluice" && install.keychain == .dataProtection)
        let stash = KeychainTrialStash(product: "sluice")
        #expect(stash.service == "dev.keygrant.trial" && stash.account == "sluice" && stash.keychain == .dataProtection)
        // The default stash on iOS holds no trial call past its own bound.
        #expect(KeychainTrialStash.callTimeout == 5)
        #endif
    }

    #if canImport(Security) && (os(macOS) || targetEnvironment(macCatalyst))
    /// On a Mac (a Mac Catalyst app's included): after the first unlock in the data protection
    /// keychain, the login keychain's own default in it; never iOS's this-device-only.
    @Test func keepsAMacsKeychainItemsReadableAfterTheFirstUnlock() {
        let dataProtection = KeychainItem(service: "s", account: "a", keychain: .dataProtection).accessible
        #expect(dataProtection.map { $0 as String } == kSecAttrAccessibleAfterFirstUnlock as String)
        #expect(KeychainItem(service: "s", account: "a", keychain: .login).accessible == nil)
    }
    #endif

    @Test func keepsTheStateInTheContainerOnAPhoneWhateverHomeSays() {
        // The Simulator's HOME may not be the app's container; NSHomeDirectory() is.
        #expect(storageHome(platform: "ios", home: "/Users/jo/Library/Developer/CoreSimulator") == NSHomeDirectory())
        #expect(storageHome(platform: "darwin", home: "/Users/jo") == "/Users/jo")
        #expect(storageHome(platform: "linux", home: "") == NSHomeDirectory())
        #expect(storageHome(platform: "linux", home: nil) == NSHomeDirectory())
    }
}

@Suite("the default fingerprinter on an iPhone or iPad", suiteTimeLimit)
struct PhoneFingerprinterTests {
    @Test func readsTheInstallIdAndNothingToFallBackOn() async {
        #expect(await readMachineId(iPhone(.value(INSTALL_ID)), timeout: 1, on: ManualTicker()) == .id(INSTALL_ID))
        // No id, any failure, or no answer in time: not this time, never "none" (there is no host
        // name to fall back on), and never Linux's files.
        var withFiles = linuxMachine()
        withFiles.platform = "ios"
        #expect(await readMachineId(withFiles, timeout: 1, on: ManualTicker()) == .transient)
        #expect(await readMachineId(iPhone(.value("")), timeout: 1, on: ManualTicker()) == .transient)
        let missing = StorageError(code: "ENOENT", operation: "open", path: "keychain")
        #expect(await readMachineId(iPhone(.failure(missing)), timeout: 1, on: ManualTicker()) == .transient)
        #expect(await readMachineId(iPhone(.failure(ScriptedMachineSource.Odd())), timeout: 1, on: ManualTicker()) == .transient)
        #expect(await readMachineId(iPhone(.hang), timeout: 0.1) == .transient)
    }

    @Test func hashesTheInstallIdWithNoHostNameBesideIt() async throws {
        let identity = try await DefaultFingerprinter(source: iPhone(.value(INSTALL_ID))).identify(timeout: 1)
        #expect(identity == DeviceIdentity(fingerprint: PHONE, kind: .machine, alternates: []))
        #expect(try await DefaultFingerprinter(source: iPhone(.value(INSTALL_ID))).get() == PHONE)
    }

    @Test func givesNoFingerprintAndNoAlternateWhenTheIdCannotBeReadThisTime() async throws {
        let source = iPhone(.failure(ScriptedMachineSource.Odd()), .value(INSTALL_ID))
        let fingerprinter = DefaultFingerprinter(source: source)
        #expect(try await fingerprinter.identify(timeout: 1) == DeviceIdentity(fingerprint: nil, alternates: []))
        // Read again on the next call, then kept: two reads in all.
        #expect(try await fingerprinter.identify(timeout: 1) == DeviceIdentity(fingerprint: PHONE, kind: .machine))
        #expect(try await fingerprinter.identify(timeout: 1) == DeviceIdentity(fingerprint: PHONE, kind: .machine))
        #expect(source.installReads.count == 2)
        await #expect(throws: FingerprintUnavailable.self) {
            try await DefaultFingerprinter(source: iPhone(.value(nil))).get()
        }
    }

    @Test func readsOnceForEachProductOnAPhoneAndOnceForTheProcessElsewhere() async throws {
        #expect(FingerprintCache.shared(product: "sluice", platform: "darwin") === FingerprintCache.process)
        #expect(FingerprintCache.shared(product: "sluice", platform: "linux") === FingerprintCache.process)
        // These caches are the process's: products named afresh each run, so a run repeated in the
        // same process reads as the first did.
        let run = UUID().uuidString
        let first = iPhone(.value(INSTALL_ID))
        for _ in 1...2 {
            let fingerprinter = DefaultFingerprinter(source: first, cache: .shared(product: "a-\(run)", platform: "ios"))
            #expect(try await fingerprinter.identify(timeout: 1).fingerprint == PHONE)
        }
        #expect(first.installReads.count == 1)
        // Another product reads its own install id.
        let second = iPhone(.value("9B2A44C0-1D3E-4F5A-8B6C-7D8E9F0A1B2C"))
        let other = DefaultFingerprinter(source: second, cache: .shared(product: "b-\(run)", platform: "ios"))
        #expect(try await other.identify(timeout: 1).fingerprint == machineFingerprint("ios:9B2A44C0-1D3E-4F5A-8B6C-7D8E9F0A1B2C"))
        #expect(second.installReads.count == 1)
    }

    @Test func isTheOneALicenseMakesForTheProductOnAPhone() {
        let product = "c-\(UUID().uuidString)"
        let fingerprinter = DefaultFingerprinter(product: product, platform: "ios")
        #expect(fingerprinter.cache === FingerprintCache.shared(product: product, platform: "ios"))
        #expect(fingerprinter.cache !== FingerprintCache.process)
        #expect((fingerprinter.source as? SystemMachineIdSource)?.product == product)
    }
}

/// The privacy manifest the package ships for the App Store, read as Xcode reads it.
@Suite("the privacy manifest", suiteTimeLimit)
struct PrivacyManifestTests {
    @Test func declaresNoTrackingWhatIsSentAndWhyTheReadsAreMade() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: package.appendingPathComponent("Sources/KeyGrant/PrivacyInfo.xcprivacy"))
        let manifest = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect((manifest["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty == true)
        // What is sent, and what for: the device id and an address for licensing; a trial's launch
        // report for the trial figures and metered uses for licensing.
        var collected: [String: Set<String>] = [:]
        for type in manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? [] {
            #expect(type["NSPrivacyCollectedDataTypeLinked"] as? Bool == true)
            #expect(type["NSPrivacyCollectedDataTypeTracking"] as? Bool == false)
            collected[type["NSPrivacyCollectedDataType"] as? String ?? ""] =
                Set(type["NSPrivacyCollectedDataTypePurposes"] as? [String] ?? [])
        }
        let licensing = "NSPrivacyCollectedDataTypePurposeAppFunctionality"
        #expect(collected == [
            "NSPrivacyCollectedDataTypeDeviceID": [licensing],
            "NSPrivacyCollectedDataTypeEmailAddress": [licensing],
            "NSPrivacyCollectedDataTypeProductInteraction": ["NSPrivacyCollectedDataTypePurposeAnalytics", licensing],
        ])
        var reasons: [String: [String]] = [:]
        for api in manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? [] {
            reasons[api["NSPrivacyAccessedAPIType"] as? String ?? ""] = api["NSPrivacyAccessedAPITypeReasons"] as? [String]
        }
        #expect(reasons == [
            "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
            "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"],
        ])
    }
}
