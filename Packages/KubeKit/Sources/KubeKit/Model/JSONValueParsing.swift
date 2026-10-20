import Foundation

extension JSONValue {
    /// Fast parse via `JSONSerialization`. The `Decodable` path has to probe each node by trial decoding,
    /// which is ~15x slower on large lists. Keys in `omittingKeys` are skipped at any depth before they are
    /// materialized as Swift values (used to drop `managedFields` from list rows).
    public static func parse(_ data: Data, omittingKeys: Set<String> = []) throws -> JSONValue {
        try autoreleasepool {
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return convert(object, omitting: omittingKeys)
        }
    }

    private static func convert(_ object: Any, omitting: Set<String>) -> JSONValue {
        switch object {
        case let dictionary as [String: Any]:
            var result: [String: JSONValue] = [:]
            result.reserveCapacity(dictionary.count)
            for (key, value) in dictionary where !omitting.contains(key) {
                result[key] = convert(value, omitting: omitting)
            }
            return .object(result)
        case let array as [Any]:
            return .array(array.map { convert($0, omitting: omitting) })
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if CFNumberIsFloatType(number) { return .double(number.doubleValue) }
            // Unsigned values above Int64.max would wrap negative; keep the magnitude (precision is lossy).
            if String(cString: number.objCType) == "Q", number.uint64Value > UInt64(Int64.max) {
                return .double(number.doubleValue)
            }
            return .int(number.int64Value)
        default:
            return .null
        }
    }
}
