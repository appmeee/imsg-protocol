import AppMeeeIMsgCore
import Foundation

enum AppVersion {
    static var current: String {
        ProcessInfo.processInfo.environment["IMSG_VERSION"] ?? "0.2.0"
    }
}

struct CommandRouter {
    let rootName = "appmeee-imsg-protocol"

    func run() async -> Int32 {
        await run(argv: Array(CommandLine.arguments.dropFirst()))
    }

    func run(argv: [String]) async -> Int32 {
        if argv.contains("--version") || argv.contains("-V") {
            StdoutWriter.writeLine(AppVersion.current)
            return 0
        }
        if argv.isEmpty || argv.first == "rpc" || argv.allSatisfy({ $0.hasPrefix("-") }) {
            return await runRPC(argv: argv)
        }
        if argv.contains("--help") || argv.contains("-h") {
            printHelp(for: argv)
            return 0
        }

        guard let command = argv.first else {
            printRootHelp()
            return 1
        }

        let remaining = Array(argv.dropFirst())
        if remaining.contains("--help") || remaining.contains("-h") {
            printCommandHelp(command)
            return 0
        }

        do {
            let options = CLIOptions(argv: remaining)
            switch command {
            case "chats":
                try await ChatsCommand.run(options: options)
            case "history":
                try await HistoryCommand.run(options: options)
            case "send":
                try await SendCommand.run(options: options)
            case "watch":
                try await WatchCommand.run(options: options)
            case "typing":
                try await TypingCommand.run(options: options)
            case "react":
                try await ReactCommand.run(options: options)
            default:
                StdoutWriter.writeLine("Unknown command: \(command)")
                printRootHelp()
                return 1
            }
            return 0
        } catch {
            StdoutWriter.writeLine("Error: \(error)")
            return 1
        }
    }

    private func runRPC(argv: [String]) async -> Int32 {
        let options = CLIOptions(argv: argv)
        let verbose = options.flag("verbose") || options.flag("v")
        let dbPath = options.option("db") ?? MessageStore.defaultPath

        let store: MessageStore
        do {
            store = try MessageStore(path: dbPath)
        } catch {
            StdoutWriter.writeJSON([
                "jsonrpc": "2.0",
                "id": NSNull(),
                "error": [
                    "code": -32603,
                    "message": "Failed to open chat.db: \(error.localizedDescription)",
                ] as [String: Any],
            ])
            return 1
        }

        let server = RPCServer(store: store, verbose: verbose)
        do {
            try await server.run()
        } catch {
            StdoutWriter.writeLine("RPC server error: \(error)")
            return 1
        }
        return 0
    }

    private func printHelp(for argv: [String]) {
        let commands = argv.filter { !$0.hasPrefix("-") }
        if let command = commands.first {
            printCommandHelp(command)
        } else {
            printRootHelp()
        }
    }

    private func printRootHelp() {
        let lines = [
            "\(rootName) \(AppVersion.current)",
            "Send and read iMessage / SMS from the terminal",
            "",
            "Usage:",
            "  \(rootName) <command> [options]",
            "",
            "Commands:",
            "  rpc      Run JSON-RPC over stdin/stdout (default)",
            "  chats    List recent conversations",
            "  history  Show recent messages for a chat",
            "  send     Send a message (text and/or attachment)",
            "  watch    Stream incoming messages",
            "  typing   Send typing indicator",
            "  react    Send a tapback reaction",
            "",
            "Global Options:",
            "  --db <path>  Path to chat.db (defaults to ~/Library/Messages/chat.db)",
            "  --json       Output as JSON lines",
            "  --verbose    Enable verbose logging",
            "",
            "Run '\(rootName) <command> --help' for details.",
        ]
        for line in lines { StdoutWriter.writeLine(line) }
    }

    private func printCommandHelp(_ command: String) {
        switch command {
        case "rpc":
            printLines([
                "\(rootName) rpc",
                "Run JSON-RPC over stdin/stdout",
                "",
                "Options:",
                "  --db <path>    Path to chat.db",
                "  --verbose      Enable verbose logging",
            ])
        case "chats":
            printLines([
                "\(rootName) chats",
                "List recent conversations",
                "",
                "Options:",
                "  --db <path>    Path to chat.db",
                "  --limit <n>    Number of chats to list (default: 20)",
                "  --json         Output as JSON lines",
            ])
        case "history":
            printLines([
                "\(rootName) history",
                "Show recent messages for a chat",
                "",
                "Options:",
                "  --db <path>            Path to chat.db",
                "  --chat-id <id>         Chat ROWID (required)",
                "  --limit <n>            Number of messages (default: 50)",
                "  --participants <list>  Filter by participant handles",
                "  --start <iso8601>      Start time (inclusive)",
                "  --end <iso8601>        End time (exclusive)",
                "  --attachments          Include attachment metadata",
                "  --json                 Output as JSON lines",
            ])
        case "send":
            printLines([
                "\(rootName) send",
                "Send a message (text and/or attachment)",
                "",
                "Options:",
                "  --db <path>              Path to chat.db",
                "  --to <phone/email>       Recipient",
                "  --chat-id <id>           Chat ROWID",
                "  --chat-identifier <id>   Chat identifier",
                "  --chat-guid <guid>       Chat GUID",
                "  --text <message>         Message body",
                "  --file <path>            Path to attachment",
                "  --service <name>         imessage|sms|auto (default: auto)",
                "  --region <code>          Phone region (default: US)",
                "  --json                   Output as JSON",
            ])
        case "watch":
            printLines([
                "\(rootName) watch",
                "Stream incoming messages",
                "",
                "Options:",
                "  --db <path>            Path to chat.db",
                "  --chat-id <id>         Limit to chat ROWID",
                "  --since-rowid <id>     Start after this ROWID",
                "  --participants <list>  Filter by participant handles",
                "  --start <iso8601>      Start time (inclusive)",
                "  --end <iso8601>        End time (exclusive)",
                "  --attachments          Include attachment metadata",
                "  --reactions            Include reaction events",
                "  --json                 Output as JSON lines",
            ])
        case "typing":
            printLines([
                "\(rootName) typing",
                "Send typing indicator",
                "",
                "Options:",
                "  --db <path>              Path to chat.db",
                "  --to <phone/email>       Recipient",
                "  --chat-id <id>           Chat ROWID",
                "  --chat-identifier <id>   Chat identifier",
                "  --chat-guid <guid>       Chat GUID",
                "  --service <name>         imessage|sms (default: imessage)",
                "  --stop                   Stop typing instead of starting",
                "  --duration <time>        Duration (e.g., 5s, 3000ms)",
            ])
        case "react":
            printLines([
                "\(rootName) react",
                "Send a tapback reaction to the most recent message",
                "",
                "Options:",
                "  --db <path>          Path to chat.db",
                "  --chat-id <id>       Chat ROWID (required)",
                "  --reaction <type>    love|like|dislike|laugh|emphasis|question or emoji (required)",
                "  --json               Output as JSON",
            ])
        default:
            printRootHelp()
        }
    }

    private func printLines(_ lines: [String]) {
        for line in lines { StdoutWriter.writeLine(line) }
    }
}
