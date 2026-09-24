import Foundation

/// Splits a byte stream into newline-delimited messages (app-server framing).
public struct LineBuffer: Sendable {
    private var storage = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [Data] {
        storage.append(data)
        var lines: [Data] = []
        while let newline = storage.firstIndex(of: 0x0A) {
            var line = Data(storage[storage.startIndex..<newline])
            storage = Data(storage[storage.index(after: newline)...])
            if line.last == 0x0D { line.removeLast() }
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    public var pendingByteCount: Int { storage.count }
}

/// Minimal JSON-RPC message model. app-server omits the `"jsonrpc": "2.0"`
/// field, so this neither sends nor requires it.
public enum RPCMessage {
    case response(id: Int, result: Data)
    case error(id: Int, code: Int, message: String)
    case notification(method: String, params: Data?)
    /// Server-to-client request (approvals etc.). This app answers "unsupported".
    case request(id: RPCID, method: String)
    case invalid

    public enum RPCID: Equatable {
        case int(Int)
        case string(String)

        public var jsonValue: Any {
            switch self {
            case .int(let value): return value
            case .string(let value): return value
            }
        }
    }

    public static func parse(_ line: Data) -> RPCMessage {
        guard let object = (try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed])) as? [String: Any] else {
            return .invalid
        }

        let method = object["method"] as? String
        let rawID = object["id"]

        if let method {
            if let rawID, let id = rpcID(rawID) {
                return .request(id: id, method: method)
            }
            return .notification(method: method, params: encode(object["params"]))
        }

        guard let rawID, case .int(let id)? = rpcID(rawID) else {
            return .invalid
        }

        if let error = object["error"] as? [String: Any] {
            let code = (error["code"] as? NSNumber)?.intValue ?? -1
            let message = error["message"] as? String ?? "Unknown app-server error"
            return .error(id: id, code: code, message: message)
        }

        return .response(id: id, result: encode(object["result"]) ?? Data("null".utf8))
    }

    public static func encodeRequest(id: Int, method: String, params: Any?) throws -> Data {
        var object: [String: Any] = ["id": id, "method": method]
        if let params { object["params"] = params }
        return try line(object)
    }

    public static func encodeNotification(method: String, params: Any? = nil) throws -> Data {
        var object: [String: Any] = ["method": method]
        if let params { object["params"] = params }
        return try line(object)
    }

    public static func encodeErrorResponse(id: RPCID, code: Int, message: String) throws -> Data {
        try line(["id": id.jsonValue, "error": ["code": code, "message": message]])
    }

    private static func line(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    private static func rpcID(_ raw: Any) -> RPCID? {
        if let string = raw as? String { return .string(string) }
        if let number = raw as? NSNumber { return .int(number.intValue) }
        return nil
    }

    private static func encode(_ value: Any?) -> Data? {
        guard let value, !(value is NSNull) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }
}
