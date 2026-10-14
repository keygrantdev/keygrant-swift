import Foundation
import Testing

@testable import KeyGrant

/// The licence-file types an app handles and what this port reads on its own: the strict UTF-8 check
/// a file's container is held to, the public words and constants, the import's answer, and the stored
/// field's name in the state file every SDK shares.
@Suite("licence-file types", suiteTimeLimit)
struct LicenseFileTypesTests {
    /// A file whose note holds `bytes`, then the token on a line of its own.
    func file(note bytes: [UInt8], token: String) -> Data {
        Data(Array("# ".utf8) + bytes + Array("\n\(token)\n".utf8))
    }

    @Test func aContainerIsReadAsStrictUTF8EveryIllFormedSequenceRefused() {
        let token = Signer().offlineFile()
        let illFormed: [[UInt8]] = [
            // Overlong forms.
            [0xC0, 0x80], [0xC1, 0xBF], [0xE0, 0x80, 0x80], [0xE0, 0x9F, 0xBF], [0xF0, 0x80, 0x80, 0x80], [0xF0, 0x8F, 0xBF, 0xBF],
            // Surrogates.
            [0xED, 0xA0, 0x80], [0xED, 0xBF, 0xBF],
            // Past U+10FFFF, and leads no sequence starts with.
            [0xF4, 0x90, 0x80, 0x80], [0xF5, 0x80, 0x80, 0x80], [0xF8], [0xFF],
            // Cut short: mid-file, and before ASCII.
            [0xE2, 0x82, 0x0A], [0xF0, 0x9F, 0x98, 0x41],
            // A continuation byte that is not one.
            [0xE2, 0x82, 0x41], [0xF0, 0x9F, 0x41, 0x80],
        ]
        for bytes in illFormed {
            #expect(licenseFileToken(file(note: bytes, token: token)) == nil, "\(bytes)")
        }
        // Cut short at the very end of the file.
        #expect(licenseFileToken(Data(Array("\(token)\n# ".utf8) + [0xE2, 0x82])) == nil)
        // The control: each edge of each range is well formed, and the token is read.
        let wellFormed: [[UInt8]] = [
            [0xC2, 0x80], [0xDF, 0xBF], [0xE0, 0xA0, 0x80], [0xED, 0x9F, 0xBF], [0xEE, 0x80, 0x80], [0xEF, 0xBF, 0xBF],
            [0xF0, 0x90, 0x80, 0x80], [0xF1, 0x80, 0x80, 0x80], [0xF3, 0xBF, 0xBF, 0xBF], [0xF4, 0x8F, 0xBF, 0xBF],
        ]
        for bytes in wellFormed {
            #expect(licenseFileToken(file(note: bytes, token: token)) == token, "\(bytes)")
        }
    }

    @Test func theWordsAreTheReferences() {
        #expect(LicenseFileError.allCases.map(\.rawValue) == [
            "malformed", "not-a-license-file", "bad-signature", "unknown-key", "wrong-product", "revoked-file", "upgrade", "outdated",
        ])
        #expect(LicenseFileKind.allCases.map(\.rawValue) == ["key", "offline"])
        #expect(LicenseSource.allCases.map(\.rawValue) == ["file"])
    }

    @Test func theExtensionAndMediaTypeAreTheContracts() {
        #expect(licenseFileExtension == ".kglicense")
        #expect(licenseFileMediaType == "application/vnd.keygrant.license")
    }

    @Test func onlyAFileTakenIsImported() {
        #expect(ImportLicenseFileResult.imported(.offline, licensedTo: ada).isImported)
        #expect(!ImportLicenseFileResult.refused(.malformed).isImported)
        #expect(!ImportLicenseFileResult.notActivated(.network).isImported)
    }

    @Test func theStoredFileIsLicenseFileInTheStateFileWrittenAndReadByThatName() async throws {
        let token = Signer().offlineFile()
        let fs = MemoryFileSystem()
        try await storage(fs).write(StoredState(licenseFile: token))
        let saved = try #require(fs.files[statePath])
        #expect(JSONText.parse(saved)?["licenseFile"] == .string(token))
        #expect(try await storage(fs).read(readOnly: true)?.licenseFile == token)
    }
}
