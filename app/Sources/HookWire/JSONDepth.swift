import Foundation

/// How deeply JSON text nests arrays and objects, counted without parsing it. JSONSerialization
/// recurses once per level and overflows a dispatch queue's 512 KB stack a little past 400 levels (a
/// SIGBUS that kills the process, not an error), so JSON another program wrote is checked with this
/// before it is parsed: hook lines, transcript lines, registry records. The helper's stdin goes through
/// JSONScan instead, which counts the same way in the pass that looks for what two parsers read differently.
public enum JSONDepth {
    /// The deepest nesting the app parses from anything another program wrote.
    public static let limit = 128

    /// Whether no array or object in `data` nests deeper than `limit` levels. Brackets inside strings do
    /// not count (escapes honored). A zero byte fails it: UTF-8 JSON never holds one, and the UTF-16 and
    /// UTF-32 that JSONSerialization also reads always do, and could hide brackets from this count.
    public static func isWithin(_ data: Data, limit: Int = limit) -> Bool {
        data.withUnsafeBytes { raw in
            var depth = 0
            var isInString = false
            var isEscaped = false
            for byte in raw.bindMemory(to: UInt8.self) {
                if byte == 0 { return false }
                if isInString {
                    if isEscaped {
                        isEscaped = false
                    } else if byte == UInt8(ascii: "\\") {
                        isEscaped = true
                    } else if byte == UInt8(ascii: "\"") {
                        isInString = false
                    }
                    continue
                }
                switch byte {
                case UInt8(ascii: "\""):
                    isInString = true
                case UInt8(ascii: "["), UInt8(ascii: "{"):
                    depth += 1
                    if depth > limit { return false }
                case UInt8(ascii: "]"), UInt8(ascii: "}"):
                    if depth > 0 { depth -= 1 }
                default:
                    break
                }
            }
            return true
        }
    }

    /// `data` parsed, or nil when it nests deeper than `limit` or is not JSON.
    public static func parse(_ data: Data, limit: Int = limit) -> Any? {
        guard isWithin(data, limit: limit) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
