import Foundation
import Testing

@testable import KeyGrant

/// A build's major, read as the server reads a version (`majorOf`): a 0.x build is major 1.
@Suite("the major a build runs as", suiteTimeLimit)
struct MajorTests {
    /// Beyond the `majors` vectors (ConformancePurchaseTests): every negative an `Int` holds is 1.
    @Test func readsEveryMajorBelowZeroAsOne() {
        #expect([-1, Int.min].map { majorOf($0) } == [1, 1])
    }

    @Test func aZeroXBuildIsLicensedOfflineByALeaseForMajorOneNotRefusedAsOutdated() async throws {
        let h = try Harness(major: 0)
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.signer.lease(major: 1), lastSeen: NOW, checkedMajor: 1))
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY))
    }

    @Test func aZeroXBuildSendsMajorOneWithItsActivationItsValidateAndItsClaim() async throws {
        let h = try Harness(StoredState(purchaseToken: Purchase.token, purchaseTokenAt: NOW), major: 0)
        let lease = h.signer.lease(major: 1)
        h.http.on("claim", status: 200, json: ["pending": true])
        h.http.on("activate", status: 200, json: ["lease": .string(lease), "activationId": "act_1"])
        h.http.on("validate", status: 200, json: ["lease": .string(lease)])
        _ = await h.license.status()
        #expect(await h.license.activate(KEY) == .activated)
        #expect(await h.license.refresh() == LicenseStatus(state: .licensed, key: KEY))
        #expect(h.http.body("claim")?["major"] == 1)
        #expect(h.http.body("activate")?["major"] == 1)
        #expect(h.http.body("validate")?["major"] == 1)
        #expect(h.stored?.checkedMajor == 1)
    }
}
