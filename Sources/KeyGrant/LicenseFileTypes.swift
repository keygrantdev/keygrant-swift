import Foundation

/// A licence file's extension, for both kinds: `.kglicense`. In an open panel or a drop handler,
/// `UTType(filenameExtension: "kglicense")`.
public let licenseFileExtension = ".kglicense"

/// The media type of a licence file attached to an email: a vendor type, so a mail client hands it
/// over byte for byte.
public let licenseFileMediaType = "application/vnd.keygrant.license"

/// The most a licence file may be, in bytes; a larger one is `.malformed`.
/// A real one is well under 2 KB.
public let maxLicenseFileBytes = 16_384

/// The kind of a licence file: one format, two kinds.
public enum LicenseFileKind: String, Sendable, Hashable, CaseIterable {
    /// A key file: it carries the licence key, which the app activates online exactly as a typed
    /// key (seats, revocation and refunds as usual). Only the delivery differs.
    case key
    /// An offline licence file: a lease that never expires and is bound to no device, for machines
    /// that never go online. It has no seat limit and cannot be revoked: a leaked file works until an
    /// app update lists its id (`LicenseConfig.revokedLicenseFiles`).
    case offline
}

/// Why a licence file was not taken (`License.importLicenseFile(_:)`).
public enum LicenseFileError: String, Error, Sendable, Hashable, CaseIterable {
    /// Not a licence file's text, or its token or claims are broken.
    case malformed
    /// A signed token, but not a licence file (a lease, say).
    case notALicenseFile = "not-a-license-file"
    /// Not signed by the key it names.
    case badSignature = "bad-signature"
    /// Signed by a key this build does not carry (`LicenseConfig.publicJWK`): a newer one, after the
    /// product rotated its key, which an update of the app carries.
    case unknownKey = "unknown-key"
    /// Another product's file.
    case wrongProduct = "wrong-product"
    /// Its id is one this build lists as revoked (`LicenseConfig.revokedLicenseFiles`).
    case revokedFile = "revoked-file"
    /// An offline file for older versions than this build.
    case upgrade
    /// An offline file for later versions than this build: update the app.
    case outdated
}

/// What a status rests on, when it is not a key's lease or a trial.
public enum LicenseSource: String, Sendable, Hashable, CaseIterable {
    /// A stored offline licence file. It holds no seat: offer to remove the file
    /// (`License.removeLicenseFile()`) rather than deactivating.
    case file
}

/// Who a licence file is licensed to, as it signs it: a name, an email address, or both. Show it:
/// "Licensed to Ada Lovelace".
public struct LicensedTo: Sendable, Hashable {
    public var name: String?
    public var email: String?

    public init(name: String? = nil, email: String? = nil) {
        self.name = name
        self.email = email
    }
}

/// What `License.importLicenseFile(_:)` did.
public enum ImportLicenseFileResult: Sendable, Hashable {
    /// Taken: an offline file stored, or a key file's key activated.
    case imported(LicenseFileKind, licensedTo: LicensedTo)
    /// The file was refused, and nothing was stored.
    case refused(LicenseFileError)
    /// A key file's key did not activate: what `activate(_:)` answers.
    case notActivated(LicenseError)

    /// Whether the file was taken.
    public var isImported: Bool {
        if case .imported = self { return true }
        return false
    }
}
