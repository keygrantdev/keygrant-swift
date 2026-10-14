import Foundation
import Testing

@testable import KeyGrant

/// A stored offline licence file beside a key and beside a trial (one that licenses this build answers
/// first, with no ask, no write and no launch report; one that does not answers only when nothing
/// else does), a key file activating its key, and the calls behind one that has not finished.
@Suite("licence files beside keys and trials", suiteTimeLimit)
struct LicenseFilePrecedenceTests {
    /// `KEY` held on act_1 with `lease`, heard on major 2, seen at NOW.
    func keyed(_ lease: String, file: String? = nil) -> StoredState {
        StoredState(key: KEY, activationId: "act_1", lease: lease, lastSeen: NOW, checkedMajor: 2, licenseFile: file)
    }

    @Test func aFileWinsOverAHeldKeyWhichKeepsWorkingOnceTheFileIsRemoved() async throws {
        let h = try Harness()
        let lease = h.leaseTo3()
        h.storage.set(keyed(lease, file: h.signer.offlineFile()))
        let app = try h.fileApp()
        #expect(await app.status() == fileLicensed)
        try await app.removeLicenseFile()
        #expect(h.stored?.key == KEY && h.stored?.lease == lease && h.stored?.licenseFile == nil)
        #expect(await app.status() == keyLicensed)
    }

    @Test func aFileImportedOverAHeldKeyLeavesItsSeatAskingNothing() async throws {
        let h = try Harness()
        let lease = h.leaseTo3()
        h.storage.set(keyed(lease))
        let app = try h.fileApp()
        #expect(try await app.importLicenseFile(h.signer.offlineFile()).isImported)
        #expect(h.http.calls.isEmpty)
        #expect(h.stored?.key == KEY && h.stored?.activationId == "act_1" && h.stored?.lease == lease)
        try await app.removeLicenseFile()
        #expect(await app.status() == keyLicensed)
    }

    @Test func aFileIsKeptByAnActivationTypedOrFromAKeyFileAndStillAnswers() async throws {
        let h = try Harness()
        let file = h.signer.offlineFile()
        h.storage.set(StoredState(licenseFile: file))
        h.http.on("activate", status: 200, json: ["lease": .string(h.leaseTo3()), "activationId": "act_1"])
        let app = try h.fileApp()
        #expect(await app.activate(KEY) == .activated)
        #expect(h.stored?.key == KEY && h.stored?.licenseFile == file)
        #expect(try await app.importLicenseFile(h.signer.keyFile()) == .imported(.key, licensedTo: LicensedTo(email: adaEmail)))
        #expect(h.stored?.key == KEY && h.stored?.licenseFile == file)
        #expect(await app.status() == fileLicensed)
    }

    @Test func deactivateLeavesAFileAloneReleasingOnlyTheKey() async throws {
        let h = try Harness()
        let file = h.signer.offlineFile()
        h.storage.set(keyed(h.leaseTo3(), file: file))
        h.http.on("deactivate", status: 200, json: [:])
        let app = try h.fileApp()
        #expect(try await app.deactivate() == DeactivateResult(released: true))
        #expect(h.stored?.key == nil && h.stored?.licenseFile == file)
        #expect(await app.status() == fileLicensed)
    }

    /// `KEY` held with a second under a day left of its two-day lease (less than half its life, so due to
    /// renew early), inside an open upgrade window: an unforced status renews it and notes this major.
    func keyDue(_ h: Harness, file: String?) {
        let lease = h.signer.lease(major: 3, upgradeUntil: NOW / 1000 + 30 * 86_400, ttlSeconds: 2 * 86_400, at: NOW - DAY - 1000)
        h.storage.set(keyed(lease, file: file))
    }

    @Test func aFileThatLicensesLeavesAHeldKeyUnrenewedAndUnnotedForcedOrNot() async throws {
        let h = try Harness()
        keyDue(h, file: h.signer.offlineFile())
        let app = try h.fileApp()
        #expect(await app.status() == fileLicensed)
        #expect(await app.refresh() == fileLicensed)
        #expect(h.http.calls.isEmpty)
        #expect(h.stored?.keptMajor == nil)
    }

    @Test func withNoFileTheSameKeyIsAskedAboutAndNotedUnforcedSoTheTestAboveCanSeeIt() async throws {
        let h = try Harness()
        keyDue(h, file: nil)
        _ = try await h.fileApp().status()
        #expect(h.http.count("validate") == 1)
        #expect(h.stored?.keptMajor == 2)
    }

    @Test func aFileThatDoesNotLicenseGivesWayToTheKey() async throws {
        let h = try Harness()
        h.storage.set(keyed(h.leaseTo3(), file: h.signer.offlineFile()))
        #expect(try await h.fileApp(revoked: ["lf_1"]).status() == keyLicensed)
    }

    @Test func aFileThatDoesNotLicenseGivesWayToTheKeysStoredRefusal() async throws {
        let h = try Harness()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", refused: .revoked, licenseFile: h.signer.offlineFile()))
        h.http.setFail(true)
        #expect(try await h.fileApp(revoked: ["lf_1"]).status() == LicenseStatus(state: .invalid, reason: .revoked, key: KEY))
    }

    /// A trial this device started at `start`, five days long, beside `file`.
    func trial(_ h: Harness, start: Int, file: String?, trialAt: Int? = nil) -> StoredState {
        StoredState(
            trialStart: start, trialEndsAt: start + 5 * DAY,
            trialLease: h.signer.trialLease(device: "fp-test", kind: nil, ttlSeconds: 5 * 86_400, at: start), trialAt: trialAt,
            licenseFile: file
        )
    }

    @Test func aFileThatLicensesAnswersBeforeARunningTrialWhoseLaunchIsThenNotReported() async throws {
        let h = try Harness()
        // No stamp of a report or a trial answer: a running trial would report its launch now.
        h.storage.set(trial(h, start: NOW, file: h.signer.offlineFile()))
        let app = try h.fileApp()
        let writes = h.storage.writes
        #expect(await app.status() == fileLicensed)
        await app.launchReportSettled()
        #expect(h.http.calls.isEmpty)
        #expect(h.storage.writes == writes)
    }

    @Test func withNoFileTheSameTrialReportsItsLaunchSoTheTestAboveCanSeeIt() async throws {
        let h = try Harness()
        h.storage.set(trial(h, start: NOW, file: nil))
        let app = try h.fileApp()
        #expect(await app.status().state == .trial)
        await app.launchReportSettled()
        #expect(h.http.count("trial") == 1)
        #expect(h.stored?.trialReportedAt == NOW)
    }

    @Test func aFileThatLicensesAnswersOverAKeysStoredRefusalAskingNothing() async throws {
        let h = try Harness()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", refused: .revoked, licenseFile: h.signer.offlineFile()))
        #expect(try await h.fileApp().refresh() == fileLicensed)
        #expect(h.http.calls.isEmpty)
    }

    @Test func aFileThatDoesNotLicenseGivesWayToARunningTrial() async throws {
        let h = try Harness()
        h.storage.set(trial(h, start: NOW, file: h.signer.offlineFile(["major": 1]), trialAt: NOW))
        #expect(try await h.fileApp().status() == LicenseStatus(state: .trial, trialDaysLeft: 5, trialEndsAt: NOW + 5 * DAY))
    }

    @Test func aFileThatDoesNotLicenseAnswersInPlaceOfAnEndedTrial() async throws {
        let h = try Harness()
        h.storage.set(trial(h, start: NOW - 10 * DAY, file: h.signer.offlineFile(["major": 1]), trialAt: NOW))
        #expect(try await h.fileApp().status() == fileInvalid(.upgrade))
        #expect(h.http.calls.isEmpty)
    }

    @Test func aKeyFileActivatesItsKeyOnlineAsATypedKeyJudgingNoVersionAndStoresNoFile() async throws {
        let h = try Harness()
        let lease = h.leaseTo3()
        h.http.on("activate", status: 200, json: ["lease": .string(lease), "activationId": "act_1"])
        let app = try h.fileApp()
        // Versions on a key file are not read: this build is outside them.
        let file = h.signer.keyFile(["major": 1, "minMajor": 1])
        #expect(try await app.importLicenseFile(licenseFileText(file)) == .imported(.key, licensedTo: LicensedTo(email: adaEmail)))
        // The key as a typed one is sent: normalised.
        #expect(h.http.body("activate")?["key"] == .string(KEY) && h.http.body("activate")?["major"] == 2)
        #expect(h.stored?.key == KEY && h.stored?.lease == lease && h.stored?.licenseFile == nil)
        #expect(await app.status() == keyLicensed)
    }

    @Test func aKeyFileAnswersWhatActivateAnswersWhenTheKeyDoesNotActivate() async throws {
        let h = try Harness()
        h.http.on("activate", status: 403, json: ["error": "limit"])
        #expect(try await h.fileApp().importLicenseFile(h.signer.keyFile()) == .notActivated(.limit))
        h.http.setFail(true)
        #expect(try await h.fileApp().importLicenseFile(h.signer.keyFile()) == .notActivated(.network))
        #expect(h.stored?.key == nil && h.stored?.licenseFile == nil)
    }

    @Test func aKeyFileThrowsWhereActivateCannotReadOrSaveTheState() async throws {
        let h = try Harness()
        let app = try h.fileApp()
        h.storage.failRead(1)
        await #expect(throws: StorageError.self) { try await app.importLicenseFile(h.signer.keyFile()) }
        #expect(h.http.calls.isEmpty)
        h.http.on("activate", status: 200, json: ["lease": .string(h.leaseTo3()), "activationId": "act_1"])
        h.storage.failWrites()
        await #expect(throws: StorageError.self) { try await app.importLicenseFile(h.signer.keyFile()) }
        // The server answered, and the activation's save was tried: it is that save that failed.
        #expect(h.http.count("activate") == 1 && h.storage.writes >= 1)
    }

    @Test func aKeyFileNotForThisAppIsRefusedBeforeAnyRequest() async throws {
        let h = try Harness()
        let app = try h.fileApp(revoked: ["lf_2"])
        #expect(try await app.importLicenseFile(h.signer.keyFile(["product": "maindeck"])) == .refused(.wrongProduct))
        #expect(try await app.importLicenseFile(h.signer.keyFile()) == .refused(.revokedFile))
        #expect(h.http.calls.isEmpty)
    }

    @Test func behindACallThatHasNotFinishedImportAndRemoveThrowAndAStatusAnswersTheFile() async throws {
        let ticker = ManualTicker()
        let h = try Harness(timing: Timing(ticker: ticker))
        let token = h.signer.offlineFile()
        h.storage.set(StoredState(licenseFile: token))
        h.storage.hangNextRead()
        let stuck = Task { await h.license.status() }
        await eventually { h.storage.hungReads == 1 }
        let imported = Task { () -> Error? in
            do { _ = try await h.license.importLicenseFile(token) } catch { return error }
            return nil
        }
        let removed = Task { () -> Error? in
            do { try await h.license.removeLicenseFile() } catch { return error }
            return nil
        }
        let answered = Task { await h.license.status() }
        await eventually { ticker.deadlinesMs == [30_000] }
        ticker.advance(ms: 30_000)
        #expect(await answer { await imported.value } as? LicenseCallError == .previousCallUnfinished)
        #expect(await answer { await removed.value } as? LicenseCallError == .previousCallUnfinished)
        var stalled = fileLicensed
        stalled.isStalled = true
        #expect(await answer { await answered.value } == stalled)
        #expect(h.storage.writes == 0)
        h.storage.releaseAll()
        _ = await answer { await stuck.value }
    }
}
