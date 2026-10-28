import Foundation
import NoodleCore
import Security

/// Retains the HTTP status across URLSession without exposing response contents.
struct MCPHTTPError: Error, CustomNSError, Sendable {
    let status: Int
    static var errorDomain: String { "Noodle.MCP.HTTP" }
    var errorCode: Int { status }
}

/// Supplies the SDK's HTTP transport with a no-redirect, bounded data loader.
/// In particular, bearer credentials must never follow a server redirect.
final class MCPGuardedHTTP: URLProtocol, URLSessionDataDelegate, @unchecked Sendable {
    private var session: URLSession?
    private var loadingTask: URLSessionDataTask?
    private var received = 0
    private var responseError: Error?
    private var eventStream = false
    private var sawBody = false
    private var heldResponse: HTTPURLResponse?
    // Per-instance configuration lets transport tests run without shared session state.
    var sessionConfiguration: () -> URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = []
        return configuration
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, Self.allowed(url) else {
            client?.urlProtocol(self, didFailWithError: MCPServiceError.invalidMetadata)
            return
        }
        let configuration = sessionConfiguration()
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        loadingTask = session.dataTask(with: request)
        loadingTask?.resume()
    }
    override func stopLoading() { loadingTask?.cancel(); session?.invalidateAndCancel() }

    private static func allowed(_ url: URL) -> Bool {
        (try? MCPConnectionRecord.validatedEndpoint(url)) != nil
            || (try? MCPConnectionRecord.validatedLoopbackEndpoint(url)) != nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let host = task.originalRequest?.url?.host,
              MCPConnectionRecord.isLoopbackName(host) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        var trustError: CFError?
        guard SecTrustEvaluateWithError(trust, &trustError) else {
            responseError = MCPServiceError.untrustedCertificate
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, !(300..<400).contains(response.statusCode),
              response.expectedContentLength <= 8 * 1_048_576 else {
            completionHandler(.cancel)
            return
        }
        guard (200..<300).contains(response.statusCode) else {
            responseError = MCPHTTPError(status: response.statusCode)
            completionHandler(.cancel)
            return
        }
        let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        eventStream = type.contains("text/event-stream")
        // Hold the response until the first body bytes are checked. A legacy
        // `event:` stream must fail before the client treats this as success.
        heldResponse = response
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received += data.count
        guard received <= 8 * 1_048_576 else {
            loadingTask?.cancel()
            return
        }
        if eventStream, !sawBody {
            sawBody = true
            let prefix = String(decoding: data.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if prefix.hasPrefix("event:") {
                responseError = MCPServiceError.legacyEventStream
                heldResponse = nil
                loadingTask?.cancel()
                return
            }
        }
        deliverHeldResponse()
        client?.urlProtocol(self, didLoad: data)
    }
    private func deliverHeldResponse() {
        if let heldResponse {
            client?.urlProtocol(self, didReceive: heldResponse, cacheStoragePolicy: .notAllowed)
            self.heldResponse = nil
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let responseError { client?.urlProtocol(self, didFailWithError: responseError) }
        else if let error { client?.urlProtocol(self, didFailWithError: error) }
        else {
            deliverHeldResponse()
            client?.urlProtocolDidFinishLoading(self)
        }
        session.finishTasksAndInvalidate()
        self.session = nil
        self.loadingTask = nil
    }
}
