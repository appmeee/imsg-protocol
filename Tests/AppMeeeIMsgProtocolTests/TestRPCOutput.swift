import Foundation

@testable import AppMeeeIMsgProtocol

final class TestRPCOutput: RPCOutput, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var responses: [[String: Any]] = []
    private(set) var errors: [[String: Any]] = []
    private(set) var notifications: [[String: Any]] = []

    func sendResponse(id: Any, result: Any) {
        record(&responses, value: ["jsonrpc": "2.0", "id": id, "result": result])
    }

    func sendError(id: Any?, error: RPCError) {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": error.toDictionary(),
        ]
        record(&errors, value: payload)
    }

    func sendNotification(method: String, params: Any) {
        record(&notifications, value: ["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func record(_ bucket: inout [[String: Any]], value: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        bucket.append(value)
    }
}
