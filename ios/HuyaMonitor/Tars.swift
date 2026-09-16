import Foundation

enum Tars {
    static let byte = 0
    static let short = 1
    static let int = 2
    static let long = 3
    static let float = 4
    static let double = 5
    static let string1 = 6
    static let string4 = 7
    static let map = 8
    static let list = 9
    static let structBegin = 10
    static let structEnd = 11
    static let zero = 12
    static let simpleList = 13
}

final class TarsOutput {
    private(set) var bytes = [UInt8]()

    func toData() -> Data {
        return Data(bytes)
    }

    private func appendBigEndian(_ value: UInt64, count: Int) {
        var shift = (count - 1) * 8
        while shift >= 0 {
            bytes.append(UInt8((value >> UInt64(shift)) & 0xFF))
            shift -= 8
        }
    }

    func writeHead(_ type: Int, tag: Int) {
        if tag < 15 {
            bytes.append(UInt8((tag << 4) | type))
        } else {
            bytes.append(UInt8(0xF0 | type))
            bytes.append(UInt8(tag & 0xFF))
        }
    }

    func writeBool(_ value: Bool, tag: Int) {
        writeInt(value ? 1 : 0, tag: tag)
    }

    func writeInt(_ value: Int, tag: Int) {
        if value == 0 {
            writeHead(Tars.zero, tag: tag)
            return
        }
        if value >= -128 && value <= 127 {
            writeHead(Tars.byte, tag: tag)
            bytes.append(UInt8(truncatingIfNeeded: value))
            return
        }
        if value >= -32768 && value <= 32767 {
            writeHead(Tars.short, tag: tag)
            appendBigEndian(UInt64(UInt16(truncatingIfNeeded: value)), count: 2)
            return
        }
        if value >= -2147483648 && value <= 2147483647 {
            writeHead(Tars.int, tag: tag)
            appendBigEndian(UInt64(UInt32(truncatingIfNeeded: value)), count: 4)
            return
        }
        writeHead(Tars.long, tag: tag)
        appendBigEndian(UInt64(bitPattern: Int64(value)), count: 8)
    }

    func writeString(_ text: String, tag: Int) {
        let data = Array(text.utf8)
        if data.count > 255 {
            writeHead(Tars.string4, tag: tag)
            appendBigEndian(UInt64(UInt32(data.count)), count: 4)
        } else {
            writeHead(Tars.string1, tag: tag)
            bytes.append(UInt8(data.count))
        }
        bytes.append(contentsOf: data)
    }

    func writeBytes(_ data: Data, tag: Int) {
        let payload = [UInt8](data)
        writeHead(Tars.simpleList, tag: tag)
        writeHead(Tars.byte, tag: 0)
        writeInt(payload.count, tag: 0)
        bytes.append(contentsOf: payload)
    }
}

final class TarsInput {
    private let data: [UInt8]
    private var pos = 0

    init(_ data: Data) {
        self.data = [UInt8](data)
    }

    init(_ data: [UInt8]) {
        self.data = data
    }

    func remaining() -> Int {
        return data.count - pos
    }

    private func readU8() throws -> UInt8 {
        guard pos < data.count else { throw TarsError.overflow }
        let value = data[pos]
        pos += 1
        return value
    }

    private func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, pos + count <= data.count else { throw TarsError.overflow }
        let chunk = Array(data[pos..<(pos + count)])
        pos += count
        return chunk
    }

    func readHead() throws -> (type: Int, tag: Int) {
        let first = try readU8()
        let type = Int(first & 0x0F)
        var tag = Int((first & 0xF0) >> 4)
        if tag == 15 {
            tag = Int(try readU8())
        }
        return (type, tag)
    }

    func peekHead() -> (type: Int, tag: Int)? {
        let saved = pos
        defer { pos = saved }
        return try? readHead()
    }

    func skipField(_ type: Int) throws {
        switch type {
        case Tars.byte:
            _ = try readU8()
        case Tars.short:
            _ = try readBytes(2)
        case Tars.int, Tars.float:
            _ = try readBytes(4)
        case Tars.long, Tars.double:
            _ = try readBytes(8)
        case Tars.string1:
            let count = Int(try readU8())
            _ = try readBytes(count)
        case Tars.string4:
            let head = try readBytes(4)
            let count = Int(UInt32(head[0]) << 24 | UInt32(head[1]) << 16 | UInt32(head[2]) << 8 | UInt32(head[3]))
            _ = try readBytes(count)
        case Tars.map:
            let size = readInt(tag: 0)
            for _ in 0..<max(0, size) {
                let keyHead = try readHead()
                try skipField(keyHead.type)
                let valueHead = try readHead()
                try skipField(valueHead.type)
            }
        case Tars.list:
            let size = readInt(tag: 0)
            for _ in 0..<max(0, size) {
                let head = try readHead()
                try skipField(head.type)
            }
        case Tars.structBegin:
            while true {
                let head = try readHead()
                if head.type == Tars.structEnd { break }
                try skipField(head.type)
            }
        case Tars.structEnd, Tars.zero:
            return
        case Tars.simpleList:
            _ = try readHead()
            let count = readInt(tag: 0)
            _ = try readBytes(count)
        default:
            throw TarsError.unknownType(type)
        }
    }

    @discardableResult
    func skipToTag(_ tag: Int) throws -> Bool {
        while remaining() > 0 {
            guard let head = peekHead() else { return false }
            if head.type == Tars.structEnd { return false }
            if head.tag == tag { return true }
            if head.tag > tag { return false }
            _ = try readHead()
            try skipField(head.type)
        }
        return false
    }

    func readInt(tag: Int, fallback: Int = 0) -> Int {
        do {
            guard try skipToTag(tag) else { return fallback }
            let head = try readHead()
            switch head.type {
            case Tars.zero:
                return 0
            case Tars.byte:
                let value = Int(try readU8())
                return value > 127 ? value - 256 : value
            case Tars.short:
                let raw = try readBytes(2)
                let value = UInt16(raw[0]) << 8 | UInt16(raw[1])
                return Int(Int16(bitPattern: value))
            case Tars.int:
                let raw = try readBytes(4)
                let value = UInt32(raw[0]) << 24 | UInt32(raw[1]) << 16 | UInt32(raw[2]) << 8 | UInt32(raw[3])
                return Int(Int32(bitPattern: value))
            case Tars.long:
                var value: UInt64 = 0
                for byte in try readBytes(8) {
                    value = (value << 8) | UInt64(byte)
                }
                return Int(Int64(bitPattern: value))
            default:
                return fallback
            }
        } catch {
            return fallback
        }
    }

    func readBool(tag: Int, fallback: Bool = false) -> Bool {
        return readInt(tag: tag, fallback: fallback ? 1 : 0) != 0
    }

    func readString(tag: Int, fallback: String = "") -> String {
        do {
            guard try skipToTag(tag) else { return fallback }
            let head = try readHead()
            switch head.type {
            case Tars.zero:
                return ""
            case Tars.string1:
                let count = Int(try readU8())
                return String(decoding: try readBytes(count), as: UTF8.self)
            case Tars.string4:
                let raw = try readBytes(4)
                let count = Int(UInt32(raw[0]) << 24 | UInt32(raw[1]) << 16 | UInt32(raw[2]) << 8 | UInt32(raw[3]))
                return String(decoding: try readBytes(count), as: UTF8.self)
            default:
                return fallback
            }
        } catch {
            return fallback
        }
    }

    func readBytes(tag: Int) -> Data {
        do {
            guard try skipToTag(tag) else { return Data() }
            let head = try readHead()
            switch head.type {
            case Tars.zero:
                return Data()
            case Tars.simpleList:
                _ = try readHead()
                let count = readInt(tag: 0)
                return Data(try readBytes(count))
            case Tars.list:
                let count = readInt(tag: 0)
                var out = [UInt8]()
                out.reserveCapacity(max(0, count))
                for _ in 0..<max(0, count) {
                    out.append(UInt8(truncatingIfNeeded: readInt(tag: 0)))
                }
                return Data(out)
            default:
                return Data()
            }
        } catch {
            return Data()
        }
    }

    func readStructBytes(tag: Int) -> Data? {
        do {
            guard try skipToTag(tag) else { return nil }
            let head = try readHead()
            guard head.type == Tars.structBegin else { return nil }
            let start = pos
            var depth = 1
            while depth > 0 {
                let nested = try readHead()
                if nested.type == Tars.structBegin {
                    depth += 1
                } else if nested.type == Tars.structEnd {
                    depth -= 1
                } else {
                    try skipField(nested.type)
                }
            }
            guard pos - 1 >= start else { return nil }
            return Data(data[start..<(pos - 1)])
        } catch {
            return nil
        }
    }
}

enum TarsError: Error {
    case overflow
    case unknownType(Int)
}
