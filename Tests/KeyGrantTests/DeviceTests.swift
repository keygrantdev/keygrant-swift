import Foundation
import Testing

@testable import KeyGrant

/// A Mac's IOPlatformUUID, and the machine fingerprint it gives.
let UUID_ = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
let MACHINE = machineFingerprint(UUID_)
let HOST = hostnameFingerprint()

@Suite("a lease held to its key, its activation and its device", suiteTimeLimit)
struct HeldLeaseTests {
    /// A 30-day lease for this key and activation, held (a machine-keyed seat) to `device` unless nil.
    func lease(_ h: Harness, sub: String = KEY, aid: String = "act_1", device: String? = "fp-test") -> String {
        h.signer.lease(sub: sub, aid: aid, fp: device.map(fingerprintClaim), fpk: device == nil ? nil : .machine)
    }

    @Test func licensesThisDeviceOnItsOwnLeaseOffline() async throws {
        let h = try Harness()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: lease(h), lastSeen: NOW, checkedMajor: 1))
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY))
        #expect(h.http.count("validate") == 0)
    }

    @Test func takesALeaseWithNoDeviceClaim() async throws {
        let h = try Harness()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: lease(h, device: nil), lastSeen: NOW, checkedMajor: 1))
        h.http.setFail(true)
        #expect(await h.license.status().state == .licensed)
    }

    @Test func matchesTheKeyWithoutRegardToCase() async throws {
        let h = try Harness()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: lease(h, sub: "Sluice-aaaa-BBBB-CCCC-DDDD"), lastSeen: NOW, checkedMajor: 1))
        h.http.setFail(true)
        #expect(await h.license.status().state == .licensed)
    }

    @Test(arguments: [
        ("SLUICE-OTHR-OTHR-OTHR-OTHR", "act_1", "fp-test", LicenseStatus(state: .invalid, reason: .tampered)),
        (KEY, "act_2", "fp-test", LicenseStatus(state: .invalid, reason: .tampered)),
        (KEY, "act_1", "fp-another-machine", LicenseStatus(state: .invalid, reason: .device, key: KEY)),
    ])
    func refusesOfflineALeaseForAnotherKeyActivationOrDeviceAndAsksUnderTheUsualWaits(
        sub: String, aid: String, device: String, refused: LicenseStatus
    ) async throws {
        let h = try Harness()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: lease(h, sub: sub, aid: aid, device: device), lastSeen: NOW, checkedMajor: 1))
        h.http.setFail(true)
        #expect(await h.license.status() == refused)
        #expect(h.http.count("validate") == 1)
        #expect(await h.license.status() == refused)
        #expect(h.http.count("validate") == 1)
    }

    @Test func staysRefusedForAnotherDeviceEvenOnline() async throws {
        let h = try Harness()
        let theirs = lease(h, device: "fp-another-machine")
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: theirs, lastSeen: NOW, checkedMajor: 1))
        h.http.on("validate", status: 200, json: ["lease": .string(theirs), "activationId": "act_1"])
        let device = LicenseStatus(state: .invalid, reason: .device, key: KEY)
        #expect(await h.license.status() == device)
        #expect(await h.license.refresh() == device)
    }

    @Test func saysDeviceOfflineTooOnceALeaseWithNoDeviceClaimIsRenewedWithAnotherDevices() async throws {
        let h = try Harness()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: lease(h, device: nil), lastSeen: NOW, checkedMajor: 1))
        h.http.on("validate", status: 200, json: ["lease": .string(lease(h, device: "fp-another-machine")), "activationId": "act_1"])
        let device = LicenseStatus(state: .invalid, reason: .device, key: KEY)
        #expect(await h.license.refresh() == device)
        h.http.setFail(true)
        #expect(await h.license.status() == device)
    }
}

@Suite("who this device is, when it cannot be told", suiteTimeLimit)
struct DeviceIdentityTests {
    /// A licence lease for this key and activation, its seat keyed (`kind`) by the fingerprint `device`.
    func lease(_ h: Harness, _ device: String, kind: DeviceKind = .machine) -> String {
        h.signer.lease(fp: fingerprintClaim(device), fpk: kind)
    }

    func licensed(_ h: Harness, _ lease: String, deviceKind: DeviceKind? = nil) {
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: lease, lastSeen: NOW, checkedMajor: 1, deviceKind: deviceKind))
    }

    @Test func doesNotCallASlowFirstReadAnotherDevice() async throws {
        let source = mac(.hang, .value(UUID_))
        let first = try Harness(fingerprinter: DefaultFingerprinter(source: source), timing: quick)
        licensed(first, lease(first, MACHINE))
        first.http.setFail(true)
        // The read outlives its time box: this run cannot tell, and does not judge.
        #expect(await first.license.status() == LicenseStatus(state: .licensed, key: KEY))
        // Another fingerprinter on the same machine, whose read answers: the id.
        let second = try Harness(fingerprinter: DefaultFingerprinter(source: source), timing: quick)
        licensed(second, lease(second, MACHINE))
        second.http.setFail(true)
        #expect(await second.license.status() == LicenseStatus(state: .licensed, key: KEY))
        #expect(source.reads.count == 2)
    }

    @Test func givesAnActivationItsFullBoundThenActivatesUnderTheHostNameAndMovesToTheIdOnceItReads() async throws {
        let ticker = ManualTicker()
        let fingerprinter = DefaultFingerprinter(source: mac(.hang, .value(UUID_)), ticker: ticker)
        let h = try Harness(fingerprinter: fingerprinter, timing: Timing(ticker: ticker))
        h.http.on("activate", status: 200, json: ["lease": .string(lease(h, HOST, kind: .hostname)), "activationId": "act_1"])
        let answered = Flag()
        let activating = Task { () -> ActivateResult in
            let result = await h.license.activate(KEY)
            answered.set(true)
            return result
        }
        // Not the status bound: the activation's, 10 s (the read's own), inside the reader's 11 s.
        await eventually { ticker.deadlinesMs == [10_000, 11_000] }
        #expect(ticker.deadlinesMs == [10_000, 11_000])
        ticker.advance(ms: 9_999)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!answered.on, "answered before its bound")
        ticker.advance(ms: 1)
        #expect(await answer { await activating.value } == .activated)
        #expect(h.http.body("activate")?["fingerprint"]?.stringValue == HOST)
        #expect(h.http.body("activate")?["fingerprintKind"] == "hostname")
        #expect(h.stored?.deviceKind == .hostname)
        // The id reads now: the renewal sends it first, as a machine id, and the install is keyed by it.
        h.http.on("validate", status: 200, json: ["lease": .string(lease(h, MACHINE)), "activationId": "act_1"])
        #expect(await answer { await h.license.refresh() } == LicenseStatus(state: .licensed, key: KEY))
        #expect(h.http.body("validate")?["fingerprints"] == .array([.string(MACHINE), .string(HOST)]))
        #expect(h.http.body("validate")?["fingerprintKind"] == "machine")
        #expect(h.stored?.deviceKind == .machine)
    }

    /// A phone whose Keychain cannot be read this time (a device locked since it started), and its
    /// source, which counts the reads.
    func lockedPhone() throws -> (h: Harness, source: ScriptedMachineSource) {
        let source = iPhone(.failure(ScriptedMachineSource.Odd()))
        return (try Harness(fingerprinter: DefaultFingerprinter(source: source), timing: quick), source)
    }

    @Test func activatesAnIPhoneUnderItsInstallIdAloneAndNeverUnderAHostName() async throws {
        // The id cannot be read this time: nothing to activate under.
        let (locked, keychain) = try lockedPhone()
        #expect(await locked.license.activate(KEY) == .failed(.network))
        #expect(!locked.http.called("activate") && keychain.installReads.count > 0)
        // It reads: the seat is keyed by it, and a renewal tells the server it and nothing else.
        let h = try Harness(fingerprinter: DefaultFingerprinter(source: iPhone(.value(INSTALL_ID))))
        h.http.on("activate", status: 200, json: ["lease": .string(lease(h, PHONE)), "activationId": "act_1"])
        #expect(await h.license.activate(KEY) == .activated)
        #expect(h.http.body("activate")?["fingerprint"]?.stringValue == PHONE)
        #expect(h.http.body("activate")?["fingerprintKind"] == "machine")
        #expect(h.stored?.deviceKind == .machine)
        h.http.on("validate", status: 200, json: ["lease": .string(lease(h, PHONE)), "activationId": "act_1"])
        #expect(await h.license.refresh() == LicenseStatus(state: .licensed, key: KEY))
        #expect(h.http.body("validate")?["fingerprints"] == .array([.string(PHONE)]))
        #expect(h.http.body("validate")?["fingerprintKind"] == "machine")
    }

    @Test func keepsAnIPhoneLicensedAndTellsTheServerNothingWhileItsIdCannotBeRead() async throws {
        let (h, keychain) = try lockedPhone()
        licensed(h, lease(h, PHONE), deviceKind: .machine)
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY))
        h.http.setFail(false)
        h.http.on("validate", status: 200, json: ["lease": .string(lease(h, PHONE)), "activationId": "act_1"])
        #expect(await h.license.refresh() == LicenseStatus(state: .licensed, key: KEY))
        #expect(h.http.body("validate")?.has("fingerprints") == false)
        #expect(keychain.installReads.count > 0)
    }

    @Test func readsAStateRestoredOntoAnotherIPhoneAsAnotherDeviceUntilItActivatesThere() async throws {
        // A backup restored onto a new phone brings the state file, never the install id.
        let newPhone = machineFingerprint("ios:9B2A44C0-1D3E-4F5A-8B6C-7D8E9F0A1B2C")
        let h = try Harness(fingerprinter: DefaultFingerprinter(source: iPhone(.value("9B2A44C0-1D3E-4F5A-8B6C-7D8E9F0A1B2C"))))
        licensed(h, lease(h, PHONE), deviceKind: .machine)
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .invalid, reason: .device, key: KEY))
        // The customer activates again there: a seat of its own.
        h.http.setFail(false)
        let held = h.signer.lease(aid: "act_2", fp: fingerprintClaim(newPhone), fpk: .machine)
        h.http.on("activate", status: 200, json: ["lease": .string(held), "activationId": "act_2"])
        #expect(await h.license.activate(KEY) == .activated)
        #expect(h.http.body("activate")?["fingerprint"]?.stringValue == newPhone)
        #expect(h.stored?.activationId == "act_2" && h.stored?.deviceKind == .machine)
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY))
    }

    @Test func startsAnIPhonesTrialUnderItsInstallIdAndNoneWhileItCannotBeRead() async throws {
        let (locked, keychain) = try lockedPhone()
        #expect(await locked.license.startTrial().state != .trial)
        #expect(!locked.http.called("trial") && keychain.installReads.count > 0)
        let h = try Harness(fingerprinter: DefaultFingerprinter(source: iPhone(.value(INSTALL_ID))))
        let trialLease = h.signer.trialLease(device: PHONE, ttlSeconds: 5 * 24 * 3600)
        h.http.on("trial", status: 200, json: [
            "trialStart": .number(Double(NOW)), "trialEndsAt": .number(Double(NOW + 5 * DAY)), "lease": .string(trialLease),
        ])
        #expect(await h.license.startTrial().state == .trial)
        #expect(h.http.body("trial") == ["fingerprint": .string(PHONE), "fingerprintKind": "machine"])
    }

    @Test func neverReactivatesTheSeatAMachineIdKeyedUnderTheHostName() async throws {
        let h = try Harness(StoredState(key: KEY, activationId: "act_1", lastSeen: NOW, deviceKind: .machine),
                            fingerprinter: DefaultFingerprinter(source: mac(.hang, .value(UUID_))), timing: quick)
        #expect(await h.license.activate(KEY) == .failed(.network))
        #expect(!h.http.called("activate"))
    }

    @Test func keepsToTheSeatWhateverCaseItsKeyWasStoredIn() async throws {
        let h = try Harness(StoredState(key: KEY.lowercased(), activationId: "act_1", lastSeen: NOW, deviceKind: .machine),
                            fingerprinter: DefaultFingerprinter(source: mac(.value(nil))), timing: quick)
        #expect(await h.license.activate(KEY) == .failed(.network))
        #expect(!h.http.called("activate"))
    }

    @Test func takesALeaseActivatedUnderTheHostNameAndRenewsIt() async throws {
        let h = try Harness(fingerprinter: DefaultFingerprinter(source: mac(.value(UUID_))))
        let legacy = lease(h, HOST, kind: .hostname)
        licensed(h, legacy)
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY))
        h.http.setFail(false)
        h.http.on("validate", status: 200, json: ["lease": .string(legacy), "activationId": "act_1"])
        #expect(await h.license.refresh() == LicenseStatus(state: .licensed, key: KEY))
        #expect(h.http.body("validate")?["fingerprints"] == .array([.string(MACHINE), .string(HOST)]))
    }

    @Test func doesNotJudgeTheDeviceNorTellTheServerWhoItIsOnARunThatCannotTell() async throws {
        let calls = Counter()
        let h = try Harness(fingerprinter: GetFingerprinter {
            calls.next()
            throw FakeHTTP.NetworkDown()
        })
        let elsewhere = lease(h, "fp-another-machine")
        licensed(h, elsewhere)
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY))
        h.http.on("validate", status: 200, json: ["lease": .string(elsewhere), "activationId": "act_1"])
        #expect(await h.license.refresh() == LicenseStatus(state: .licensed, key: KEY))
        #expect(h.http.body("validate")?.has("fingerprints") == false)
        // Not kept: every call asks the adapter again.
        #expect(calls.count > 1)
    }

    @Test func readsAgainAfterAnAdapterThatFailedAndJudgesTheDeviceOnceItCanTell() async throws {
        let failing = Flag(true)
        let h = try Harness(fingerprinter: GetFingerprinter {
            if failing.on { throw FakeHTTP.NetworkDown() }
            return "fp-test"
        })
        licensed(h, lease(h, "fp-another-machine"))
        h.http.setFail(true)
        #expect(await h.license.status().state == .licensed)
        failing.set(false)
        #expect(await h.license.status() == LicenseStatus(state: .invalid, reason: .device, key: KEY))
    }

    @Test func boundsAFingerprinterThatNeverAnswersToTheMillisecondCancelsItAndDoesNotKeepThat() async throws {
        let calls = Counter()
        let cancelled = Counter()
        let ticker = ManualTicker()
        let h = try Harness(fingerprinter: GetFingerprinter {
            calls.next()
            try? await Task.sleep(nanoseconds: hangNanoseconds)
            // Seen once the SDK's bound gives up on it: cancelled, not left running.
            if Task.isCancelled { cancelled.next() }
            throw CancellationError()
        }, timing: Timing(ticker: ticker))
        licensed(h, lease(h, "fp-test"))
        h.http.setFail(true)
        for call in 1...2 {
            let answered = Flag()
            let status = Task { () -> LicenseStatus in
                let status = await h.license.status()
                answered.set(true)
                return status
            }
            // A get()-only fingerprinter has the status bound (2 s), with no slack.
            let bound = Double(ticker.now()) / 1_000_000 + Timing.standard.machineId * 1_000
            await eventually { ticker.deadlinesMs == [bound] }
            #expect(ticker.deadlinesMs == [bound])
            ticker.advance(ms: 1_999)
            try await Task.sleep(nanoseconds: 50_000_000)
            #expect(!answered.on, "answered before its bound")
            ticker.advance(ms: 1)
            // Cannot tell: the lease is not judged by its device.
            #expect(await answer { await status.value } == LicenseStatus(state: .licensed, key: KEY))
            await eventually { cancelled.count == call }
            #expect(cancelled.count == call)
        }
        // Not kept: every call asks the adapter again.
        #expect(calls.count == 2)
    }

    @Test func keepsASettledFingerprintSoTheAdapterIsAskedOnce() async throws {
        let calls = Counter()
        let h = try Harness(fingerprinter: GetFingerprinter {
            calls.next()
            return "fp-test"
        })
        licensed(h, lease(h, "fp-test"))
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY))
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY))
        #expect(calls.count == 1)
    }

    @Test func takesTheServersDeviceRefusalForThisDeviceOnly() async throws {
        let h = try Harness()
        licensed(h, lease(h, "fp-test"))
        h.http.on("validate", status: 403, json: ["error": "device"])
        #expect(await h.license.refresh() == LicenseStatus(state: .invalid, reason: .device, key: KEY))
        #expect(h.http.body("validate")?["fingerprints"] == ["fp-test"])
        // A get()-only fingerprinter says nothing of what it hashes: no kind is claimed for it.
        #expect(h.http.body("validate")?.has("fingerprintKind") == false)
        // Kept, refused for this device only.
        #expect(h.stored?.refused == .device && h.stored?.refusedFor == [fingerprintClaim("fp-test")])
        #expect(h.stored?.lease != nil)
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .invalid, reason: .device, key: KEY))
    }

    @Test func licensesAgainAtOnceWhenTheFingerprintFlipsBackAfterADeviceRefusal() async throws {
        let fingerprint = Shared("fp-flipped")
        let flipping = GetFingerprinter { fingerprint.current }
        let h = try Harness(fingerprinter: flipping)
        licensed(h, lease(h, "fp-test"))
        h.http.on("validate", status: 403, json: ["error": "device"])
        #expect(await h.license.refresh().reason == .device)
        // The next run reads the device as it was: the refusal was not for it.
        fingerprint.set("fp-test")
        h.http.setFail(true)
        #expect(try await h.license(major: 1).status() == LicenseStatus(state: .licensed, key: KEY))
    }

    @Test func doesNotStandADeviceRefusalOnALaterRunThatOnlySharesItsHostNameAlternate() async throws {
        let own = Shared("fp-boot-1")
        let booting = IdentifyingFingerprinter { DeviceIdentity(fingerprint: own.current, kind: .machine, alternates: ["fp-same-host"]) }
        let h = try Harness(fingerprinter: booting)
        // A lease whose seat's kind is unknown: not itself judged by its device.
        licensed(h, h.sign())
        h.http.on("validate", status: 403, json: ["error": "device"])
        #expect(await h.license.refresh().reason == .device)
        #expect(h.stored?.refusedFor == [fingerprintClaim("fp-boot-1")])
        own.set("fp-boot-2")
        h.http.setFail(true)
        #expect(try await h.license(major: 1).status() == LicenseStatus(state: .licensed, key: KEY))
    }

    @Test func doesNotRefuseAMachineKeyedInstallWhoseIdStopsReading() async throws {
        // The id worked here (deviceKind); now it reads as none. That says nothing about the
        // machine changing: cannot tell, never the host name.
        let h = try Harness(fingerprinter: DefaultFingerprinter(source: mac(.value(nil))))
        let held = lease(h, MACHINE)
        licensed(h, held, deviceKind: .machine)
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY))
        h.http.setFail(false)
        h.http.on("validate", status: 200, json: ["lease": .string(held), "activationId": "act_1"])
        #expect(await h.license.refresh() == LicenseStatus(state: .licensed, key: KEY))
        #expect(h.http.body("validate")?.has("fingerprints") == false)
        #expect(h.stored?.lease == held && h.stored?.deviceKind == .machine)
    }

    @Test(arguments: [ScriptedMachineSource.Answer.value(UUID_), .value(nil)])
    func doesNotRefuseAHostNameKeyedSeat(read: ScriptedMachineSource.Answer) async throws {
        // Activated under a host name this machine no longer has (renamed, or an x64 build under
        // Rosetta moved to arm64).
        let h = try Harness(fingerprinter: DefaultFingerprinter(source: mac(read)))
        licensed(h, lease(h, hashFingerprint("old-name|darwin|x64"), kind: .hostname))
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY))
    }

    @Test func doesNotJudgeALeaseWhoseSeatsKindIsUnknown() async throws {
        let h = try Harness(fingerprinter: DefaultFingerprinter(source: mac(.value(UUID_))))
        licensed(h, h.signer.lease(fp: fingerprintClaim(hashFingerprint("old-name|darwin|x64"))))
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY))
    }

    @Test func holdsNothingToItsDeviceWithDeviceHoldFalse() async throws {
        let h = try Harness(fingerprinter: DefaultFingerprinter(source: mac(.value(UUID_))), deviceHold: false)
        h.http.on("activate", status: 200, json: ["lease": .string(lease(h, MACHINE)), "activationId": "act_1"])
        #expect(await h.license.activate(KEY) == .activated)
        #expect(h.http.body("activate")?["fingerprint"]?.stringValue == MACHINE)
        #expect(h.http.body("activate")?.has("fingerprintKind") == false)
        #expect(h.stored?.deviceKind == nil)
        // A machine-keyed lease for another machine: not judged.
        let elsewhere = lease(h, "fp-another-machine")
        licensed(h, elsewhere)
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY))
        // And the server is told no fingerprints to check.
        h.http.setFail(false)
        h.http.on("validate", status: 200, json: ["lease": .string(elsewhere), "activationId": "act_1"])
        #expect(await h.license.refresh() == LicenseStatus(state: .licensed, key: KEY))
        #expect(h.http.body("validate")?.has("fingerprints") == false)
        #expect(h.http.body("validate")?.has("fingerprintKind") == false)
    }

    @Test func activatesUnderTheHostNameWithDeviceHoldFalseOnAnInstallAMachineIdOnceKeyed() async throws {
        let h = try Harness(StoredState(key: KEY, activationId: "act_1", lastSeen: NOW, deviceKind: .machine),
                            fingerprinter: DefaultFingerprinter(source: mac(.value(nil))), deviceHold: false)
        h.http.on("activate", status: 200, json: ["lease": .string(lease(h, MACHINE)), "activationId": "act_1"])
        #expect(await h.license.activate(KEY) == .activated)
        #expect(h.http.body("activate")?["fingerprint"]?.stringValue == HOST)
        #expect(h.http.body("activate")?.has("fingerprintKind") == false)
        // It writes the kind it used, none: the stored machine kind is cleared.
        #expect(h.stored?.deviceKind == nil)
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY))
    }

    @Test func clearsAStoredMachineKindWhenAFingerprintOfUnknownKindActivatesTheSeat() async throws {
        let h = try Harness(StoredState(key: KEY, activationId: "act_1", lastSeen: NOW, deviceKind: .machine))
        h.http.on("activate", status: 200, json: ["lease": .string(h.sign()), "activationId": "act_1"])
        #expect(await h.license.activate(KEY) == .activated)
        #expect(h.stored?.deviceKind == nil)
    }

    @Test func activatesUnderTheHostNameAfterADeactivateFreesAMachineInstallWhoseIdNoLongerReads() async throws {
        let h = try Harness(fingerprinter: DefaultFingerprinter(source: mac(.value(nil))))
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: lease(h, MACHINE), lastSeen: NOW, checkedMajor: 1, deviceKind: .machine))
        h.http.on("deactivate", status: 200, json: ["ok": true])
        try await h.license.deactivate()
        #expect(h.stored?.deviceKind == nil)
        h.http.on("activate", status: 200, json: ["lease": .string(lease(h, HOST, kind: .hostname)), "activationId": "act_1"])
        #expect(await h.license.activate(KEY) == .activated)
        #expect(h.http.body("activate")?["fingerprint"]?.stringValue == HOST)
        #expect(h.http.body("activate")?["fingerprintKind"] == "hostname")
        #expect(h.stored?.deviceKind == .hostname)
    }

    @Test func activatesAnotherKeyUnderTheHostNameOnAMachineInstallWhoseIdNoLongerReads() async throws {
        let h = try Harness(StoredState(key: "SLUICE-OLDK-OLDK-OLDK-OLDK", activationId: "act_1", lastSeen: NOW, deviceKind: .machine),
                            fingerprinter: DefaultFingerprinter(source: mac(.value(nil))))
        h.http.on("activate", status: 200, json: ["lease": .string(lease(h, HOST, kind: .hostname)), "activationId": "act_1"])
        #expect(await h.license.activate(KEY) == .activated)
        #expect(h.http.body("activate")?["fingerprint"]?.stringValue == HOST)
        #expect(h.http.body("activate")?["fingerprintKind"] == "hostname")
    }

    @Test func takesATrialLeaseStartedUnderTheHostNameItAnswersToBesidesItsMachineId() async throws {
        let h = try Harness(fingerprinter: DefaultFingerprinter(source: mac(.value(UUID_))))
        h.storage.set(StoredState(trialStart: NOW - 2 * DAY, trialLease: h.signer.trialLease(device: HOST, kind: .machine), lastSeen: NOW))
        #expect(await h.license.status().state == .trial)
    }

    @Test func startsATrialUnderItsOwnFingerprintSayingItIsAMachineId() async throws {
        let h = try Harness(fingerprinter: DefaultFingerprinter(source: mac(.value(UUID_))))
        h.http.on("trial", status: 200, json: ["trialStart": .number(Double(NOW)), "trialEndsAt": .number(Double(NOW + 7 * DAY))])
        _ = await h.license.startTrial()
        #expect(h.http.body("trial") == ["fingerprint": .string(MACHINE), "fingerprintKind": "machine"])
    }
}
