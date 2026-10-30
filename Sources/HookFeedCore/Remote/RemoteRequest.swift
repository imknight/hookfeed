import Foundation
import MCP

public enum RemoteRequest {
    public static let bodyLimit = 64 * 1024

    public static func handle(method: String, path: String, headers: [String: String], body: Data,
                              connections: RemoteConnections, store: InboxStore, now: Date) -> (status: Int, json: Data) {
        guard body.count <= bodyLimit else { return failure(413, "Request body exceeds 64 KiB.") }
        if path == "/v1/health" {
            return method == "GET" ? (200, Data(#"{"ok":true}"#.utf8)) : failure(405, "Method not allowed.")
        }
        guard path == "/v1/messages" else { return failure(404, "Not found.") }
        guard method == "POST" else { return failure(405, "Method not allowed.") }
        let auth = headers.filter { $0.key.lowercased() == "authorization" }.map(\.value)
        guard auth.count == 1 else { return failure(401, "Bearer token required.") }
        let parts = auth[0].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].lowercased() == "bearer",
              let connection = connections.authenticate(bearer: String(parts[1])) else {
            return failure(401, "Invalid or revoked bearer token.")
        }
        let arguments: [String: Value]
        do { arguments = try JSONDecoder().decode([String: Value].self, from: body) }
        catch { return failure(400, "Expected a JSON object of send_message fields.") }
        do {
            let draft = try MCPTools.messageDraft(arguments, defaultSource: "remote")
            let receipt = try store.send(draft)
            connections.markUsed(id: connection.id, now: now)
            return (201, try JSONEncoder().encode(receipt))
        } catch let error as HookFeedError {
            switch error {
            case .invalidInput, .idempotencyConflict: return failure(400, error.localizedDescription)
            default: return failure(500, "Could not store message.")
            }
        } catch { return failure(500, "Could not store message.") }
    }

    public static func failure(_ status: Int, _ message: String) -> (status: Int, json: Data) {
        (status, try! JSONEncoder().encode(["error": message]))
    }
}
