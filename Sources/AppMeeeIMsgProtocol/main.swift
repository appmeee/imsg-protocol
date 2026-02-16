import AppMeeeIMsgCore
import Foundation

let dbPath: String
if CommandLine.arguments.count > 1 {
    dbPath = CommandLine.arguments[1]
} else {
    dbPath = MessageStore.defaultPath
}

let store: MessageStore
do {
    store = try MessageStore(path: dbPath)
} catch {
    let errorResponse: [String: Any] = [
        "jsonrpc": "2.0",
        "id": NSNull(),
        "error": [
            "code": -32603,
            "message": "Failed to open chat.db: \(error.localizedDescription)",
        ] as [String: Any],
    ]
    StdoutWriter.writeJSON(errorResponse)
    exit(1)
}

let server = RPCServer(store: store)
await server.run()
