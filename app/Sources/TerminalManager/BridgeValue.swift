import Foundation

/// Strict readers for values from JavaScript or JSON: both turn booleans and numbers into NSNumber, so a
/// plain `as? Bool` would accept 1 and `as? Int` would accept true.
enum BridgeValue {
    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func double(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    static func int(_ value: Any?) -> Int? {
        guard let double = double(value), double == double.rounded(), abs(double) <= 9_007_199_254_740_991 else { return nil }
        return Int(double)
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }
}

extension Date {
    var millis: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
}
