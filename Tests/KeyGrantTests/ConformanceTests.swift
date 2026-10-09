import Foundation
import Testing

@testable import KeyGrant

/// `conformance/vectors.json`: what every KeyGrant SDK must answer, generated from the reference.
/// Each group is answered here from its vectors' own JSON, and every answer must equal the file's.
@Suite("Conformance vectors", suiteTimeLimit)
struct ConformanceTests {
    static let file: LicenseJSON? = {
        // Up from this file to the folder that holds conformance/vectors.json (the repo root).
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = folder.appendingPathComponent("conformance/vectors.json")
            if let data = try? Data(contentsOf: candidate) { return JSONText.parse(decoding: data) }
            folder.deleteLastPathComponent()
        }
        return nil
    }()

    func group(_ name: String) throws -> [LicenseJSON] {
        let file = try #require(Self.file, "conformance/vectors.json not found above the tests")
        let vectors = try #require(file[name]?.arrayValue, "no group \(name)")
        #expect(!vectors.isEmpty, "the group \(name) is empty")
        return vectors
    }

    @Test func theFileIsTheOneThisSuiteReads() throws {
        let file = try #require(Self.file)
        let groups = (file.objectValue ?? [:]).filter { $0.value.arrayValue != nil && $0.key != "conventions" }
        // Every group in the file has a test below; a new group fails here until it does.
        #expect(Set(groups.keys) == Self.answered)
        let key = try publicKeyBytes(fromJWK: try #require(file["publicJwk"]).jsonText)
        #expect(key.count == 32)
        // What the README says this suite replays: every vector but the Windows reads of the
        // machine id (`machineIds`), which this SDK, with no Windows reader, does not make, and
        // the majors with a fraction, which `LicenseConfig.major` (an `Int`) cannot hold (`majors`).
        let total = groups.values.reduce(0) { $0 + ($1.arrayValue?.count ?? 0) }
        let windows = try group("machineIds").filter { $0["source"]?["platform"] == "win32" }.count
        let fractions = try group("majors").filter { vector in
            (vector["configured"]?.numberValue).map { $0 != $0.rounded(.towardZero) } == true
        }.count
        #expect(groups.count == 43 && total == 716 && windows == 9 && fractions == 4)
        #expect(total - windows - fractions == 703)
    }

    static let answered: Set<String> = [
        "leases", "trials", "fingerprintClaims", "fingerprints", "machineFingerprints", "hostFingerprints", "kept",
        "renew", "asks", "standing", "trialStatuses", "refusalPatches", "leasePatches", "keyedBy", "merges",
        "guardedNow", "clockCorrections", "mapServerError", "refusalOf", "enteredKey", "trimDeviceName", "noAnswer",
        "parseLeaseBody", "parseTrialBody", "mountinfo", "machineIds", "renewals", "validLeaseAsks", "devices",
        "identities", "savedLastSeen", "leaseStatuses", "trialLeaseStatuses", "entitlementNumbers",
        // Added with the purchase from the trial (ConformancePurchaseTests.swift).
        "majors", "purchaseUrls", "purchaseTokenKept", "claimDue", "parseClaimBody", "claimOutcomes", "trialReportDue",
        "purchaseReferences", "claimBodies",
    ]

    /// Answers are compared as JSON is, unit for unit: text only canonically equivalent to the
    /// file's (an "é" decomposed) is another answer, and in a patch a field cleared (`null`) is
    /// another answer than a field left alone (absent).
    @Test func comparesEveryAnswerExactly() throws {
        #expect(LicenseJSON.string("\u{E9}") != .string("e\u{301}"))
        #expect(LicenseJSON.object(["\u{E9}": 1]) != .object(["e\u{301}": 1]))
        #expect(LicenseJSON.array([.string("\u{E9}")]) != .array([.string("e\u{301}")]))
        #expect(LicenseJSON.object(["keptMajor": .null]) != .object([:]))
        #expect(StatePatch([.keptMajor: .clear]).json != StatePatch().json)
        // A device name cut to length, and handed back decomposed, is not the file's answer.
        let composed = try group("trimDeviceName").first { vector in
            guard let input = vector["input"]?.stringValue else { return false }
            return !input.unicodeScalars.elementsEqual(input.decomposedStringWithCanonicalMapping.unicodeScalars)
        }
        let vector = try #require(composed, "a vector with composed text")
        let trimmed = try #require(trimToLength(try vector.string("input"), try vector.int("max")))
        #expect(LicenseJSON.string(trimmed) == vector["expect"])
        #expect(LicenseJSON.string(trimmed.decomposedStringWithCanonicalMapping) != vector["expect"])
    }

    @Test func constants() throws {
        let constants = try #require(Self.file?["constants"])
        let ours: [String: LicenseJSON] = [
            "OPEN_MAJOR": .number(Double(openMajor)),
            "ASK_AGAIN_MS": .number(Double(Waits.askAgainMs)),
            "RETRY_UNANSWERED_MS": .number(Double(Waits.retryUnansweredMs)),
            "RENEW_WITHIN_MS": .number(Double(Waits.renewWithinMs)),
            "CLOCK_TOLERANCE_MS": .number(Double(Waits.clockToleranceMs)),
            "STATUS_CHECK_TIMEOUT_MS": .number(Timing.standard.statusCheck * 1000),
            "DEFAULT_HTTP_TIMEOUT_MS": .number(LicenseConfig(product: "p", apiBaseURL: apiBase, publicJWK: "").httpTimeout * 1000),
            "LOCK_GRACE_MS": .number(Timing.standard.lockGrace * 1000),
            "MACHINE_ID_TIMEOUT_MS": .number(Timing.standard.machineId * 1000),
            "ACTIVATE_MACHINE_ID_TIMEOUT_MS": .number(Timing.standard.activateMachineId * 1000),
            "BOOT_SLACK_MS": .number(bootSlackMs),
            "MAX_DEVICE_NAME": .number(Double(maxDeviceName)),
            "MAX_KEY": .number(Double(maxKey)),
            "KEEP_CORRUPT": .number(Double(keepCorrupt)),
            "STALE_TEMP_MS": .number(staleTempMs),
            "UPDATE_ATTEMPTS": .number(Double(updateAttempts)),
            "UNKNOWN_HOST": .string(unknownHost),
            "CLAIM_WAIT_MS": .number(Double(Waits.claimWaitMs)),
            "PURCHASE_TOKEN_MS": .number(Double(Waits.purchaseTokenMs)),
            "TRIAL_REPORT_MS": .number(Double(Waits.trialReportMs)),
            "PURCHASE_REFERENCE_PREFIX": .string(purchaseReferencePrefix),
            "CLAIM_EAGER_MS": .number(Double(Waits.claimEagerMs)),
            "MAX_CLAIM_FINGERPRINTS": .number(Double(maxClaimFingerprints)),
            "MAX_CLAIM_FINGERPRINT_LENGTH": .number(Double(maxClaimFingerprintLength)),
        ]
        #expect(constants == .object(ours))
    }

    @Test func leases() throws {
        let file = try #require(Self.file)
        let key = try publicKeyBytes(fromJWK: try #require(file["publicJwk"]).jsonText)
        let vectors = try group("leases")
        for vector in vectors {
            let name = vector.name
            let holder = LeaseHolder(
                key: try vector.string("holder", "key"),
                activationId: try vector.string("holder", "activationId"),
                claims: try #require(vector["holder"]?["claims"]?.arrayValue).compactMap(\.stringValue),
                canTell: try vector.bool("holder", "canTell")
            )
            let verified = verifyLease(try vector.string("token"), publicKey: key, now: try vector.int("now"))
            // The claims as parsed, `ent` read leniently: its flag, number and text members only.
            #expect(verified.json == vector["verify"], "\(name): verify")
            let check = checkLease(verified, product: try vector.string("product"), major: try vector.int("major"), holder: holder)
            #expect(check.json == vector["expect"], "\(name): checkLease")
        }
        // Every verdict the offline check can give is pinned.
        let verdicts = Set(vectors.compactMap { $0["expect"]?["reason"]?.stringValue ?? ($0["expect"]?["ok"]?.boolValue == true ? "ok" : nil) })
        #expect(verdicts == ["device", "expired", "ok", "outdated", "tampered", "upgrade"])
    }

    @Test func trials() throws {
        let key = try publicKeyBytes(fromJWK: try #require(Self.file?["publicJwk"]).jsonText)
        for vector in try group("trials") {
            let verified = verifyLease(try vector.string("token"), publicKey: key, now: try vector.int("now"))
            let valid = trialLeaseValid(
                verified,
                product: try vector.string("product"),
                claims: try #require(vector["device"]?["claims"]?.arrayValue).compactMap(\.stringValue),
                canTell: try vector.bool("device", "canTell")
            )
            #expect(.bool(valid) == vector["expect"], "\(vector.name)")
        }
    }

    @Test func fingerprints() throws {
        for vector in try group("fingerprintClaims") {
            #expect(.string(fingerprintClaim(try vector.string("input"))) == vector["claim"], "claim of \(vector["input"] ?? .null)")
        }
        for vector in try group("fingerprints") {
            #expect(.string(hashFingerprint(try vector.string("raw"))) == vector["fingerprint"], "\(vector["raw"] ?? .null)")
        }
        for vector in try group("machineFingerprints") {
            #expect(.string(machineFingerprint(try vector.string("id"))) == vector["fingerprint"], "\(vector["id"] ?? .null)")
        }
        for vector in try group("hostFingerprints") {
            let fingerprint = hostFingerprint(
                host: try vector.string("host"), platform: try vector.string("platform"), arch: try vector.string("arch")
            )
            #expect(.string(fingerprint) == vector["fingerprint"], "\(vector["host"] ?? .null)")
        }
    }

    @Test func kept() throws {
        for vector in try group("kept") {
            var claims = baseClaims
            claims.upgradeUntil = vector["upgradeUntil"]?.numberValue
            let kept = keptWith(vector["kept"]?.intValue, claims: claims, now: try vector.int("now"), major: try vector.int("major"))
            #expect(kept.map { LicenseJSON.number(Double($0)) } ?? .null == vector["expect"], "\(vector.name)")
        }
    }

    @Test func renew() throws {
        for vector in try group("renew") {
            var claims = baseClaims
            claims.iat = try #require(vector["iat"]?.numberValue)
            claims.exp = try #require(vector["exp"]?.numberValue)
            #expect(.bool(renewsEarly(claims, now: try vector.int("now"))) == vector["expect"], "\(vector.name)")
        }
    }

    @Test func asks() throws {
        for vector in try group("asks") {
            let due = askDue(
                StoredState(json: try #require(vector["state"])),
                clockNow: try vector.int("clockNow"),
                force: try vector.bool("force")
            )
            #expect(.bool(due) == vector["expect"], "\(vector.name)")
        }
    }

    @Test func standing() throws {
        for vector in try group("standing") {
            var device: (ownClaim: String?, canTell: Bool)?
            if let given = vector["device"], !given.isNull {
                device = (ownClaim: given["ownClaim"]?.stringValue, canTell: given["canTell"]?.boolValue ?? true)
            }
            let refused = standingRefusal(StoredState(json: try #require(vector["state"])), major: try vector.int("major"), device: device)
            #expect(refused.map { LicenseJSON.string($0.rawValue) } ?? .null == vector["expect"], "\(vector.name)")
        }
    }

    @Test func trialStatuses() throws {
        for vector in try group("trialStatuses") {
            let status = trialStatusOf(
                StoredState(json: try #require(vector["state"])),
                now: try vector.int("now"),
                leaseValid: try vector.bool("leaseValid"),
                leaseEndsAt: vector["leaseEndsAt"]?.intValue
            )
            #expect(status.json == vector["expect"], "\(vector.name)")
        }
    }

    @Test func patches() throws {
        for vector in try group("refusalPatches") {
            let refused = try #require(Refusal(rawValue: try vector.string("refused")))
            let patch = refusalPatch(refused, major: try vector.int("major"), ownClaim: vector["device"]?["ownClaim"]?.stringValue)
            #expect(patch.json == vector["expect"], "\(vector.name)")
        }
        let named = ["LEASED": leased, "UNKEYED": unkeyed, "NO_PURCHASE": noPurchase]
        for vector in try group("leasePatches") {
            let patch = try #require(named[try vector.string("patch")], "\(vector.name)")
            #expect(patch.json == vector["expect"], "\(vector.name)")
        }
        for vector in try group("keyedBy") {
            let kind = vector["kind"]?.stringValue.flatMap(DeviceKind.init(rawValue:))
            let device = Device(
                own: "fingerprint-own", kind: kind, canTell: true, fingerprints: ["fingerprint-own"], claims: [], hostname: nil
            )
            #expect(keyedBy(device).json == vector["expect"], "\(vector.name)")
        }
    }

    @Test func merges() throws {
        for vector in try group("merges") {
            let latest = StoredState(json: try #require(vector["latest"]))
            let patch = try StatePatch(json: try #require(vector["patch"]))
            let basis = try Basis(json: vector["basis"] ?? .null)
            #expect(merged(latest, patch, basis).json == vector["expect"], "\(vector.name)")
        }
    }

    @Test func theClock() throws {
        for vector in try group("guardedNow") {
            let now = guardedNow(try vector.int("clockNow"), vector["lastSeen"]?.intValue)
            #expect(.number(Double(now)) == vector["expect"], "\(vector.name)")
        }
        for vector in try group("clockCorrections") {
            let claims = try vector["claims"].flatMap { claims -> SignedAt? in
                if claims.isNull { return nil }
                return SignedAt(
                    sub: try #require(claims["sub"]?.stringValue),
                    aid: try #require(claims["aid"]?.stringValue),
                    iat: try #require(claims["iat"]?.numberValue)
                )
            }
            let corrected = clockCorrection(
                clockNow: try vector.int("clockNow"),
                lastSeen: vector["lastSeen"]?.intValue,
                claims: claims,
                heldIat: vector["heldIat"]?.numberValue,
                key: try vector.string("key"),
                activationId: try vector.string("activationId")
            )
            #expect(corrected.map { LicenseJSON.number(Double($0)) } ?? .null == vector["expect"], "\(vector.name)")
        }
    }

    @Test func wireWords() throws {
        for vector in try group("mapServerError") {
            let error = mapServerError(vector["error"]?.stringValue)
            #expect(.string(error.rawValue) == vector["expect"], "\(vector["error"] ?? .null)")
        }
        for vector in try group("refusalOf") {
            let refusal = refusalOf(vector["error"]?.stringValue)
            #expect(refusal.map { LicenseJSON.string($0.rawValue) } ?? .null == vector["expect"], "\(vector["error"] ?? .null)")
        }
        for vector in try group("enteredKey") {
            let entered = enteredKey(try vector.string("input"))
            #expect(entered.map(LicenseJSON.string) ?? .null == vector["expect"], "\(vector["input"] ?? .null)")
        }
        for vector in try group("trimDeviceName") {
            let trimmed = trimToLength(try vector.string("input"), try vector.int("max"))
            #expect(trimmed.map(LicenseJSON.string) ?? .null == vector["expect"], "\(vector["input"] ?? .null)")
        }
        for vector in try group("noAnswer") {
            #expect(.bool(noAnswer(try vector.int("status"))) == vector["expect"], "\(vector["status"] ?? .null)")
        }
    }

    @Test func answerBodies() throws {
        for vector in try group("parseLeaseBody") {
            let (lease, activationId) = parseLeaseBody(vector["body"])
            var answer: [String: LicenseJSON] = [:]
            if let lease { answer["lease"] = .string(lease) }
            if let activationId { answer["activationId"] = .string(activationId) }
            #expect(.object(answer) == vector["expect"], "\(vector["body"] ?? .null)")
        }
        for vector in try group("parseTrialBody") {
            let answer = parseTrialBody(vector["body"]).map { body -> LicenseJSON in
                var members: [String: LicenseJSON] = [
                    "trialStart": .number(Double(body.trialStart)), "trialEndsAt": .number(Double(body.trialEndsAt)),
                ]
                if let lease = body.lease { members["lease"] = .string(lease) }
                return .object(members)
            }
            #expect(answer ?? .null == vector["expect"], "\(vector["body"] ?? .null)")
        }
    }

    @Test func mountinfo() throws {
        for vector in try group("mountinfo") {
            let filesystem = machineIdFilesystem(try vector.string("mountinfo"))
            #expect(filesystem.map(LicenseJSON.string) ?? .null == vector["expect"], "\(vector.name)")
        }
    }

    /// The scripted reads: every Linux case through the Linux reader, and the macOS cases through
    /// the IOKit-shaped read with the harness reading the scripted `ioreg` output in its place.
    /// The Windows cases pin `reg.exe` output parsing; this SDK has no Windows reader.
    @Test func machineIds() async throws {
        var counts: [String: Int] = [:]
        for vector in try group("machineIds") {
            let script = try #require(vector["source"])
            let platform = try #require(script["platform"]?.stringValue)
            counts[platform, default: 0] += 1
            guard platform == "linux" || platform == "darwin" else { continue }
            let source = platform == "linux" ? try linuxSource(script) : try macSource(script)
            // On a clock that does not move: a scripted read answers, however long it is held up.
            let reading = await readMachineId(source, timeout: 2, on: ManualTicker())
            #expect(reading.json == vector["expect"], "\(vector.name)")
        }
        #expect(counts == ["linux": 26, "darwin": 5, "win32": 9])
    }

    /// What an ask's answer saves and says (`renewalOutcome`, which `renew` calls): the check given
    /// is the one made, and the lease is never verified (it is `header.payload.signature`).
    @Test func renewals() throws {
        let vectors = try group("renewals")
        for vector in vectors {
            let input = RenewalInput(
                response: try response(vector["response"]),
                check: try check(vector["check"]),
                askedAt: try vector.int("askedAt"),
                now: try vector.int("now"),
                major: try vector.int("major"),
                key: vector["key"]?.stringValue,
                keptMajor: vector["keptMajor"]?.intValue,
                device: deviceOf(
                    kind: vector["device"]?["kind"]?.stringValue.flatMap(DeviceKind.init(rawValue:)),
                    ownClaim: vector["device"]?["ownClaim"]?.stringValue
                )
            )
            #expect(renewalOutcome(input).json == vector["expect"], "\(vector.name)")
        }
        #expect(vectors.count == 118)
    }

    /// The status a stored licence lease gives with no verdict from the server (`leaseStatus` of
    /// `checkLease`, which `status()` and a renewal answer with), entitlements included.
    @Test func leaseStatuses() throws {
        let key = try publicKeyBytes(fromJWK: try #require(Self.file?["publicJwk"]).jsonText)
        for vector in try group("leaseStatuses") {
            let holder = LeaseHolder(
                key: try vector.string("holder", "key"),
                activationId: try vector.string("holder", "activationId"),
                claims: try #require(vector["holder"]?["claims"]?.arrayValue).compactMap(\.stringValue),
                canTell: try vector.bool("holder", "canTell")
            )
            let verified = verifyLease(try vector.string("token"), publicKey: key, now: try vector.int("now"))
            let check = checkLease(verified, product: try vector.string("product"), major: try vector.int("major"), holder: holder)
            #expect(leaseStatus(check, key: holder.key).json == vector["expect"], "\(vector.name)")
        }
    }

    /// A trial's status from its start and its trial lease (`trialStatusOf` of `trialLeaseOf`,
    /// which a trial's `status()` and `startTrial()` answer with), entitlements included: the
    /// stored state is the trial start and the trial lease, and nothing else.
    @Test func trialLeaseStatuses() throws {
        let key = try publicKeyBytes(fromJWK: try #require(Self.file?["publicJwk"]).jsonText)
        for vector in try group("trialLeaseStatuses") {
            let token = try vector.string("token")
            let now = try vector.int("now")
            let lease = trialLeaseOf(
                verifyLease(token, publicKey: key, now: now),
                product: try vector.string("product"),
                claims: try #require(vector["device"]?["claims"]?.arrayValue).compactMap(\.stringValue),
                canTell: try vector.bool("device", "canTell")
            )
            let state = StoredState(trialStart: try vector.int("trialStart"), trialLease: token)
            let status = trialStatusOf(
                state, now: now, leaseValid: lease.valid, leaseEndsAt: lease.endsAt, leaseEntitlements: lease.entitlements
            )
            #expect(status.json == vector["expect"], "\(vector.name)")
        }
    }

    /// The bits of the double an entitlement reads from a number as the server writes it
    /// (`entitlementsOf` of `{"n": json}`, read as a lease's payload is read): a string no JSON
    /// reader can round, so a reader that rounds wrongly fails here, though it reads this file and
    /// a lease alike.
    @Test func entitlementNumbers() throws {
        for vector in try group("entitlementNumbers") {
            let json = try vector.string("json")
            let read = entitlementsOf(JSONText.parse(decoding: Data("{\"n\":\(json)}".utf8)))
            let number = try #require(read["n"]?.numberValue, "\(vector.name): \(json) is not a number")
            #expect(.string(doubleBits(number)) == vector["expect"], "\(vector.name)")
        }
    }

    /// Whether `status()` asks on a valid lease (`asksOnValidLease`, which `status()` calls).
    @Test func validLeaseAsks() throws {
        for vector in try group("validLeaseAsks") {
            var claims = baseClaims
            claims.major = try #require(vector["claims"]?["major"]?.numberValue)
            claims.iat = try #require(vector["claims"]?["iat"]?.numberValue)
            claims.exp = try #require(vector["claims"]?["exp"]?.numberValue)
            let asks = asksOnValidLease(
                claims: claims,
                state: StoredState(json: try #require(vector["state"])),
                major: try vector.int("major"),
                now: try vector.int("now"),
                clockNow: try vector.int("clockNow")
            )
            #expect(.bool(asks) == vector["expect"], "\(vector.name)")
        }
    }

    /// Who the device is from what its fingerprinter said (`deviceFrom`, which the reader calls).
    @Test func devices() throws {
        for vector in try group("devices") {
            let identity = try #require(vector["identity"])
            let device = deviceFrom(
                DeviceIdentity(
                    fingerprint: identity["fingerprint"]?.stringValue,
                    kind: identity["kind"]?.stringValue.flatMap(DeviceKind.init(rawValue:)),
                    alternates: (identity["alternates"]?.arrayValue ?? []).compactMap(\.stringValue)
                ),
                installKind: vector["installKind"]?.stringValue.flatMap(DeviceKind.init(rawValue:)),
                deviceHold: try vector.bool("deviceHold")
            )
            #expect(device.json == vector["expect"], "\(vector.name)")
        }
    }

    /// What the default fingerprinter says from a reading of the machine id (`identityOf`, which
    /// `DefaultFingerprinter.identify` calls).
    @Test func identities() throws {
        for vector in try group("identities") {
            let reading: MachineIdReading
            switch vector["reading"]?["kind"]?.stringValue {
            case "id": reading = .id(try #require(vector["reading"]?["id"]?.stringValue))
            case "unavailable": reading = .unavailable
            default: reading = .transient
            }
            var host: HostNames?
            if let names = vector["host"], !names.isNull {
                host = HostNames(
                    host: try #require(names["host"]?.stringValue),
                    platform: try #require(names["platform"]?.stringValue),
                    arch: try #require(names["arch"]?.stringValue)
                )
            }
            #expect(identityOf(reading, host: host).json == vector["expect"], "\(vector.name)")
        }
    }

    /// The latest time seen a save writes (`savedLastSeen`, which `save` calls).
    @Test func savedLastSeen() throws {
        for vector in try group("savedLastSeen") {
            let saved = KeyGrant.savedLastSeen(
                stored: vector["stored"]?.intValue, clockNow: try vector.int("clockNow"), guard: vector["guard"]?.intValue
            )
            #expect(.number(Double(saved)) == vector["expect"], "\(vector.name)")
        }
    }

    /// A validate's answer as a vector gives it: nil for none at all, and a body of `null` for none.
    func response(_ json: LicenseJSON?) throws -> LicenseHTTPResponse? {
        guard let json, !json.isNull else { return nil }
        let body = json["json"].flatMap { $0.isNull ? nil : $0 }
        return LicenseHTTPResponse(status: try #require(json["status"]?.intValue), json: body)
    }

    /// The offline check of the lease a 200 carried, as a vector gives it (as `leases.expect`, with
    /// the claims when ok).
    func check(_ json: LicenseJSON?) throws -> LeaseCheck? {
        guard let json, !json.isNull else { return nil }
        if json["ok"] == true {
            let given = try #require(json["claims"])
            let claims = try #require(LeaseClaims(json: given), "the check's claims")
            return .ok(test: json["test"] == true, claims: claims)
        }
        return .refused(try #require(json["reason"]?.stringValue.flatMap(LeaseCheck.Reason.init(rawValue:))))
    }
}

// MARK: - reading vectors

/// A double's IEEE-754 bits, sign first, as 16 lowercase hex digits.
func doubleBits(_ value: Double) -> String {
    let hex = String(value.bitPattern, radix: 16)
    return String(repeating: "0", count: 16 - hex.count) + hex
}

/// What the decisions read of a lease's claims (the vectors' base claims).
let baseClaims = LeaseClaims(
    sub: KEY, product: PRODUCT, aid: "act_1", model: "perpetual", lim: 3, major: 3, iat: 1_789_913_600, exp: 1_792_505_600
)

struct VectorError: Error, CustomStringConvertible {
    var description: String
}

extension LicenseJSON {
    var name: String { self["name"]?.stringValue ?? "?" }

    func string(_ path: String...) throws -> String {
        var value: LicenseJSON? = self
        for key in path { value = value?[key] }
        guard let string = value?.stringValue else { throw VectorError(description: "\(name): no string at \(path)") }
        return string
    }

    func bool(_ path: String...) throws -> Bool {
        var value: LicenseJSON? = self
        for key in path { value = value?[key] }
        guard let bool = value?.boolValue else { throw VectorError(description: "\(name): no boolean at \(path)") }
        return bool
    }

    func int(_ key: String) throws -> Int {
        guard let int = self[key]?.intValue else { throw VectorError(description: "\(name): no number at \(key)") }
        return int
    }

    /// This value as JSON text.
    var jsonText: String {
        JSONText.text(self)
    }
}

extension VerifyResult {
    /// As the vectors say it: `{valid, reason?, claims?}`.
    var json: LicenseJSON {
        var members: [String: LicenseJSON] = ["valid": .bool(failure == nil)]
        if let failure { members["reason"] = .string(failure.rawValue) }
        if let claims { members["claims"] = claims.json }
        return .object(members)
    }
}

extension LeaseCheck {
    var json: LicenseJSON {
        switch self {
        case .ok(let test, _): ["ok": true, "test": .bool(test)]
        case .refused(let reason): ["ok": false, "reason": .string(reason.rawValue)]
        }
    }
}

extension RenewalOutcome {
    /// As the vectors say it: `{answered, status, patch}`, no status as `null`.
    var json: LicenseJSON {
        ["answered": .bool(answered), "status": status?.json ?? .null, "patch": patch.json]
    }
}

extension Device {
    /// As the reference's device reads in JSON: no fingerprint and no host name as `null`, no kind
    /// and no own claim left out.
    var json: LicenseJSON {
        var members: [String: LicenseJSON] = [
            "own": own.map(LicenseJSON.string) ?? .null,
            "canTell": .bool(canTell),
            "fingerprints": .array(fingerprints.map(LicenseJSON.string)),
            "claims": .array(claims.map(LicenseJSON.string)),
            "hostname": hostname.map(LicenseJSON.string) ?? .null,
        ]
        if let ownClaim { members["ownClaim"] = .string(ownClaim) }
        if let kind { members["kind"] = .string(kind.rawValue) }
        return .object(members)
    }
}

extension DeviceIdentity {
    /// As the reference's identity reads in JSON: no fingerprint as `null`, no kind left out.
    var json: LicenseJSON {
        var members: [String: LicenseJSON] = [
            "fingerprint": fingerprint.map(LicenseJSON.string) ?? .null,
            "alternates": .array(alternates.map(LicenseJSON.string)),
        ]
        if let kind { members["kind"] = .string(kind.rawValue) }
        return .object(members)
    }
}

/// A device as the decisions that take one read it: its own fingerprint (none when it cannot tell),
/// what that hashes, and its own claim.
func deviceOf(kind: DeviceKind?, ownClaim: String?, canTell: Bool = true, claims: [String]? = nil) -> Device {
    Device(
        own: canTell ? "fingerprint-own" : nil,
        kind: kind,
        canTell: canTell,
        fingerprints: canTell ? ["fingerprint-own"] : [],
        claims: claims ?? ownClaim.map { [$0] } ?? [],
        ownClaim: ownClaim,
        hostname: nil
    )
}

extension LicenseStatus {
    /// As the reference's status object reads in JSON: absent members left out, and the
    /// entitlements too when there are none, as `test` is when false.
    var json: LicenseJSON {
        var members: [String: LicenseJSON] = ["state": .string(state.rawValue)]
        if let reason { members["reason"] = .string(reason.rawValue) }
        if let key { members["key"] = .string(key) }
        if let trialDaysLeft { members["trialDaysLeft"] = .number(Double(trialDaysLeft)) }
        if let trialEndsAt { members["trialEndsAt"] = .number(Double(trialEndsAt)) }
        if isTest { members["test"] = true }
        if !entitlements.isEmpty { members["entitlements"] = .object(entitlements.mapValues(\.json)) }
        if isStalled { members["stalled"] = true }
        return .object(members)
    }
}

extension StatePatch {
    /// A patch from JSON: `null` clears the field, and a field it does not name is left alone.
    init(json: LicenseJSON) throws {
        self.init()
        for (name, value) in json.objectValue ?? [:] {
            guard let field = StateField(rawValue: name) else { throw VectorError(description: "no field \(name)") }
            if value.isNull {
                self[field] = .clear
            } else {
                guard let parsed = field.value(from: value) else { throw VectorError(description: "\(name): \(value)") }
                self[field] = .set(parsed)
            }
        }
    }

    /// The patch as JSON: a cleared field is `null`.
    var json: LicenseJSON {
        var members: [String: LicenseJSON] = [:]
        for (field, change) in changes {
            switch change {
            case .set(let value): members[field.rawValue] = value.json
            case .clear: members[field.rawValue] = .null
            }
        }
        return .object(members)
    }
}

extension Basis {
    init(json: LicenseJSON) throws {
        self.init()
        guard !json.isNull else { return }
        func asked(_ value: LicenseJSON?) throws -> Asked? {
            guard let value, !value.isNull else { return nil }
            guard let at = value["at"]?.intValue else { throw VectorError(description: "an ask with no at") }
            return Asked(at: at, activationId: value["activationId"]?.stringValue, seen: value["seen"]?.intValue)
        }
        answer = try asked(json["answer"])
        activation = try asked(json["activation"])
        if let about = json["about"], !about.isNull { self.about = About(activationId: about["activationId"]?.stringValue) }
        if let trial = json["trial"], !trial.isNull {
            guard let at = trial["at"]?.intValue else { throw VectorError(description: "a trial ask with no at") }
            self.trial = Stamp(at: at, seen: trial["seen"]?.intValue)
        }
        if let purchase = json["purchase"], !purchase.isNull {
            guard let token = purchase["token"]?.stringValue else { throw VectorError(description: "a purchase with no token") }
            self.purchase = PurchaseBasis(token: token, at: purchase["at"]?.intValue)
        }
    }
}

extension MachineIdReading {
    var json: LicenseJSON {
        switch self {
        case .id(let id): ["kind": "id", "id": .string(id)]
        case .unavailable: ["kind": "unavailable"]
        case .transient: ["kind": "transient"]
        }
    }
}

/// A Linux machine as a vector scripts it: each file's content or error (unlisted: ENOENT), and
/// when it was written.
func linuxSource(_ script: LicenseJSON) throws -> ScriptedMachineSource {
    var files: [String: ScriptedMachineSource.File] = [:]
    for (path, file) in script["files"]?.objectValue ?? [:] {
        if let error = file["error"] {
            files[path] = error["code"]?.stringValue.map { ScriptedMachineSource.File.failure($0) } ?? .odd
        } else {
            files[path] = .text(file["content"]?.stringValue ?? "", mtimeMs: file["mtimeMs"]?.numberValue)
        }
    }
    return ScriptedMachineSource(platform: "linux", files: files)
}

/// A Mac as a vector scripts `ioreg` for it, read the IOKit way: no `ioreg` is no platform expert;
/// its output, the `IOPlatformUUID` in it (or none); a command killed, or failing oddly, a read
/// that did not finish.
func macSource(_ script: LicenseJSON) throws -> ScriptedMachineSource {
    guard let ioreg = script["commands"]?["/usr/sbin/ioreg"] else { return mac(.value(nil)) }
    if let error = ioreg["error"] {
        if let code = error["code"]?.stringValue, error["signal"] == nil, error["killed"] == nil {
            return mac(.failure(StorageError(code: code, operation: "ioreg", path: "/usr/sbin/ioreg")))
        }
        return mac(.failure(ScriptedMachineSource.Odd()))
    }
    return mac(.value(platformUUID(inIoreg: ioreg["output"]?.stringValue ?? "")))
}

/// The value of `"IOPlatformUUID" = "..."` in `ioreg` output.
func platformUUID(inIoreg output: String) -> String? {
    guard let label = output.range(of: "\"IOPlatformUUID\"") else { return nil }
    let rest = output[label.upperBound...].drop { $0 == " " || $0 == "\t" }
    guard rest.first == "=" else { return nil }
    let value = rest.dropFirst().drop { $0 == " " || $0 == "\t" }
    guard value.first == "\"" else { return nil }
    let uuid = value.dropFirst().prefix { $0 != "\"" }
    return uuid.isEmpty ? nil : String(uuid)
}
