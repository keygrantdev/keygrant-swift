import Foundation
import Testing

@testable import KeyGrant

/// Licence files: an offline file imported, stored and answered with no network; every refusal; a
/// stored file that does not license this build; a key file activating its key; and the calls
/// behind one that has not finished.
@Suite("licence files", suiteTimeLimit)
struct LicenseFileTests {
    @Test func anOfflineFileIsTakenFromItsTextWithNoNetworkStoredAndLicensesAsTheFile() async throws {
        let h = try Harness()
        let token = h.signer.offlineFile()
        let app = try h.fileApp()
        #expect(try await app.importLicenseFile(licenseFileText(token)) == .imported(.offline, licensedTo: ada))
        #expect(h.stored?.licenseFile == token)
        #expect(await app.status() == fileLicensed)
        #expect(h.http.calls.isEmpty)
    }

    @Test func anOfflineFileIsTakenAsBytesAsADropHandlerReadsThem() async throws {
        let h = try Harness()
        let token = h.signer.offlineFile()
        #expect(try await h.fileApp().importLicenseFile(Data(licenseFileText(token).utf8)) == .imported(.offline, licensedTo: ada))
        #expect(h.stored?.licenseFile == token)
    }

    @Test func aStoredOfflineFileNeverGoesOnlineRefreshIncludedThoughTheKeyBesideItHasRunOut() async throws {
        let h = try Harness()
        // Without the file, this run-out lease would be asked about, and the wait after the ask saved.
        let expired = h.signer.lease(major: 3, ttlSeconds: 3600, at: NOW - 2 * DAY)
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: expired, lastSeen: NOW, licenseFile: h.signer.offlineFile()))
        let app = try h.fileApp()
        #expect(await app.status() == fileLicensed)
        #expect(await app.refresh() == fileLicensed)
        #expect(h.http.calls.isEmpty)
        #expect(h.storage.writes == 0)
    }

    @Test func aFileSaysWhenItIsATestLicenceAndCarriesItsEntitlementsWhichHasReads() async throws {
        let h = try Harness()
        h.storage.set(StoredState(licenseFile: h.signer.offlineFile(["test": true, "ent": ["edition": "pro", "cloud": true]])))
        let app = try h.fileApp()
        var expected = fileLicensed
        expected.isTest = true
        expected.entitlements = ["edition": "pro", "cloud": true]
        #expect(await app.status() == expected)
        #expect(await app.has("cloud"))
        await #expect(throws: MissingEntitlement(entitlement: "export")) { try await app.require("export") }
    }

    @Test func removingNoFileIsNoErrorAndLeavesUnlicensedAsItWas() async throws {
        let h = try Harness()
        let app = try h.fileApp()
        try await app.removeLicenseFile()
        #expect(await app.status() == LicenseStatus(state: .unlicensed))
    }

    @Test func aFileReplacesTheOneStoredBeforeAndAFileRefusedLeavesIt() async throws {
        let h = try Harness()
        let app = try h.fileApp()
        _ = try await app.importLicenseFile(h.signer.offlineFile())
        let second = h.signer.offlineFile(["fid": "lf_3", "name": "Grace Hopper", "email": .null])
        #expect(try await app.importLicenseFile(second) == .imported(.offline, licensedTo: LicensedTo(name: "Grace Hopper")))
        #expect(try await app.importLicenseFile(h.signer.offlineFile(["product": "maindeck"])) == .refused(.wrongProduct))
        #expect(h.stored?.licenseFile == second)
    }

    @Test func aFileRefusedNamesEachReasonAndStoresNothing() async throws {
        let h = try Harness()
        let token = h.signer.offlineFile()
        let app = try h.fileApp(revoked: ["lf_9"])
        let cases: [(Data, LicenseFileError)] = [
            (Data(), .malformed),
            (Data("\(token)\n\(token)".utf8), .malformed),
            (Data([0xFF, 0xFE, 0x00]), .malformed),
            (Data(h.leaseTo3().utf8), .notALicenseFile),
            (Data(payloadSwapped(token, h.signer.offlineFile(["major": 9])).utf8), .badSignature),
            (Data(Signer().offlineFile().utf8), .unknownKey),
            (Data(h.signer.offlineFile(["product": "maindeck"]).utf8), .wrongProduct),
            (Data(h.signer.offlineFile(["fid": "lf_9"]).utf8), .revokedFile),
            (Data(h.signer.offlineFile(["major": 1]).utf8), .upgrade),
            (Data(h.signer.offlineFile(["minMajor": 3]).utf8), .outdated),
        ]
        for (content, error) in cases {
            #expect(try await app.importLicenseFile(content) == .refused(error), "\(error)")
        }
        #expect(h.storage.writes == 0)
        #expect(h.http.calls.isEmpty)
    }

    @Test func anImportOrARemovalThatCannotBeSavedThrowsOneAttemptEach() async throws {
        let h = try Harness()
        h.storage.set(StoredState(licenseFile: h.signer.offlineFile()))
        let app = try h.fileApp()
        h.storage.failWrites()
        await #expect(throws: StorageError.self) { try await app.importLicenseFile(h.signer.offlineFile(["fid": "lf_3"])) }
        await #expect(throws: StorageError.self) { try await app.removeLicenseFile() }
        #expect(h.storage.writes == 2)
    }

    @Test func anImportOrARemovalWhoseStateCannotBeReadThrowsWritingNothing() async throws {
        let h = try Harness()
        let app = try h.fileApp()
        h.storage.failRead(1)
        await #expect(throws: StorageError.self) { try await app.importLicenseFile(h.signer.offlineFile()) }
        h.storage.failRead(1)
        await #expect(throws: StorageError.self) { try await app.removeLicenseFile() }
        #expect(h.storage.writes == 0)
    }

    @Test func aFilesProductAndIdAreMatchedUnitForUnitNotByCanonicalEquivalence() async throws {
        // Swift's String equality would take a composed and a decomposed "é" for one; the reference's
        // `===` does not.
        let h = try Harness()
        let composed = "lf_\u{E9}", decomposed = "lf_e\u{301}"
        let app = try h.fileApp(revoked: [composed])
        #expect(try await app.importLicenseFile(h.signer.offlineFile(["fid": .string(decomposed)])).isImported)
        #expect(try await app.importLicenseFile(h.signer.offlineFile(["fid": .string(composed)])) == .refused(.revokedFile))
        let product = "sluic\u{E9}"
        let other = try License(
            LicenseConfig(product: product, apiBaseURL: apiBase, publicJWK: h.signer.publicJWK, major: 2, adapters: LicenseAdapters(storage: h.storage)),
            timing: h.timing
        )
        let decomposedProduct = h.signer.offlineFile(["product": "sluice\u{301}"])
        #expect(try await other.importLicenseFile(decomposedProduct) == .refused(.wrongProduct))
        // The control: the product as configured, composed, is this product's.
        #expect(try await other.importLicenseFile(h.signer.offlineFile(["product": .string(product)])).isImported)
    }

    @Test func aStoredFileIsRevokedFileOnceAnUpdateListsItWithWhoseItIsAndNoEntitlements() async throws {
        let h = try Harness()
        h.storage.set(StoredState(licenseFile: h.signer.offlineFile(["ent": ["cloud": true]])))
        let app = try h.fileApp(revoked: ["lf_0", "lf_1"])
        #expect(await app.status() == fileInvalid(.revokedFile))
        #expect(await !app.has("cloud"))
    }

    @Test func aStoredFileIsUpgradeOnABuildNewerThanItCoversAndOutdatedOnOneOlder() async throws {
        let h = try Harness()
        h.storage.set(StoredState(licenseFile: h.signer.offlineFile(["minMajor": 2, "major": 3])))
        #expect(try await h.license(major: 4).status() == fileInvalid(.upgrade))
        #expect(try await h.license(major: 1).status() == fileInvalid(.outdated))
    }

    @Test func aStoredValueThatIsNotTextIsNoFileAsEveryFieldOfTheWrongTypeIs() async throws {
        // The reference reads one as tampered; this port reads a stored field of the wrong type as
        // absent, every field alike. Either way it licenses nothing.
        let h = try Harness()
        let app = try h.fileApp()
        for value: LicenseJSON in [42, .null, ["token": "x"]] {
            h.storage.set(StoredState(json: ["licenseFile": value]))
            #expect(await app.status() == LicenseStatus(state: .unlicensed), "\(value)")
        }
        // The control: the same field holding text is the stored file.
        h.storage.set(StoredState(json: ["licenseFile": .string(h.signer.offlineFile())]))
        #expect(await app.status() == fileLicensed)
    }

    @Test func aStoredTokenEditedOrAStoredKeyFileOrNoneAtAllIsTampered() async throws {
        let h = try Harness()
        let edited = payloadSwapped(h.signer.offlineFile(), h.signer.offlineFile(["major": 9]))
        let app = try h.fileApp()
        for stored in [edited, h.signer.keyFile(), ""] {
            h.storage.set(StoredState(licenseFile: stored))
            #expect(await app.status() == fileUnread(.tampered), "\(stored)")
        }
    }

    @Test func aStoredFileSurvivesARotationWhileTheBuildCarriesItsKeyAndIsUnknownKeyAfter() async throws {
        let h = try Harness()
        let next = Signer()
        h.storage.set(StoredState(licenseFile: h.signer.offlineFile()))
        // A build after the switch: the new key signs, the old one is kept because it signed files.
        let rotated = try h.fileApp(keys: "[\(next.publicJWK),\(h.signer.publicJWK)]")
        #expect(await rotated.status() == fileLicensed)
        // A build that dropped it (a leaked key): the file must be signed again.
        let dropped = try h.fileApp(keys: next.publicJWK)
        #expect(await dropped.status() == fileUnread(.unknownKey))
    }
}
