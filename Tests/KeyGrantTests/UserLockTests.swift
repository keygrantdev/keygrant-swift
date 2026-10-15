import Foundation
import Testing

@testable import KeyGrant

/// User-locked keys: what `activate(_:email:code:)` and `importLicenseFile(_:email:code:)` send for
/// the address and code a person typed, how each word the server refuses a new device with comes
/// back, and everything that never carries them. What the typing is prepared as, and the
/// word-to-error mapping, are held to the conformance vectors (`typedFor`, `userLockErrors`); these
/// are the calls.
@Suite("user-locked keys", suiteTimeLimit)
struct UserLockTests {
    static let words: [(word: String, error: LicenseError)] = [
        ("user-email-required", .userEmailRequired),
        ("user-email-mismatch", .userEmailMismatch),
        ("user-code-required", .userCodeRequired),
        ("user-code-invalid", .userCodeInvalid),
        ("too-many-codes", .tooManyCodes),
        ("too-many-attempts", .tooManyAttempts),
        ("try-again", .tryAgain),
    ]

    /// A harness whose server activates any key with a lease for `KEY`.
    func activating() throws -> Harness {
        let h = try Harness()
        h.http.on("activate", status: 200, json: ["lease": .string(h.sign()), "activationId": "act_1"])
        return h
    }

    /// A harness whose server refuses every activation with `word`.
    func refusing(_ word: String, status: Int = 403) throws -> Harness {
        let h = try Harness()
        h.http.on("activate", status: status, json: ["error": .string(word)])
        return h
    }

    func lastBody(_ h: Harness, _ action: String = "activate") -> LicenseJSON? {
        h.http.calls.last { $0.action == action }?.body
    }

    // MARK: - activate with an address and a code

    @Test func sendsWhatThePersonTypedTrimmedBesideTheKeyAndNothingWhenTheyTypedNone() async throws {
        let h = try activating()
        #expect(await h.license.activate(KEY) == .activated)
        let plain = try #require(h.http.body("activate"))
        #expect(!plain.has("email") && !plain.has("code"))

        _ = await h.license.activate(KEY, email: "  Mara@Studio.example\n", code: " 123 456 ")
        let body = try #require(lastBody(h))
        #expect(body["key"]?.stringValue == KEY)
        #expect(body["email"]?.stringValue == "Mara@Studio.example")
        #expect(body["code"]?.stringValue == "123456")
    }

    @Test func treatsABlankAddressOrCodeAsNoneAndSendsTheOneThereIsAlone() async throws {
        let h = try refusing("user-email-required")
        _ = await h.license.activate(KEY, email: "   ", code: "")
        let blank = try #require(lastBody(h))
        #expect(!blank.has("email") && !blank.has("code"))

        _ = await h.license.activate(KEY, email: "mara@studio.example")
        let address = try #require(lastBody(h))
        #expect(address["email"]?.stringValue == "mara@studio.example")
        #expect(!address.has("code"))

        _ = await h.license.activate(KEY, code: "123456")
        let code = try #require(lastBody(h))
        #expect(code["code"]?.stringValue == "123456")
        #expect(!code.has("email"))
    }

    @Test func answersEachWordOfTheServerAsItsOwnErrorWhateverTheStatus() async throws {
        for (word, error) in Self.words {
            for status in [403, 429, 503] {
                let h = try refusing(word, status: status)
                #expect(await h.license.activate(KEY, email: "mara@studio.example") == .failed(error), "\(status) \(word)")
            }
            // The word an app sends on to its screens is the server's.
            #expect(error.rawValue == word)
        }
    }

    @Test func answersALockedKeysFirstAskWithTheKeyAloneAsTheErrorThatAsksForTheAddress() async throws {
        let h = try refusing("user-email-required")
        #expect(await h.license.activate(KEY) == .failed(.userEmailRequired))
    }

    @Test func answersARateLimitOrAnOutageThatIsNotALocksWordAsNetworkAsItAlwaysDid() async throws {
        for (status, word) in [(429, "rate-limited"), (503, "unavailable"), (500, "internal"), (403, "user-something-new"), (403, "Try-Again")] {
            let h = try refusing(word, status: status)
            #expect(await h.license.activate(KEY, email: "mara@studio.example") == .failed(.network), "\(status) \(word)")
        }
        let down = try Harness()
        down.http.setFail(true)
        #expect(await down.license.activate(KEY, email: "mara@studio.example") == .failed(.network))
    }

    @Test func storesNothingAboutTheAddressTheCodeOrARefusal() async throws {
        let h = try refusing("user-code-required")
        #expect(await h.license.activate(KEY, email: "mara@studio.example", code: "123456") == .failed(.userCodeRequired))
        #expect(h.stored == nil)
        #expect(h.storage.writes == 0)

        // Once the lease comes, the activation is stored as ever and nothing of what was typed.
        let ok = try activating()
        #expect(await ok.license.activate(KEY, email: "mara@studio.example", code: "123456") == .activated)
        let stored = try #require(ok.stored)
        let text = JSONText.text(stored.json)
        #expect(text.contains(KEY))
        #expect(!text.contains("studio") && !text.contains("123456"))
        #expect(await ok.license.status() == keyLicensed)
    }

    @Test func refusesAnAddressLongerThanAnyAndACodeThatIsNotSixDigitsBeforeTheServerIsAsked() async throws {
        let h = try refusing("user-email-required")
        let tooLong = String(repeating: "a", count: maxEmail) + "@b.example"
        #expect(await h.license.activate(KEY, email: tooLong) == .failed(.userEmailMismatch))
        #expect(await h.license.activate(KEY, email: "a@b.example", code: "12345") == .failed(.userCodeInvalid))
        #expect(!h.http.called("activate"))

        // The address is judged first, and the key before both.
        #expect(await h.license.activate(KEY, email: String(repeating: "x", count: 300), code: "nope") == .failed(.userEmailMismatch))
        #expect(await h.license.activate("", email: String(repeating: "x", count: 300)) == .failed(.invalidKey))
        // A blank address beside a code that is no code is still the code's fault.
        #expect(await h.license.activate(KEY, email: "", code: "12") == .failed(.userCodeInvalid))
        #expect(!h.http.called("activate"))
    }

    // MARK: - what never carries them

    @Test func sendsNeitherToValidateDeactivateOrATrialEvenAfterAnActivationThatCarriedThem() async throws {
        let h = try activating()
        h.http.on("validate", status: 200, json: ["lease": .string(h.sign())])
        h.http.on("deactivate", status: 200, json: [:])
        #expect(await h.license.activate(KEY, email: "mara@studio.example", code: "123456") == .activated)
        _ = await h.license.refresh()
        _ = try await h.license.deactivate()
        _ = await h.license.startTrial()
        for call in h.http.calls where call.action != "activate" {
            #expect(!call.body.has("email") && !call.body.has("code"), "\(call.action)")
        }
        #expect(h.http.count("validate") == 1)
        #expect(h.http.count("deactivate") == 1)
        #expect(h.http.count("trial") > 0)
    }

    // MARK: - a key file

    @Test func asksAKeyFilesKeyWithTheSameAddressAndCodeAndItsAnswersComeBackAsActivates() async throws {
        let h = try refusing("user-code-required")
        let app = try h.fileApp()
        let file = licenseFileText(h.signer.keyFile())
        let result = try await app.importLicenseFile(file, email: " Ada@Example.com ", code: "123 456")
        #expect(result == .notActivated(.userCodeRequired))
        let body = try #require(h.http.body("activate"))
        #expect(body["key"]?.stringValue == KEY)
        #expect(body["email"]?.stringValue == "Ada@Example.com")
        #expect(body["code"]?.stringValue == "123456")

        // With no options it sends neither, as before.
        #expect(try await app.importLicenseFile(file) == .notActivated(.userCodeRequired))
        let again = try #require(lastBody(h))
        #expect(!again.has("email") && !again.has("code"))
        // Nothing of it is stored.
        #expect(h.stored == nil)
    }

    @Test func takesAKeyFilesOptionsAsBytesToo() async throws {
        let h = try refusing("user-email-required")
        let bytes = Data(licenseFileText(h.signer.keyFile()).utf8)
        #expect(try await h.fileApp().importLicenseFile(bytes, email: "ada@example.com") == .notActivated(.userEmailRequired))
        #expect(h.http.body("activate")?["email"]?.stringValue == "ada@example.com")
    }

    @Test func takesAKeyFileWhoseKeyActivatesWithTheOptionsSendingThemNormalisedAndStoringNeither() async throws {
        let h = try Harness()
        h.http.on("activate", status: 200, json: ["lease": .string(h.leaseTo3()), "activationId": "act_1"])
        let result = try await h.fileApp().importLicenseFile(
            licenseFileText(h.signer.keyFile()), email: "  Mara@Studio.example ", code: " 123 456 "
        )
        #expect(result == .imported(.key, licensedTo: LicensedTo(email: adaEmail)))
        let body = try #require(h.http.body("activate"))
        #expect(body["key"]?.stringValue == KEY)
        #expect(body["email"]?.stringValue == "Mara@Studio.example")
        #expect(body["code"]?.stringValue == "123456")
        // Activated as ever, and nothing of what was typed (nor the file's own address) is stored.
        let text = JSONText.text(try #require(h.stored).json)
        #expect(text.contains(KEY))
        // Whatever the case, the address as typed (its local part and its domain) and the code both as
        // normalised and as typed.
        for typed in ["mara@", "studio.example", "123456", "123 456", "example.com"] {
            #expect(!text.lowercased().contains(typed), "\(typed)")
        }
    }

    @Test func judgesAKeyFilesKeyBeforeTheAddressAndTheAddressBeforeTheCode() async throws {
        let h = try refusing("user-email-required")
        let app = try h.fileApp()
        let long = String(repeating: "x", count: 300)
        #expect(try await app.importLicenseFile(licenseFileText(h.signer.keyFile()), email: long, code: "nope") == .notActivated(.userEmailMismatch))
        let blank = h.signer.keyFile(["sub": " "])
        #expect(try await app.importLicenseFile(licenseFileText(blank), email: long, code: "nope") == .notActivated(.invalidKey))
        #expect(!h.http.called("activate"))
    }

    @Test func refusesAFileThatIsNoLicenceFileBeforeAnyKeyIsAskedForWhateverComesWithIt() async throws {
        let h = try Harness()
        #expect(try await h.license.importLicenseFile("not a file", email: "mara@studio.example") == .refused(.malformed))
        #expect(!h.http.called("activate"))
    }

    @Test func ignoresTheOptionsForAnOfflineFileAndAsksNothing() async throws {
        let h = try Harness()
        let taken = try await h.fileApp().importLicenseFile(
            licenseFileText(h.signer.offlineFile()), email: String(repeating: "x", count: 300), code: "nope"
        )
        #expect(taken == .imported(.offline, licensedTo: ada))
        #expect(h.http.calls.isEmpty)
    }
}
