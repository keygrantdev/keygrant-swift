import Foundation
import Testing

@testable import KeyGrant

/// The user-lock groups of `conformance/vectors.json`, after the licence-file groups: what an
/// activation sends for the address and code a person typed (or the error that refuses them
/// first), and the error each word of a refused activation gives, answered from each vector's own
/// JSON with the conventions of the other groups (ConformanceTests.swift).
extension ConformanceTests {
    /// What is sent for what was typed, or why it is refused. An option that was not given is
    /// `null` in the file.
    @Test func whatWasTypedIsSentOrRefused() throws {
        for vector in try group("typedFor") {
            let answer: LicenseJSON
            switch typedFor(email: vector["email"]?.stringValue, code: vector["code"]?.stringValue) {
            case .send(let email, let code):
                var send: [String: LicenseJSON] = [:]
                if let email { send["email"] = .string(email) }
                if let code { send["code"] = .string(code) }
                answer = ["send": .object(send)]
            case .refused(let error):
                answer = ["refused": .string(error.rawValue)]
            }
            #expect(answer == vector["expect"], "\(vector["email"] ?? .null) \(vector["code"] ?? .null)")
        }
    }

    /// The words of a user lock are their own errors, and any other word, or none, is `network`.
    @Test func theWordsOfAUserLockAreTheirOwnErrors() throws {
        for vector in try group("userLockErrors") {
            let error = mapServerError(vector["error"]?.stringValue)
            #expect(.string(error.rawValue) == vector["expect"], "\(vector["error"] ?? .null)")
        }
    }
}
