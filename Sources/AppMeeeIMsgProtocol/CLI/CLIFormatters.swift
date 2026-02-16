import AppMeeeIMsgCore
import Foundation

enum CLIFormatter {
    private nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func formatDate(_ date: Date) -> String {
        iso8601.string(from: date)
    }

    static func displayName(for meta: AttachmentMeta) -> String {
        if !meta.transferName.isEmpty { return meta.transferName }
        if !meta.filename.isEmpty { return meta.filename }
        return "(unknown)"
    }

    static func pluralSuffix(for count: Int) -> String {
        count == 1 ? "" : "s"
    }

    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    static func writeJSONLine<T: Encodable>(_ value: T) throws {
        let data = try jsonEncoder.encode(value)
        guard let line = String(data: data, encoding: .utf8), !line.isEmpty else { return }
        StdoutWriter.writeLine(line)
    }
}

enum DurationParser {
    static func parse(_ value: String) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let units: [(suffix: String, multiplier: Double)] = [
            ("ms", 0.001),
            ("s", 1),
            ("m", 60),
            ("h", 3600),
        ]
        for unit in units {
            if trimmed.hasSuffix(unit.suffix) {
                let number = String(trimmed.dropLast(unit.suffix.count))
                if let value = Double(number) {
                    return value * unit.multiplier
                }
                return nil
            }
        }
        if let value = Double(trimmed) {
            return value
        }
        return nil
    }
}
