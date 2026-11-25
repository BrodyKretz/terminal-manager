import Foundation

/// What one pass over a hook's raw JSON finds, besides how deep it nests: text that JSONSerialization and
/// Claude Code (which writes hook input with JSON.stringify and holds it as JavaScript values) may read as
/// different values. A card must show exactly what Claude Code will run, so such a request is never held.
/// Measured on this Mac: JSONSerialization keeps the first of two equal keys where JavaScript keeps the
/// last, and a Swift dictionary merges keys that are only canonically equal ("K" and U+212A KELVIN SIGN,
/// "é" and "e" plus U+0301) where both of the others keep two; it refuses a lone surrogate escape outright,
/// keeps a \u0000 inside a string, and reads integers past 2^53 and long decimals exactly (Int64,
/// NSDecimalNumber) where JavaScript rounds them to a double.
public struct JSONScan: Equatable, Sendable {
    /// No array or object nests deeper than the limit, and no raw zero byte (JSONDepth's own rule).
    public var isWithinDepth = true
    /// An object holds a key twice, escapes decoded, keys compared as Swift compares strings.
    public var hasDuplicateKey = false
    /// A \uD800–\uDFFF escape that is not half of a surrogate pair.
    public var hasLoneSurrogate = false
    /// Where the four hex digits of each such escape start, for `replacingLoneSurrogates`.
    public var loneSurrogateOffsets: [Int] = []
    /// A \u0000 escape (a raw zero byte already fails isWithinDepth).
    public var hasNUL = false
    /// A number whose text says more than the nearest double does (NumberText.isExact).
    public var hasInexactNumber = false

    public init() {}

    /// Two parsers may read the text as different values: never held, only observed.
    public var isAmbiguous: Bool { hasDuplicateKey || hasLoneSurrogate || hasNUL }

    /// One pass over `data`. It stops at the first level past `limit`, since such text is never parsed.
    public static func scan(_ data: Data, limit: Int = JSONDepth.limit) -> JSONScan {
        data.withUnsafeBytes { raw in
            var scanner = Scanner(limit: limit)
            for (offset, byte) in raw.bindMemory(to: UInt8.self).enumerated() {
                scanner.offset = offset
                guard scanner.feed(byte) else { return scanner.result }
            }
            scanner.finish()
            return scanner.result
        }
    }

    /// The text with each lone surrogate escape the scan found turned into \uFFFD (the replacement
    /// character) in place, four hex digits for four: the same length, every other byte as it was. What
    /// JSONSerialization refuses then reads as JavaScript shows such a character.
    public static func replacingLoneSurrogates(in data: Data, at offsets: [Int]) -> Data {
        var repaired = data
        let digits = Array("FFFD".utf8)
        for offset in offsets where offset >= 0 && offset + digits.count <= repaired.count {
            for (index, digit) in digits.enumerated() {
                repaired[repaired.startIndex + offset + index] = digit
            }
        }
        return repaired
    }

    private struct Container {
        let isObject: Bool
        var expectsKey: Bool
        var keys: Set<String> = []
    }

    private enum Escape {
        case none
        case backslash
        case unicode(digits: Int, value: UInt32)
    }

    private struct Scanner {
        let limit: Int
        var result = JSONScan()
        var containers: [Container] = []
        var isInString = false
        var escape = Escape.none
        /// A high surrogate escape that only a low surrogate escape right after it may pair with.
        var pendingHigh: UInt32?
        /// The byte being fed, where the current \u escape's digits start, and where the pending high's do.
        var offset = 0
        var digitsOffset = 0
        var pendingHighOffset = 0
        /// The key being read, as UTF-8; nil while in a value string.
        var key: [UInt8]?
        var number: [UInt8]?

        init(limit: Int) {
            self.limit = limit
        }

        /// False once the rest of the text no longer matters.
        mutating func feed(_ byte: UInt8) -> Bool {
            if byte == 0 {
                result.isWithinDepth = false
                return false
            }
            if isInString {
                stringByte(byte)
                return true
            }
            if number != nil {
                if NumberText.isNumberByte(byte) {
                    number?.append(byte)
                    return true
                }
                finishNumber()
            }
            switch byte {
            case UInt8(ascii: "\""):
                isInString = true
                if let last = containers.indices.last, containers[last].isObject, containers[last].expectsKey {
                    containers[last].expectsKey = false
                    key = []
                } else {
                    key = nil
                }
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                guard containers.count < limit else {
                    result.isWithinDepth = false
                    return false
                }
                let isObject = byte == UInt8(ascii: "{")
                containers.append(Container(isObject: isObject, expectsKey: isObject))
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if !containers.isEmpty { containers.removeLast() }
            case UInt8(ascii: ","):
                if let last = containers.indices.last, containers[last].isObject { containers[last].expectsKey = true }
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                number = [byte]
            default:
                break
            }
            return true
        }

        mutating func finish() {
            if number != nil { finishNumber() }
            if isInString { closeHigh() }
        }

        private mutating func stringByte(_ byte: UInt8) {
            switch escape {
            case .backslash:
                if byte == UInt8(ascii: "u") {
                    escape = .unicode(digits: 0, value: 0)
                    digitsOffset = offset + 1
                    return
                }
                closeHigh()
                escape = .none
                appendToKey(Self.unescaped(byte))
            case .unicode(let digits, let value):
                guard let digit = Self.hexValue(byte) else {
                    // Not JSON: JSONSerialization refuses it, so what follows needs no more care.
                    escape = .none
                    return
                }
                let unit = value << 4 | digit
                if digits < 3 {
                    escape = .unicode(digits: digits + 1, value: unit)
                } else {
                    escape = .none
                    codeUnit(unit)
                }
            case .none:
                switch byte {
                case UInt8(ascii: "\\"):
                    escape = .backslash
                case UInt8(ascii: "\""):
                    closeHigh()
                    isInString = false
                    if let bytes = key, let last = containers.indices.last {
                        if !containers[last].keys.insert(String(decoding: bytes, as: UTF8.self)).inserted {
                            result.hasDuplicateKey = true
                        }
                    }
                    key = nil
                default:
                    closeHigh()
                    appendToKey(byte)
                }
            }
        }

        private mutating func codeUnit(_ unit: UInt32) {
            switch unit {
            case 0xD800...0xDBFF:
                closeHigh()
                pendingHigh = unit
                pendingHighOffset = digitsOffset
            case 0xDC00...0xDFFF:
                guard let high = pendingHigh else {
                    loneSurrogate(at: digitsOffset)
                    return
                }
                pendingHigh = nil
                appendScalar(0x10000 + ((high - 0xD800) << 10) + (unit - 0xDC00))
            default:
                closeHigh()
                if unit == 0 { result.hasNUL = true }
                appendScalar(unit)
            }
        }

        /// A high surrogate that nothing paired with.
        private mutating func closeHigh() {
            guard pendingHigh != nil else { return }
            pendingHigh = nil
            loneSurrogate(at: pendingHighOffset)
        }

        private mutating func loneSurrogate(at digits: Int) {
            result.hasLoneSurrogate = true
            result.loneSurrogateOffsets.append(digits)
        }

        private mutating func appendToKey(_ byte: UInt8) {
            if key != nil { key?.append(byte) }
        }

        private mutating func appendScalar(_ value: UInt32) {
            guard key != nil, let scalar = Unicode.Scalar(value) else { return }
            key?.append(contentsOf: Array(String(Character(scalar)).utf8))
        }

        private mutating func finishNumber() {
            if let number, !NumberText.isExact(number) { result.hasInexactNumber = true }
            number = nil
        }

        private static func hexValue(_ byte: UInt8) -> UInt32? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return UInt32(byte - UInt8(ascii: "A") + 10)
            default: return nil
            }
        }

        /// What a one-character escape stands for (\" \\ \/ and the control letters).
        private static func unescaped(_ byte: UInt8) -> UInt8 {
            switch byte {
            case UInt8(ascii: "b"): return 0x08
            case UInt8(ascii: "f"): return 0x0C
            case UInt8(ascii: "n"): return 0x0A
            case UInt8(ascii: "r"): return 0x0D
            case UInt8(ascii: "t"): return 0x09
            default: return byte
            }
        }
    }
}

/// A JSON number's text against the double JavaScript reads it as. It is exact when its value is exactly the
/// decimal the nearest double prints as (shortest round trip, as JSON.stringify writes numbers): 1, 0.1, 1e21,
/// 9007199254740992 and -0 are; 9007199254740993, a decimal longer than a double keeps, 1e400 (infinite) and
/// 1e-400 (zero) are not.
public enum NumberText {
    /// Integers of at most 15 digits are below 2^53, so every double holds them.
    static let alwaysExactDigits = 15
    /// An exponent this large already makes any nonzero mantissa infinite or zero as a double.
    static let maxExponent = 100_000

    static func isNumberByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "+"), UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"):
            return true
        default:
            return false
        }
    }

    public static func isExact(_ token: [UInt8]) -> Bool {
        let digits = token.first == UInt8(ascii: "-") ? token.count - 1 : token.count
        if digits <= alwaysExactDigits, !token.contains(where: { $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "e") || $0 == UInt8(ascii: "E") }) {
            return digits > 0
        }
        guard let text = String(bytes: token, encoding: .ascii), let value = Double(text), value.isFinite,
              let written = Decimal(token), let nearest = Decimal(Array(value.description.utf8)) else { return false }
        return written == nearest
    }

    /// A decimal as sign, significant digits and a power of ten, so "1.50", "15e-1" and "1.5" are equal.
    /// Zero is one value whatever its sign (JSON.stringify writes -0 as 0).
    struct Decimal: Equatable {
        var isNegative = false
        var digits: [UInt8] = []
        var exponent = 0

        init?(_ text: [UInt8]) {
            var index = 0
            if index < text.count, text[index] == UInt8(ascii: "-") || text[index] == UInt8(ascii: "+") {
                isNegative = text[index] == UInt8(ascii: "-")
                index += 1
            }
            var hasDigit = false
            var isFraction = false
            while index < text.count {
                let byte = text[index]
                if byte == UInt8(ascii: ".") {
                    guard !isFraction else { return nil }
                    isFraction = true
                } else if (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
                    hasDigit = true
                    if isFraction { exponent -= 1 }
                    if !(digits.isEmpty && byte == UInt8(ascii: "0")) { digits.append(byte) }
                } else {
                    break
                }
                index += 1
            }
            guard hasDigit else { return nil }
            if index < text.count {
                guard text[index] == UInt8(ascii: "e") || text[index] == UInt8(ascii: "E") else { return nil }
                index += 1
                var isNegativeExponent = false
                if index < text.count, text[index] == UInt8(ascii: "-") || text[index] == UInt8(ascii: "+") {
                    isNegativeExponent = text[index] == UInt8(ascii: "-")
                    index += 1
                }
                var power = 0
                var hasExponentDigit = false
                while index < text.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(text[index]) {
                    hasExponentDigit = true
                    power = min(power * 10 + Int(text[index] - UInt8(ascii: "0")), NumberText.maxExponent)
                    index += 1
                }
                guard hasExponentDigit, index == text.count else { return nil }
                exponent += isNegativeExponent ? -power : power
            }
            while digits.last == UInt8(ascii: "0") {
                digits.removeLast()
                exponent += 1
            }
            if digits.isEmpty {
                isNegative = false
                exponent = 0
            }
        }
    }
}
