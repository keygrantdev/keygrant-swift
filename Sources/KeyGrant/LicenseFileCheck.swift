import Foundation

/// What a licence file says about this app, offline.
enum LicenseFileCheck: Sendable, Hashable {
    /// It may be taken: an offline file that covers this build, or a key file.
    case taken(LicenseFileClaims)
    /// Refused; the claims when the signature held, so a status can still say whose file it is.
    case refused(LicenseFileError, LicenseFileClaims?)
}

/// A verified licence file held to this product, this build's major and the app's denylist, in this
/// order: not valid (`unknownKey`, `badSignature` and `notALicenseFile` as they are; bad claims and
/// `malformed` as `malformed`); another product (`wrongProduct`); its id in `revoked`, matched unit
/// for unit (`revokedFile`); for an offline file, the major below `minMajor` (absent: 1, `outdated`)
/// or above `major` (`upgrade`). A key file covers what its key does, which only the server can say,
/// so no version is judged.
func checkLicenseFile(_ verified: FileVerifyResult, product: String, major: Int, revoked: [String]) -> LicenseFileCheck {
    let claims: LicenseFileClaims
    switch verified {
    case .valid(let valid): claims = valid
    case .invalid(.unknownKey): return .refused(.unknownKey, nil)
    case .invalid(.badSignature): return .refused(.badSignature, nil)
    case .invalid(.notALicenseFile): return .refused(.notALicenseFile, nil)
    case .invalid: return .refused(.malformed, nil)
    }
    if !sameText(claims.product, product) { return .refused(.wrongProduct, claims) }
    if revoked.contains(where: { sameText($0, claims.fid) }) { return .refused(.revokedFile, claims) }
    if claims.kind == .offline {
        if Double(major) < (claims.minMajor ?? 1) { return .refused(.outdated, claims) }
        if Double(major) > claims.major { return .refused(.upgrade, claims) }
    }
    return .taken(claims)
}

extension LicenseFileClaims {
    /// Who the file is licensed to, as it signs it.
    var licensedTo: LicensedTo { LicensedTo(name: name, email: email) }
}

/// The status a STORED offline licence file gives, every one with `source` `.file`: licensed, with
/// its key, who it is licensed to, `isTest` when it says so and its entitlements; `.invalid` with
/// `.revokedFile`, `.upgrade` or `.outdated`, its key and licensee, but no entitlements;
/// `.invalid`/`.unknownKey` when the build does not carry its key (nothing of it read); and
/// `.invalid`/`.tampered` for anything else, a key file included (one is never stored: the state
/// was edited).
func licenseFileStatus(_ check: LicenseFileCheck) -> LicenseStatus {
    switch check {
    case .taken(let claims) where claims.kind == .offline:
        LicenseStatus(
            state: .licensed, key: claims.sub, isTest: claims.test == true, entitlements: claims.ent,
            source: .file, licensedTo: claims.licensedTo
        )
    case .refused(let error, let claims?) where LicenseReason(storedFile: error) != nil:
        LicenseStatus(
            state: .invalid, reason: LicenseReason(storedFile: error), key: claims.sub, source: .file,
            licensedTo: claims.licensedTo
        )
    case .refused(.unknownKey, _): LicenseStatus(state: .invalid, reason: .unknownKey, source: .file)
    default: LicenseStatus(state: .invalid, reason: .tampered, source: .file)
    }
}

extension LicenseReason {
    /// The reason a stored file whose signature held gives when it does not license this build:
    /// revoked by this build, or a range of versions that leaves it out; nil for any other refusal.
    init?(storedFile error: LicenseFileError) {
        switch error {
        case .revokedFile: self = .revokedFile
        case .upgrade: self = .upgrade
        case .outdated: self = .outdated
        case .malformed, .notALicenseFile, .badSignature, .unknownKey, .wrongProduct: return nil
        }
    }
}
