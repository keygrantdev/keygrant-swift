import Foundation
import Testing

@testable import KeyGrant

#if canImport(Glibc)
import Glibc
private let streamSocket = Int32(SOCK_STREAM.rawValue)
#elseif canImport(Darwin)
import Darwin
private let streamSocket = SOCK_STREAM
#endif

/// The default HTTP adapter against a real HTTP server on the loopback interface.
@Suite("URLSessionHTTP", .serialized, suiteTimeLimit)
struct URLSessionHTTPTests {
    @Test func postsJSONAndAnswersTheStatusAndTheParsedBody() async throws {
        let server = try LocalServer { _ in response(200, #"{"lease":"a.b.c","activationId":"act_1"}"#) }
        defer { server.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/v1/products/sluice/validate"))
        let answer = try await URLSessionHTTP().post(url, body: ["key": "K", "major": 1], timeout: 5)
        #expect(answer == LicenseHTTPResponse(status: 200, json: ["lease": "a.b.c", "activationId": "act_1"]))
        let request = try #require(server.requests.first)
        #expect(request.hasPrefix("POST /v1/products/sluice/validate HTTP/1.1"))
        #expect(request.lowercased().range(of: "content-type: application/json") != nil)
        #expect(request.hasSuffix(#"{"key":"K","major":1}"#))
    }

    @Test func answersA4xxAnd5xxAsAResponseAndABodyThatIsNotJSONAsNone() async throws {
        let server = try LocalServer { request in
            request.range(of: "/activate") != nil ? response(403, #"{"error":"revoked"}"#) : response(503, "<html>down</html>", type: "text/html")
        }
        defer { server.stop() }
        let http = URLSessionHTTP()
        let refused = try await http.post(try #require(URL(string: "http://127.0.0.1:\(server.port)/activate")), body: [:], timeout: 5)
        #expect(refused == LicenseHTTPResponse(status: 403, json: ["error": "revoked"]))
        let down = try await http.post(try #require(URL(string: "http://127.0.0.1:\(server.port)/validate")), body: [:], timeout: 5)
        #expect(down == LicenseHTTPResponse(status: 503, json: nil))
    }

    @Test func throwsForACallThatOutlivesItsBound() async throws {
        // A server that takes the connection and never answers (a captive portal, a dead proxy).
        let server = try LocalServer { _ in nil }
        defer { server.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/validate"))
        let started = Date()
        await #expect(throws: (any Error).self) { _ = try await URLSessionHTTP().post(url, body: [:], timeout: 0.5) }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func throwsWhenNothingIsListening() async throws {
        let server = try LocalServer { _ in nil }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/validate"))
        server.stop()
        await #expect(throws: (any Error).self) { _ = try await URLSessionHTTP().post(url, body: [:], timeout: 2) }
    }
}

private func response(_ status: Int, _ body: String, type: String = "application/json") -> String {
    "HTTP/1.1 \(status) X\r\nContent-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
}

/// A one-thread HTTP server on 127.0.0.1: each request is answered as `respond` says, or held
/// open unanswered when it says nil.
final class LocalServer: Sendable {
    struct Failure: Error {}

    let port: UInt16
    private let listener: Int32
    private let received = Locked<[String]>([])

    var requests: [String] { received.current }

    init(_ respond: @escaping @Sendable (String) -> String?) throws {
        let fd = socket(AF_INET, streamSocket, 0)
        guard fd >= 0 else { throw Failure() }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            _ = close(fd)
            throw Failure()
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
        listener = fd
        let received = self.received
        Thread.detachNewThread {
            var open: [Int32] = []
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { break }
                let request = readRequest(client)
                received.withValue { $0.append(request) }
                guard let answer = respond(request) else {
                    open.append(client)
                    continue
                }
                let bytes = Array(answer.utf8)
                var sent = 0
                while sent < bytes.count {
                    let count = bytes[sent...].withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
                    if count <= 0 { break }
                    sent += count
                }
                _ = close(client)
            }
            for client in open { _ = close(client) }
        }
    }

    func stop() {
        _ = shutdown(listener, 2)
        _ = close(listener)
    }
}

/// One request's text: its head, and as much body as its Content-Length says.
private func readRequest(_ client: Int32) -> String {
    var bytes: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = chunk.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
        if count <= 0 { break }
        bytes += chunk[0..<count]
        let text = String(decoding: bytes, as: UTF8.self)
        guard let head = text.range(of: "\r\n\r\n") else { continue }
        let headers = text[..<head.lowerBound].lowercased()
        let length = headers.components(separatedBy: "\r\n").first { $0.hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        if text.utf8.count - text[..<head.upperBound].utf8.count >= length { return text }
    }
    return String(decoding: bytes, as: UTF8.self)
}
