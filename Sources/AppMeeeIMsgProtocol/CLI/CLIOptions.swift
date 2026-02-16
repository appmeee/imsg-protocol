import Foundation

/// Lightweight CLI argument parser for option/flag extraction.
struct CLIOptions {
    private let argv: [String]

    init(argv: [String]) {
        self.argv = argv
    }

    /// Returns the value for `--name <value>`.
    func option(_ name: String) -> String? {
        let longFlag = "--\(name)"
        guard let index = argv.firstIndex(of: longFlag),
              argv.index(after: index) < argv.endIndex
        else { return nil }
        return argv[argv.index(after: index)]
    }

    /// Returns all values for `--name <val1> <val2> ...` up to the next `--` flag.
    func optionValues(_ name: String) -> [String] {
        let longFlag = "--\(name)"
        guard let index = argv.firstIndex(of: longFlag) else { return [] }
        var values: [String] = []
        var i = argv.index(after: index)
        while i < argv.endIndex && !argv[i].hasPrefix("--") {
            values.append(argv[i])
            i = argv.index(after: i)
        }
        return values
    }

    /// Returns the value as Int64 for `--name <value>`.
    func optionInt64(_ name: String) -> Int64? {
        guard let raw = option(name) else { return nil }
        return Int64(raw)
    }

    /// Returns the value as Int for `--name <value>`.
    func optionInt(_ name: String) -> Int? {
        guard let raw = option(name) else { return nil }
        return Int(raw)
    }

    /// Whether `--name` is present (boolean flag).
    func flag(_ name: String) -> Bool {
        argv.contains("--\(name)")
    }

    /// The JSON output flag.
    var jsonOutput: Bool { flag("json") }

    /// The verbose flag.
    var verbose: Bool { flag("verbose") }
}
