import Foundation

/// File sizes written the same way everywhere, so "19.0 MB, was 61.5 MB" reads as a pair.
/// Decimal units (1 MB = 1,000,000 bytes), like the platforms' limits in presets.json.
/// Always rounded down, so a file under a 20 MB limit never shows as "20.1 MB".
public enum SizeFormat {
    public static func string(_ bytes: Int64, locale: Locale = .current) -> String {
        let value = Double(max(bytes, 0))
        if value < 1_000_000 {
            return "\(whole(value / 1_000, locale)) KB"
        }
        if value < 1_000_000_000 {
            return "\(oneDecimal(value / 1_000_000, locale)) MB"
        }
        return "\(oneDecimal(value / 1_000_000_000, locale)) GB"
    }

    private static func whole(_ value: Double, _ locale: Locale) -> String {
        value.formatted(.number.precision(.fractionLength(0)).rounded(rule: .down).locale(locale))
    }

    private static func oneDecimal(_ value: Double, _ locale: Locale) -> String {
        value.formatted(.number.precision(.fractionLength(1)).rounded(rule: .down).grouping(.never).locale(locale))
    }
}
