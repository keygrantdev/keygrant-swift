import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The default HTTP adapter: `URLSession` (an ephemeral session of its own: no cookies, no cache),
/// every call bounded by the timeout it is given. Abandoned, a call throws, which the SDK treats
/// as no network; a 4xx or 5xx is a response, its body parsed when it is JSON.
public final class URLSessionHTTP: HTTPAdapter {
    private let session: URLSession

    public convenience init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        self.init(configuration: configuration)
    }

    init(configuration: URLSessionConfiguration) {
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func post(_ url: URL, body: LicenseJSON, timeout: TimeInterval) async throws -> LicenseHTTPResponse {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: max(timeout, 0.001))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = JSONText.data(body)
        // A request's `timeoutInterval` is only the longest pause between packets (and Linux's
        // URLSession does not keep even that): the whole call is held to `timeout` here, the data
        // task cancelled at it.
        let session = self.session
        let bounded = request
        return try await withTimeout(timeout) { try await Self.send(bounded, on: session) }
    }

    private static func send(_ request: URLRequest, on session: URLSession) async throws -> LicenseHTTPResponse {
        let call = DataTaskHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LicenseHTTPResponse, Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let response = response as? HTTPURLResponse {
                        let json = data.flatMap { $0.isEmpty ? nil : JSONText.parse(decoding: $0) }
                        continuation.resume(returning: LicenseHTTPResponse(status: response.statusCode, json: json))
                    } else {
                        continuation.resume(throwing: NotHTTP())
                    }
                }
                call.start(task)
            }
        } onCancel: {
            call.cancel()
        }
    }
}

/// A response that was not HTTP.
private struct NotHTTP: Error {}

/// A data task, cancellable from the task awaiting it (the SDK's own bound cancels it at its end).
private final class DataTaskHandle: Sendable {
    private struct State: @unchecked Sendable {
        var task: URLSessionDataTask?
        var cancelled = false
    }

    private let state = Locked(State())

    func start(_ task: URLSessionDataTask) {
        let cancelled = state.withValue { state -> Bool in
            state.task = task
            return state.cancelled
        }
        task.resume()
        if cancelled { task.cancel() }
    }

    func cancel() {
        let task = state.withValue { state -> URLSessionDataTask? in
            state.cancelled = true
            return state.task
        }
        task?.cancel()
    }
}
