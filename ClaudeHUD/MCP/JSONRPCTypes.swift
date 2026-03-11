import Foundation

// MARK: - JSON Value

/// A type-erased JSON value that can represent any valid JSON.
enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Codable

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unable to decode JSON value"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    // MARK: Conversion Helpers

    /// Convert an arbitrary Foundation object (from JSONSerialization) into a JSONValue.
    static func from(_ any: Any) -> JSONValue {
        switch any {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            // NSNumber wraps both booleans and numbers; check boolean first.
            // CFBooleanGetTypeID is the reliable way to distinguish.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        case let array as [Any]:
            return .array(array.map { from($0) })
        case let dict as [String: Any]:
            return .object(dict.mapValues { from($0) })
        case is NSNull:
            return .null
        default:
            // Best-effort fallback: coerce to string description.
            return .string(String(describing: any))
        }
    }

    /// Convert back to a Foundation object suitable for JSONSerialization.
    func toAny() -> Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .null:
            return NSNull()
        case .array(let values):
            return values.map { $0.toAny() }
        case .object(let dict):
            return dict.mapValues { $0.toAny() }
        }
    }
}

// MARK: - JSON-RPC 2.0 Request

struct JSONRPCRequest: Codable, Sendable {
    let jsonrpc: String
    let id: Int?
    let method: String
    let params: JSONValue?

    init(id: Int? = nil, method: String, params: JSONValue? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

// MARK: - JSON-RPC 2.0 Response

struct JSONRPCResponse: Codable, Sendable {
    let jsonrpc: String
    let id: Int?
    let result: JSONValue?
    let error: JSONRPCError?

    /// Convenience: true when the server returned an error frame.
    var isError: Bool { error != nil }
}

// MARK: - JSON-RPC 2.0 Error Object

struct JSONRPCError: Codable, Sendable, Error, LocalizedError {
    let code: Int
    let message: String
    let data: JSONValue?

    var errorDescription: String? {
        "JSON-RPC error \(code): \(message)"
    }

    // Standard JSON-RPC error codes
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
}
