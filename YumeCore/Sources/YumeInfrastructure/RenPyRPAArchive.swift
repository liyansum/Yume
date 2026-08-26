import Foundation
import YumeDomain

public enum RPAError: Error, Equatable, Sendable {
    case sourceIsNotFileURL
    case sourceMissing
    case sourceIsSymbolicLink
    case invalidArchive
    case unsupportedFormatVersion(String)
    case truncatedIndex
    case unsafePath
    case duplicatePath
    case entryLimitExceeded
    case pathLimitExceeded
}

public struct RPALimits: Sendable, Equatable {
    public let maximumEntryCount: Int
    public let maximumPathByteCount: Int

    public init(maximumEntryCount: Int = 100_000, maximumPathByteCount: Int = 1_024) {
        self.maximumEntryCount = maximumEntryCount
        self.maximumPathByteCount = maximumPathByteCount
    }
}

public struct RPAGameFileEntry: Sendable, Equatable {
    public let relativePath: StorageRelativePath
    public let offset: UInt64
    public let byteCount: UInt64

    public init(relativePath: StorageRelativePath, offset: UInt64, byteCount: UInt64) {
        self.relativePath = relativePath
        self.offset = offset
        self.byteCount = byteCount
    }
}

public struct RenPyRPAArchive: Sendable {
    private static let maximumHeaderLineByteCount = 128
    private static let maximumIndexByteCount = 64 * 1_024 * 1_024
    private static let maximumOperationCount = 2_000_000

    private let limits: RPALimits

    public init(limits: RPALimits = RPALimits()) {
        self.limits = limits
    }

    public func index(at url: URL) throws -> [RPAGameFileEntry] {
        guard url.isFileURL else { throw RPAError.sourceIsNotFileURL }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw RPAError.sourceIsSymbolicLink }
        guard values.isRegularFile == true else { throw RPAError.sourceMissing }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let headerLine = try readHeaderLine(handle)
        var parser = HeaderParser(line: headerLine)
        let format = try parser.parseVersion()
        let indexOffset = try parser.parseHexOffset()
        let key: UInt32?
        switch format {
        case .onePointZero:
            key = nil
        case .twoOrThreePointZero:
            key = try parser.parseHexKey()
        }

        let fileSize = UInt64(values.fileSize ?? 0)
        guard indexOffset > 0, indexOffset < fileSize else { throw RPAError.truncatedIndex }
        try handle.seek(toOffset: indexOffset)
        guard let indexData = try handle.read(upToCount: Self.maximumIndexByteCount),
              !indexData.isEmpty
        else { throw RPAError.truncatedIndex }

        return try decodeIndex(indexData, key: key)
    }

    public func decodeIndex(_ data: Data, key: UInt32?) throws -> [RPAGameFileEntry] {
        var decoder = PickleDecoder(data: data, limits: limits)
        return try decoder.decode(key: key)
    }

    private func readHeaderLine(_ handle: FileHandle) throws -> [UInt8] {
        guard let chunk = try handle.read(upToCount: Self.maximumHeaderLineByteCount),
              !chunk.isEmpty
        else { throw RPAError.invalidArchive }
        let bytes = [UInt8](chunk)
        guard let newline = bytes.firstIndex(of: 0x0A) else { throw RPAError.invalidArchive }
        return Array(bytes[..<newline])
    }
}

private enum HeaderVersion {
    case onePointZero
    case twoOrThreePointZero
}

private struct HeaderParser {
    private static let separator: UInt8 = 0x20

    private let tokens: [[UInt8]]
    private var position = 0

    init(line: [UInt8]) {
        var split: [[UInt8]] = []
        var current: [UInt8] = []
        for byte in line {
            if byte == Self.separator {
                if !current.isEmpty { split.append(current); current = [] }
            } else {
                current.append(byte)
            }
        }
        if !current.isEmpty { split.append(current) }
        tokens = split
    }

    mutating func parseVersion() throws -> HeaderVersion {
        guard let token = next(), let text = String(bytes: token, encoding: .ascii) else {
            throw RPAError.invalidArchive
        }
        switch text {
        case "RPA-1.0":
            return .onePointZero
        case "RPA-2.0", "RPA-3.0":
            return .twoOrThreePointZero
        default:
            throw RPAError.unsupportedFormatVersion(text)
        }
    }

    mutating func parseHexOffset() throws -> UInt64 {
        guard let token = next() else { throw RPAError.truncatedIndex }
        return try Self.hexValue(token)
    }

    mutating func parseHexKey() throws -> UInt32 {
        guard let token = next() else { throw RPAError.truncatedIndex }
        return UInt32(truncatingIfNeeded: try Self.hexValue(token))
    }

    private func next() -> [UInt8]? {
        guard position < tokens.count else { return nil }
        defer { position += 1 }
        return tokens[position]
    }

    private static func hexValue(_ token: [UInt8]) throws -> UInt64 {
        guard !token.isEmpty else { throw RPAError.invalidArchive }
        var value: UInt64 = 0
        for byte in token {
            let digit: UInt64
            switch byte {
            case 0x30...0x39: digit = UInt64(byte - 0x30)
            case 0x61...0x66: digit = UInt64(byte - 0x61 + 10)
            case 0x41...0x46: digit = UInt64(byte - 0x41 + 10)
            default: throw RPAError.invalidArchive
            }
            let shifted = value << 4
            guard (shifted >> 4) == value else { throw RPAError.invalidArchive }
            value = shifted | digit
        }
        return value
    }
}

private struct PickleDecoder {
    private enum Value {
        case text(String)
        case number(Int64)
        case sequence([Value])
        case mapping([Value])

        var numberValue: Int64? {
            if case let .number(value) = self { return value }
            return nil
        }
    }

    private static let protocolOpcode: UInt8 = 0x80
    private static let frameOpcode: UInt8 = 0x95
    private static let memoizeOpcode: UInt8 = 0x94
    private static let binInputOpcode: UInt8 = 0x71
    private static let longBinInputOpcode: UInt8 = 0x72
    private static let markOpcode: UInt8 = 0x28
    private static let stopOpcode: UInt8 = 0x2E
    private static let shortTextOpcode: UInt8 = 0x55
    private static let longTextOpcode: UInt8 = 0x58
    private static let binFloatOpcode: UInt8 = 0x47
    private static let intTextOpcode: UInt8 = 0x49
    private static let longTextNumberOpcode: UInt8 = 0x4C
    private static let noneOpcode: UInt8 = 0x4E
    private static let newTrueOpcode: UInt8 = 0x88
    private static let newFalseOpcode: UInt8 = 0x89
    private static let tupleOpcode: UInt8 = 0x74
    private static let emptyTupleOpcode: UInt8 = 0x29
    private static let emptyListOpcode: UInt8 = 0x5D
    private static let emptyMappingOpcode: UInt8 = 0x7D
    private static let appendOpcode: UInt8 = 0x61
    private static let appendsOpcode: UInt8 = 0x65
    private static let setItemOpcode: UInt8 = 0x73
    private static let setItemsOpcode: UInt8 = 0x75

    private let data: Data
    private let limits: RPALimits
    private var offset = 0
    private var stack: [Value] = []
    private var marks: [Int] = []
    private var operationCount = 0

    init(data: Data, limits: RPALimits) {
        self.data = data
        self.limits = limits
    }

    mutating func decode(key: UInt32?) throws -> [RPAGameFileEntry] {
        loop: while true {
            operationCount += 1
            guard operationCount <= RenPyRPAArchive.maximumOperationCount else {
                throw RPAError.invalidArchive
            }
            switch try readByte() {
            case Self.protocolOpcode:
                _ = try readByte()
            case Self.frameOpcode:
                _ = try readData(count: 8)
            case Self.memoizeOpcode:
                _ = try pop()
            case Self.binInputOpcode:
                _ = try readByte()
            case Self.longBinInputOpcode:
                _ = try readData(count: 4)
            case Self.markOpcode:
                marks.append(stack.count)
            case Self.stopOpcode:
                break loop
            case Self.shortTextOpcode:
                stack.append(.text(try readShortText()))
            case Self.longTextOpcode:
                stack.append(.text(try readLongText()))
            case Self.binFloatOpcode:
                stack.append(.number(try readBinFloat()))
            case Self.intTextOpcode, Self.longTextNumberOpcode:
                stack.append(.number(try readDecimal()))
            case Self.noneOpcode:
                stack.append(.number(0))
            case Self.newTrueOpcode:
                stack.append(.number(1))
            case Self.newFalseOpcode:
                stack.append(.number(0))
            case Self.tupleOpcode:
                stack.append(.sequence(try takeMarkedItems()))
            case Self.emptyTupleOpcode:
                stack.append(.sequence([]))
            case Self.emptyListOpcode:
                stack.append(.sequence([]))
            case Self.emptyMappingOpcode:
                stack.append(.mapping([]))
            case Self.appendOpcode:
                try appendSingle()
            case Self.appendsOpcode:
                try appendMarked()
            case Self.setItemOpcode:
                try setSingleItem()
            case Self.setItemsOpcode:
                try setMarkedItems()
            default:
                throw RPAError.invalidArchive
            }
        }
        return try buildEntries(key: key)
    }

    private func buildEntries(key: UInt32?) throws -> [RPAGameFileEntry] {
        guard let top = pop(), case let .mapping(pairs) = top, pairs.count % 2 == 0 else {
            throw RPAError.invalidArchive
        }

        var entries: [RPAGameFileEntry] = []
        var foldedPaths: Set<String> = []

        for pairIndex in stride(from: 0, to: pairs.count, by: 2) {
            guard entries.count < limits.maximumEntryCount else { throw RPAError.entryLimitExceeded }
            guard let rawName = pairs[pairIndex].textValue else { throw RPAError.invalidArchive }
            let name = Self.unobfuscatedName(rawName, key: key)
            guard !name.isEmpty, name.utf8.count <= limits.maximumPathByteCount else {
                throw RPAError.pathLimitExceeded
            }
            guard let relativePath = try? StorageRelativePath(rawValue: name) else {
                throw RPAError.unsafePath
            }
            let folded = name.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard foldedPaths.insert(folded).inserted else { throw RPAError.duplicatePath }

            let fields = pairs[pairIndex + 1]
            let offset: Int64
            let size: Int64
            switch fields.sequenceValues?.count ?? 0 {
            case 2:
                guard let first = fields.sequenceValues?[0].numberValue,
                      let second = fields.sequenceValues?[1].numberValue
                else { throw RPAError.invalidArchive }
                offset = first
                size = second
            case 3:
                guard let first = fields.sequenceValues?[0].numberValue,
                      let third = fields.sequenceValues?[2].numberValue
                else { throw RPAError.invalidArchive }
                offset = first
                size = third
            default:
                throw RPAError.invalidArchive
            }
            guard offset >= 0, size >= 0 else { throw RPAError.invalidArchive }

            entries.append(
                RPAGameFileEntry(
                    relativePath: relativePath,
                    offset: UInt64(offset),
                    byteCount: UInt64(size)
                )
            )
        }
        return entries
    }

    private static func unobfuscatedName(_ name: String, key: UInt32?) -> String {
        guard let key, key != 0 else { return name }
        var scalars = String.UnicodeScalarView()
        for character in name {
            for scalar in character.unicodeScalars {
                let xored = scalar.value ^ UInt32(truncatingIfNeeded: UInt64(key))
                if xored > 0, xored <= 0x10FFFF, let unobfuscated = Unicode.Scalar(xored) {
                    scalars.append(unobfuscated)
                }
            }
        }
        return String(scalars)
    }

    private mutating func pop() throws -> Value? {
        guard !stack.isEmpty else { return nil }
        return stack.removeLast()
    }

    private mutating func takeMarkedItems() throws -> [Value] {
        guard let mark = marks.popLast(), mark <= stack.count else { throw RPAError.invalidArchive }
        let items = Array(stack[mark...])
        if mark < stack.count { stack.removeSubrange(mark...) }
        return items
    }

    private mutating func appendSingle() throws {
        guard let item = try pop(), let container = try pop(),
              case let .sequence(existing) = container
        else { throw RPAError.invalidArchive }
        var items = existing
        items.append(item)
        stack.append(.sequence(items))
    }

    private mutating func appendMarked() throws {
        let additions = try takeMarkedItems()
        guard let container = try pop(),
              case let .sequence(existing) = container
        else { throw RPAError.invalidArchive }
        var items = existing
        items.append(contentsOf: additions)
        stack.append(.sequence(items))
    }

    private mutating func setSingleItem() throws {
        guard let newValue = try pop(), let keyValue = try pop(), let container = try pop(),
              case let .mapping(existing) = container
        else { throw RPAError.invalidArchive }
        var pairs = existing
        pairs.append(keyValue)
        pairs.append(newValue)
        stack.append(.mapping(pairs))
    }

    private mutating func setMarkedItems() throws {
        let additions = try takeMarkedItems()
        guard additions.count % 2 == 0, let container = try pop(),
              case let .mapping(existing) = container
        else { throw RPAError.invalidArchive }
        var pairs = existing
        pairs.append(contentsOf: additions)
        stack.append(.mapping(pairs))
    }

    private mutating func readByte() throws -> UInt8 {
        guard offset < data.count else { throw RPAError.truncatedIndex }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    private mutating func readData(count: Int) throws -> Data {
        guard count >= 0, count <= data.count - offset else { throw RPAError.truncatedIndex }
        defer { offset += count }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
    }

    private mutating func readShortText() throws -> String {
        let payload = try readData(count: Int(try readByte()))
        guard let text = String(data: payload, encoding: .utf8) else { throw RPAError.invalidArchive }
        return text
    }

    private mutating func readLongText() throws -> String {
        let lengthData = try readData(count: 4)
        var length: UInt32 = 0
        for index in 0..<4 {
            length |= UInt32(lengthData[lengthData.startIndex + index]) << (8 * UInt32(index))
        }
        let payload = try readData(count: Int(length))
        guard let text = String(data: payload, encoding: .utf8) else { throw RPAError.invalidArchive }
        return text
    }

    private mutating func readBinFloat() throws -> Int64 {
        let bitsData = try readData(count: 8)
        var bits: UInt64 = 0
        for index in 0..<8 {
            bits |= UInt64(bitsData[bitsData.startIndex + index]) << (8 * UInt64(7 - index))
        }
        let double = Double(bitPattern: bits)
        guard double >= 0, double <= Double(Int64.max), double.rounded() == double else {
            throw RPAError.invalidArchive
        }
        return Int64(double)
    }

    private mutating func readDecimal() throws -> Int64 {
        var text: [UInt8] = []
        while true {
            let byte = try readByte()
            if byte == 0x0A { break }
            text.append(byte)
        }
        guard let value = Int64(String(decoding: text, as: UTF8.self)) else {
            throw RPAError.invalidArchive
        }
        return value
    }
}

private extension PickleDecoder.Value {
    var textValue: String? {
        if case let .text(value) = self { return value }
        return nil
    }

    var sequenceValues: [PickleDecoder.Value]? {
        if case let .sequence(value) = self { return value }
        return nil
    }
}
