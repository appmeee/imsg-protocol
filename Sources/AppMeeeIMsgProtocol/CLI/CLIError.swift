enum CLIError: Error, CustomStringConvertible {
    case missingOption(String)
    case invalidOption(String)

    var description: String {
        switch self {
        case .missingOption(let name):
            return "Missing required option: --\(name)"
        case .invalidOption(let name):
            return "Invalid value for option: --\(name)"
        }
    }
}
