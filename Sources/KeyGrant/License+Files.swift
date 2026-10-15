import Foundation

/// Licence files on a `License`: taking one an app was handed, removing it, and the status a stored
/// one gives. Never online: a key file's key is activated as a typed key is.
extension License {
    /// Take a licence file the customer was sent (`.kglicense`): its content, as a drop handler or
    /// an open panel reads it (`Data(contentsOf: url)`), never its path. Verified offline against the
    /// build's key set, for this product and, for an offline file, this build's major; refused when
    /// `LicenseConfig.revokedLicenseFiles` lists it (`.refused`, nothing stored). An OFFLINE file is
    /// then stored, replacing any stored before, and licenses the app with no network, ever:
    /// `status()` answers it with `source` `.file`. A KEY file's key is activated online exactly as
    /// `activate(_:)` would: `.imported(.key, licensedTo:)` once it is, `.notActivated` with what
    /// `activate(_:)` answers when it is not.
    ///
    /// Throws `LicenseCallError.previousCallUnfinished` behind a call that has not finished, and the
    /// storage's error when the state cannot be read or the file (or a key file's activation) cannot
    /// be saved: the customer asked, and can try again.
    ///
    /// `email` and `code` are what a person typed for a user-locked key, passed on to a key file's
    /// activation exactly as `activate(_:email:code:)` takes them. An offline file ignores them, and
    /// a file that is no licence file is refused before any key is asked for.
    public func importLicenseFile(_ content: Data, email: String? = nil, code: String? = nil) async throws -> ImportLicenseFileResult {
        try await calls.runThrowing { readOnly in
            if readOnly { throw LicenseCallError.previousCallUnfinished }
            return try await self.importNow(content, email: email, code: code)
        }
    }

    /// `importLicenseFile(_:email:code:)` for a file's content as text (pasted, say), read as its
    /// UTF-8 bytes.
    public func importLicenseFile(_ text: String, email: String? = nil, code: String? = nil) async throws -> ImportLicenseFileResult {
        try await importLicenseFile(Data(text.utf8), email: email, code: code)
    }

    /// Drop the stored offline licence file, if there is one; a key this device holds keeps working.
    /// `deactivate()` leaves a stored file alone: it releases the key's seat, and a file holds none.
    /// Throws as `importLicenseFile(_:)` does, behind a call that has not finished or when that
    /// cannot be saved.
    public func removeLicenseFile() async throws {
        try await calls.runThrowing { readOnly in
            if readOnly { throw LicenseCallError.previousCallUnfinished }
            // Based on nothing: it is about no activation, so it lands as it is.
            try await self.save([.licenseFile: .clear])
        }
    }

    private func importNow(_ content: Data, email: String?, code: String?) async throws -> ImportLicenseFileResult {
        guard let token = licenseFileToken(content) else { return .refused(.malformed) }
        switch checkFile(token) {
        case .refused(let error, _):
            return .refused(error)
        case .taken(let claims) where claims.kind == .key:
            let activated = try await activateNow(claims.sub, email: email, code: code)
            if let error = activated.error { return .notActivated(error) }
            return .imported(.key, licensedTo: claims.licensedTo)
        case .taken(let claims):
            try await save([.licenseFile: .string(token)])
            return .imported(.offline, licensedTo: claims.licensedTo)
        }
    }

    /// A licence file's token verified against the build's key set and judged for this app.
    func checkFile(_ token: String) -> LicenseFileCheck {
        checkLicenseFile(verifyLicenseFile(token, keys: keys), product: product, major: major, revoked: revokedFiles)
    }

    /// The status the stored offline licence file gives, verified again now, or nil when none is stored.
    func fileStatus(_ state: StoredState) -> LicenseStatus? {
        state.licenseFile.map { licenseFileStatus(checkFile($0)) }
    }
}
