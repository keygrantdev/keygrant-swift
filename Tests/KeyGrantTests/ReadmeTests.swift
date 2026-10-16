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
        #expect(forced.first?.heading == "## Embedding the public keys")
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
        let working = setUp(#"{"keys":["# + Signer().publicJWK + "]}")
        #expect(working.license != nil && working.configError == nil)
        // The placeholder the README shows is not a key: the error says so.
        let placeholder = setUp(#"{"keys":[{"kty":"OKP","crv":"Ed25519","x":"<the x of your product's key>"}]}"#)
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

    /// The Buying from the app example: the Buy button opens the payment link as it is (no reference
    /// of this install's on it), and the customer then enters the key the checkout emailed.
    @Test func buysThroughThePlainLinkAsTheBuyingSectionShows() throws {
        let example = try #require(try swiftBlocks().first { $0.heading == "## Buying from the app" })
        #expect(example.code.contains("NSWorkspace.shared.open(paymentLink)"))
        #expect(example.code.contains("(`activate(_:)`)"))
        #expect(!example.code.contains("client_reference_id"))
    }

    /// The Metered uses example, as it is written there: the spend, its refusals told apart by the error,
    /// and the meters of a status.
    @Test func spendsAsTheMeteredUsesSectionShows() async throws {
        let example = try #require(try swiftBlocks().first { $0.heading == "## Metered uses: counting what a key may do" })
        #expect(example.code.contains(#"let spent = await license.use("exports")"#))
        #expect(example.code.contains("case .usedUp?:") && example.code.contains("case .offlineLimit?:"))
        #expect(example.code.contains(#"status.meters["exports"]"#))
        func told(_ spent: UseResult) -> String {
            if spent.ok { return "run \(spent.left ?? -1)" }
            switch spent.error {
            case .usedUp?: return "more \(spent.left.map(String.init) ?? "nil")"
            case .offlineLimit?: return "connect"
            default: return "problem \(spent.error?.rawValue ?? "")"
            }
        }
        let h = try Harness.holding()
        h.http.on("use") { _ in Harness.spent(89, at: NOW) }
        #expect(told(await h.license.use("exports")) == "run 89")
        h.http.on("use", status: 409, json: ["error": "used-up", "left": 1])
        #expect(told(await h.license.use("exports", 5)) == "more 1")
        h.http.setFail(true)
        h.clock.set(NOW + 2 * MINUTE)
        #expect(told(await h.license.use("renders")) == "connect")
        #expect(told(await h.license.use("credits")) == "problem no-meter")
        #expect(await h.license.status().meters["exports"]?.total == 100)
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
