import Foundation
import Testing

@testable import KeyGrant

@Suite("the product's public key", suiteTimeLimit)
struct PublicKeyTests {
    let x = "Ohg4h8SrYQ0m1su_zVacJLLwf_6rNsvOtV5oWY6CzJs"

    @Test func takesTheJWKProvisioningHandsOutAndItsBareX() throws {
        let bare = try publicKeyBytes(fromJWK: x)
        #expect(bare.count == 32)
        #expect(try publicKeyBytes(fromJWK: #"{"kty":"OKP","crv":"Ed25519","x":"\#(x)"}"#) == bare)
        // As WebCrypto exports it, with its key_ops and ext.
        #expect(try publicKeyBytes(fromJWK: #" {"crv":"Ed25519","ext":true,"key_ops":["verify"],"kty":"OKP","x":"\#(x)","alg":"EdDSA","use":"sig"} "#) == bare)
        // Pasted with its padding.
        #expect(try publicKeyBytes(fromJWK: x + "=") == bare)
    }

    @Test(arguments: [
        #"{"kty":"OKP","crv":"Ed25519","x":"Ohg4h8SrYQ0m1su_zVacJLLwf_6rNsvOtV5oWY6CzJs","d":"7M0XqcS5ikXwkEvt2VKkfVK9x-LxF_N523of445LXxk"}"#,
        #"{"kty":"EC","crv":"P-256","x":"Ohg4h8SrYQ0m1su_zVacJLLwf_6rNsvOtV5oWY6CzJs"}"#,
        #"{"kty":"OKP","crv":"Ed25519","x":"Ohg4h8SrYQ0m1su_zVacJLLwf_6rNsvOtV5oWY6CzJs","use":"enc"}"#,
        #"{"kty":"OKP","crv":"Ed25519","x":"Ohg4h8SrYQ0m1su_zVacJLLwf_6rNsvOtV5oWY6CzJs","key_ops":["sign"]}"#,
        #"{"kty":"OKP","crv":"Ed25519","x":"Ohg4h8SrYQ0m1su_zVacJLLwf_6rNsvOtV5oWY6CzJs","alg":"RS256"}"#,
        #"{"kty":"OKP","crv":"Ed25519","x":"AAAA"}"#,
        #"{"kty":"OKP","crv":"Ed25519"}"#,
        #"{"kty":"OKP""#,
        "not a key at all",
        "",
    ])
    func refusesAnythingButAnEd25519PublicKey(text: String) {
        #expect(throws: LicenseConfigError.self) { try publicKeyBytes(fromJWK: text) }
    }

    @Test func aLicenseWithAKeyItCannotUseIsAConfigurationErrorAtOnce() throws {
        #expect(throws: LicenseConfigError.self) {
            try License(LicenseConfig(product: PRODUCT, apiBaseURL: apiBase, publicJWK: "{}"))
        }
    }

    @Test func decodesOnlyCanonicalBase64URLInALease() {
        #expect(canonicalBase64URLDecode("QQ") == Data([0x41]))
        #expect(canonicalBase64URLDecode("QR") == nil)  // a stray bit
        #expect(canonicalBase64URLDecode("QQ==") == nil)  // padded
        #expect(canonicalBase64URLDecode("+/8") == nil)  // the standard alphabet
        #expect(canonicalBase64URLDecode("-_8") == Data([0xFB, 0xFF]))
        #expect(canonicalBase64URLDecode("Q") == nil)
        #expect(canonicalBase64URLDecode("") == Data())
        #expect(canonicalBase64URLDecode("QQ ") == nil)
    }
}

@Suite("the state file", suiteTimeLimit)
struct StateFileTests {
    @Test func writesTheReferencesFieldNamesAndLeavesAbsentFieldsOut() throws {
        let state = StoredState(
            key: "K", activationId: "a", lease: "L", trialStart: 1, trialEndsAt: 2, trialLease: "T", trialAt: 3, lastSeen: 4,
            checkedMajor: 5, keptMajor: 6, backoffSince: 7, backoffMs: 8, refused: .device, refusedMajor: 9, refusedFor: ["c"],
            deviceKind: .machine, verdictAt: 10, rev: 11
        )
        let text = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        let expected: LicenseJSON = [
            "key": "K", "activationId": "a", "lease": "L", "trialStart": 1, "trialEndsAt": 2, "trialLease": "T", "trialAt": 3,
            "lastSeen": 4, "checkedMajor": 5, "keptMajor": 6, "backoffSince": 7, "backoffMs": 8, "refused": "device",
            "refusedMajor": 9, "refusedFor": ["c"], "deviceKind": "machine", "verdictAt": 10, "rev": 11,
        ]
        #expect(JSONText.parse(text) == expected)
        #expect(try JSONDecoder().decode(StoredState.self, from: Data(text.utf8)) == state)
        #expect(String(decoding: try JSONEncoder().encode(StoredState()), as: UTF8.self) == "{}")
    }

    @Test func readsAStateAnySDKWroteAndKeepsWhatItDoesNotKnow() throws {
        let text = #"{"key":"K","lastSeen":1790000000000,"somethingNew":{"a":[1,true,null]},"rev":2}"#
        let state = try JSONDecoder().decode(StoredState.self, from: Data(text.utf8))
        #expect(state == StoredState(key: "K", lastSeen: 1_790_000_000_000, rev: 2, otherFields: ["somethingNew": ["a": [1, true, .null]]]))
        #expect(JSONText.parse(String(decoding: try JSONEncoder().encode(state), as: UTF8.self)) == JSONText.parse(text))
    }

    @Test func readsNoStateFromAValueThatIsNoObject() {
        for value: LicenseJSON in [.null, [1, 2], "text", 5, true] {
            #expect(StoredState(json: value) == StoredState())
        }
    }

    @Test func writesWholeNumbersAsJavaScriptDoes() throws {
        #expect(String(decoding: JSONText.data([1_790_000_000_000, 0.5, -0.0, 3]), as: UTF8.self) == "[1790000000000,0.5,0,3]")
    }
}

@Suite("the status", suiteTimeLimit)
struct StatusValueTests {
    @Test func givesTheTrialsEndAsADate() {
        let status = LicenseStatus(state: .trial, trialDaysLeft: 1, trialEndsAt: 1_790_000_000_000)
        #expect(status.trialEndDate == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(LicenseStatus(state: .unlicensed).trialEndDate == nil)
    }

    @Test func namesItsStatesReasonsAndErrorsAsTheReferenceDoes() {
        #expect(LicenseState.allCases.map(\.rawValue) == ["licensed", "trial", "expired", "invalid", "unlicensed", "unknown"])
        #expect(LicenseReason.allCases.map(\.rawValue) == ["revoked", "upgrade", "outdated", "offline", "tampered", "device", "trial", "storage", "unknown-key", "revoked-file"])
        #expect(LicenseError.allCases.map(\.rawValue) == [
            "invalid-key", "limit", "revoked", "upgrade", "outdated", "network", "not-configured", "invalid-lease", "storage",
        ])
        #expect(ActivateResult.failed(.limit).error == .limit && !ActivateResult.failed(.limit).isActivated)
        #expect(ActivateResult.activated.isActivated && ActivateResult.activated.error == nil)
    }
}

@Suite("the SDK's own bounds", suiteTimeLimit)
struct BoundTests {
    /// On a clock that does not move, so the bound cannot win however long the work is held up.
    @Test func answersWhatFinishesInTime() async throws {
        #expect(await answer { try? await withTimeout(1, on: ManualTicker()) { 42 } } == 42)
        // And on the system's, given time enough.
        #expect(try await withTimeout(60) { 42 } == 42)
    }

    @Test func abandonsWorkThatDoesNotHeedCancellationAtItsBoundToTheMillisecond() async throws {
        let ticker = ManualTicker()
        // Work that ignores cancellation: it waits for a gate nothing opens until the end.
        let gate = Gate()
        let answered = Flag()
        let bounded = Task { () -> Result<Int, Error> in
            let result: Result<Int, Error>
            do {
                result = .success(try await withTimeout(10, on: ticker) { () async throws -> Int in
                    await gate.wait()
                    return 1
                })
            } catch {
                result = .failure(error)
            }
            answered.set(true)
            return result
        }
        await eventually { ticker.deadlinesMs == [10_000] }
        #expect(ticker.deadlinesMs == [10_000])
        ticker.advance(ms: 9_999)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!answered.on, "answered before its bound")
        ticker.advance(ms: 1)
        // Still, the caller is not held past the bound.
        let result = try #require(await answer { await bounded.value })
        #expect(throws: TimeoutError.self) { try result.get() }
        gate.open()
    }

    @Test func cancelsTheWorkAtItsBound() async throws {
        let ticker = ManualTicker()
        let cancelled = Flag()
        let bounded = Task { () -> Result<Int, Error> in
            do {
                return .success(try await withTimeout(1, on: ticker) { () async throws -> Int in
                    try? await Task.sleep(nanoseconds: hangNanoseconds)
                    cancelled.set(Task.isCancelled)
                    return 1
                })
            } catch {
                return .failure(error)
            }
        }
        await eventually { ticker.deadlinesMs == [1_000] }
        ticker.advance(ms: 1_000)
        let result = try #require(await answer { await bounded.value })
        #expect(throws: TimeoutError.self) { try result.get() }
        await eventually { cancelled.on }
        #expect(cancelled.on)
    }

    @Test func passesOnTheWorksOwnError() async throws {
        struct Failure: Error {}
        let result = try #require(await answer { () -> Result<Int, Error> in
            do {
                return .success(try await withTimeout(1, on: ManualTicker()) { () async throws -> Int in throw Failure() })
            } catch {
                return .failure(error)
            }
        })
        #expect(throws: Failure.self) { try result.get() }
    }

    @Test func runsFileWorkAtTheCallersClassAndNeverBelowUserInitiated() async throws {
        let table: [(TaskPriority, DispatchQoS.QoSClass)] = [
            (.background, .userInitiated), (.utility, .userInitiated), (.low, .userInitiated), (.medium, .userInitiated),
            (.userInitiated, .userInitiated), (.high, .userInitiated), (TaskPriority(rawValue: 33), .userInteractive),
        ]
        for (priority, qos) in table {
            #expect(ioQoS(priority) == qos, "\(priority)")
        }
        // Waited on by a background task: dispatched at user-initiated, not the task's own class, and done.
        let given = Shared<[DispatchQoS.QoSClass]>([])
        let background = Task(priority: .background) { () -> Int in
            let seven = try? await blocking({ 7 }, dispatch: { qos, work in
                given.set(given.current + [qos])
                DispatchQueue.global(qos: qos).async { work() }
            })
            return seven ?? 0
        }
        #expect(await answer { await background.value } == 7)
        #expect(given.current == [.userInitiated])
    }
}

@Suite("the names the SDK had before", suiteTimeLimit)
struct FormerNameTests {
    /// Code written against the former names still builds (with a warning to rename it).
    @available(*, deprecated, message: "exercises the deprecated names")
    @Test func stillNameTheRenamedTypes() {
        #expect(JSONValue.self == LicenseJSON.self)
        #expect(HTTPResponse.self == LicenseHTTPResponse.self)
        let body: JSONValue = ["lease": "L"]
        #expect(HTTPResponse(status: 200, json: body) == LicenseHTTPResponse(status: 200, json: ["lease": "L"]))
    }
}
