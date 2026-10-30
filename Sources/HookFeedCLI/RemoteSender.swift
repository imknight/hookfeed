import Foundation
import HookFeedCore

enum RemoteSender {
    static func send(_ draft: MessageDraft, base: String, token: String?, sleep: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)) throws -> SendReceipt {
        guard let token, !token.isEmpty, token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw HookFeedError.invalidInput(field: "HOOKFEED_TOKEN", reason: "set a bearer token when HOOKFEED_URL is set.")
        }
        guard let parts = URLComponents(string: base), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
              let url = parts.url else {
            throw HookFeedError.invalidInput(field: "HOOKFEED_URL", reason: "use an HTTP(S) base URL without a path, user info, query or fragment.")
        }
        var fields: [String: String] = ["title": draft.title, "source": draft.source, "kind": draft.kind.rawValue]
        fields["body"] = draft.body
        fields["project"] = draft.project
        fields["bot"] = draft.bot
        fields["url"] = draft.url
        fields["workdir"] = draft.workdir
        fields["session_id"] = draft.sessionID
        fields["thread_key"] = draft.threadKey
        fields["idempotency_key"] = draft.idempotencyKey ?? "retry:" + UUID().uuidString.lowercased()
        var request = URLRequest(url: url.appendingPathComponent("v1/messages"), timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(fields)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        let delays: [TimeInterval] = [0.5, 1, 2]
        var failure = "Remote send failed; check the address, token and whether HookFeed is open."
        for attempt in 0...3 {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw RemoteDeliveryError(failure) }
            request.timeoutInterval = remaining
            let result = DeliveryResult()
            let session = URLSession(configuration: configuration, delegate: result, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let task = session.dataTask(with: request)
            task.resume()
            guard result.done.wait(timeout: .now() + remaining) == .success else {
                task.cancel()
                throw RemoteDeliveryError("Remote send timed out after 5 seconds; message was not confirmed stored.")
            }
            var delay = attempt < delays.count ? delays[attempt] : 0
            if let response = result.response as? HTTPURLResponse, result.error == nil {
                if response.statusCode == 201 {
                    guard let receipt = try? JSONDecoder().decode(SendReceipt.self, from: result.data), receipt.status == "stored" else {
                        throw RemoteDeliveryError("Remote server returned an invalid storage receipt.")
                    }
                    return receipt
                }
                let detail = (try? JSONSerialization.jsonObject(with: result.data) as? [String: Any])?["error"] as? String
                failure = "Remote send failed (HTTP \(response.statusCode)); " + (detail ?? "message was not confirmed stored.")
                guard response.statusCode == 503 else { throw RemoteDeliveryError(failure) }
                if let header = response.value(forHTTPHeaderField: "Retry-After"), let seconds = TimeInterval(header), seconds.isFinite, seconds >= 0 {
                    delay = min(delay, seconds)
                }
            }
            guard attempt < 3, delay < deadline - ProcessInfo.processInfo.systemUptime else { throw RemoteDeliveryError(failure) }
            sleep(delay)
        }
        throw RemoteDeliveryError(failure)
    }

    private final class DeliveryResult: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var data = Data()
        var response: URLResponse?
        var error: Error?

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            self.response = response
            completionHandler(response.expectedContentLength > 64 * 1024 ? .cancel : .allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            guard chunk.count <= 64 * 1024 - data.count else { dataTask.cancel(); return }
            data.append(chunk)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            self.error = error
            done.signal()
        }
    }
}

private struct RemoteDeliveryError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
