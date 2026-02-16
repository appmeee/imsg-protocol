import Foundation
@preconcurrency import PhoneNumberKit

/// Normalizes phone number strings to E.164 format using PhoneNumberKit.
///
/// Marked `@unchecked Sendable` because `PhoneNumberUtility` is stateless
/// after initialization but does not declare `Sendable` conformance.
///
/// If the input cannot be parsed as a valid phone number for the given region,
/// the original string is returned unchanged.
public final class PhoneNumberNormalizer: @unchecked Sendable {
    private let phoneNumberUtility = PhoneNumberUtility()

    public init() {}

    /// Normalizes a phone number to E.164 format.
    ///
    /// - Parameters:
    ///   - input: The phone number string to normalize.
    ///   - region: The ISO 3166-1 alpha-2 region code (e.g., `"US"`).
    /// - Returns: The E.164 formatted number, or the original input if parsing fails.
    public func normalize(_ input: String, region: String) -> String {
        do {
            let number = try phoneNumberUtility.parse(input, withRegion: region, ignoreType: true)
            return phoneNumberUtility.format(number, toType: .e164)
        } catch {
            return input
        }
    }
}
