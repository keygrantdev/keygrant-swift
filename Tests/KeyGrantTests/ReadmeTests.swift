import Foundation
import Testing

@testable import KeyGrant

/// The README's examples, held to what they say.
@Suite("the README", suiteTimeLimit)
struct ReadmeTests {
    static let readme: String? = {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try? String(contentsOf: folder.appendingPathComponent("README.md"), encoding: .utf8)
    }()

    /// The README's Swift code blocks, each with the `##` heading it is under.
    func swiftBlocks() throws -> [(heading: String, code: String)] {
        let readme = try #require(Self.readme, "README.md beside Package.swift")
        var blocks: [(heading: String, code: String)] = []
        var heading = ""
        var code: [Substring]?
        // By any line break: in a checkout with CRLF line ends (Windows, core.autocrlf) "\r\n" is
        // one Character, which a split on "\n" alone never finds.
        for line in readme.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if var open = code {
                if line == "```" {
                    blocks.append((heading, open.joined(separator: "\n")))
                    code = nil
                } else {
                    open.append(line)
                    code = open
                }
            } else if line == "```swift" {
                code = []
            } else if line.hasPrefix("## ") {
                heading = String(line)
            }
        }
        return blocks
    }

    @Test func handlesTheConfigErrorInTheQuickStartAndForcesTheInitOnlyWhereTheKeyIsALiteral() throws {
        let blocks = try swiftBlocks()
        let quickStart = try #require(blocks.first { $0.heading == "## Quick start (SwiftUI)" })
        #expect(quickStart.code.contains("catch let error as LicenseConfigError"))
        #expect(!quickStart.code.contains("try!"))
        let forced = blocks.filter { $0.code.contains("try!") }
        #expect(forced.count == 1)
        #expect(forced.first?.heading == "## Embedding the public key")
        #expect(forced.first?.code.contains("literal in the source") == true)
    }

    /// The quick start's set-up, as it is written there: a `License` for a key it can use, and the
    /// error it shows for one it cannot.
    @Test func runsTheQuickStartsSetUp() {
        func setUp(_ productKey: String) -> (license: License?, configError: LicenseConfigError?) {
            let license: License?
            var configError: LicenseConfigError?
            do {
                license = try License(LicenseConfig(
                    product: "sluice",
                    apiBaseURL: URL(string: "https://api.keygrant.dev")!,
                    publicJWK: productKey,
                    major: 3
                ))
            } catch let error as LicenseConfigError {
                license = nil
                configError = error
            } catch {
                license = nil
            }
            return (license, configError)
        }
        let working = setUp(Signer().publicJWK)
        #expect(working.license != nil && working.configError == nil)
        // The placeholder the README shows is not a key: the error says so.
        let placeholder = setUp(#"{"kty":"OKP","crv":"Ed25519","x":"<the x of your product's key>"}"#)
        #expect(placeholder.license == nil)
        #expect(placeholder.configError == .invalidPublicKey("x is not 32 bytes of base64url"))
    }

    /// The Entitlements example, as it is written there, on a status from a lease that grants them
    /// and on one from a lease that grants none.
    @Test func readsEntitlementsAsTheEntitlementsSectionShows() throws {
        let example = try #require(try swiftBlocks().first { $0.heading == "## Entitlements" })
        #expect(example.code.contains(#"let isPro = status.entitlements["edition"] == .string("pro")"#))
        #expect(example.code.contains(#"let seats = status.entitlements["seats"]?.numberValue ?? 1"#))
        func read(_ status: LicenseStatus) -> (isPro: Bool, seats: Double) {
            let isPro = status.entitlements["edition"] == .string("pro")
            let seats = status.entitlements["seats"]?.numberValue ?? 1
            return (isPro, seats)
        }
        let pro = read(LicenseStatus(state: .licensed, key: KEY, entitlements: ["edition": "pro", "seats": 5]))
        #expect(pro.isPro && pro.seats == 5)
        let base = read(LicenseStatus(state: .licensed, key: KEY))
        #expect(!base.isPro && base.seats == 1)
    }
}

/// What the README says of this package's own suites.
@Suite("this package's suites", suiteTimeLimit)
struct SuiteTests {
    @Test func everySuiteHasTheTimeLimit() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".swift") }
        var suites = 0
        for file in files {
            let text = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("@Suite(") {
                suites += 1
                #expect(line.contains("suiteTimeLimit"), "\(file): \(line)")
            }
        }
        #expect(suites >= 40)
    }
}
