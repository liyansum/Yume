import Foundation

public enum ScriptScanError: Error, Equatable, Sendable {
    case sourceMissing
    case readFailed
    case undecodableText
    case binaryContent
}

public struct NScripterScanLimits: Sendable, Equatable {
    public let maximumFileByteCount: Int
    public let maximumCommandSampleCount: Int

    public init(
        maximumFileByteCount: Int = 33_554_432,
        maximumCommandSampleCount: Int = 4096
    ) {
        self.maximumFileByteCount = maximumFileByteCount
        self.maximumCommandSampleCount = maximumCommandSampleCount
    }
}

public struct NScripterScriptReport: Sendable, Equatable {
    public let lineCount: Int
    public let commandCounts: [String: Int]
    public let containsNonASCII: Bool
    public let sampleCommands: [String]

    public init(
        lineCount: Int,
        commandCounts: [String: Int],
        containsNonASCII: Bool,
        sampleCommands: [String]
    ) {
        self.lineCount = lineCount
        self.commandCounts = commandCounts
        self.containsNonASCII = containsNonASCII
        self.sampleCommands = sampleCommands
    }
}

public struct NScripterScriptScanner: Sendable {
    private let limits: NScripterScanLimits

    public init(limits: NScripterScanLimits = NScripterScanLimits()) {
        self.limits = limits
    }

    public func scan(fileAt url: URL) throws -> NScripterScriptReport {
        let data = try loadFile(url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ScriptScanError.undecodableText
        }
        guard !text.contains("\u{0}") else { throw ScriptScanError.binaryContent }

        var lineCount = 0
        var commandCounts: [String: Int] = [:]
        var sampleCommands: [String] = []
        var sampledTokens: Set<String> = []

        for line in Self.physicalLines(of: text) {
            lineCount += 1
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            guard let first = trimmed.first else { continue }
            if first == ";" || first == "*" { continue }
            guard let token = Self.commandToken(in: trimmed) else { continue }
            commandCounts[token, default: 0] += 1
            if sampleCommands.count < limits.maximumCommandSampleCount,
               sampledTokens.insert(token).inserted {
                sampleCommands.append(token)
            }
        }

        return NScripterScriptReport(
            lineCount: lineCount,
            commandCounts: commandCounts,
            containsNonASCII: text.contains { !$0.isASCII },
            sampleCommands: sampleCommands
        )
    }

    private func loadFile(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw ScriptScanError.sourceMissing }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { throw ScriptScanError.sourceMissing }
        if let size = values?.fileSize, size > limits.maximumFileByteCount {
            throw ScriptScanError.readFailed
        }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard let data = try handle.read(upToCount: limits.maximumFileByteCount + 1) else {
                throw ScriptScanError.readFailed
            }
            guard data.count <= limits.maximumFileByteCount else {
                throw ScriptScanError.readFailed
            }
            return data
        } catch let error as ScriptScanError {
            throw error
        } catch {
            throw ScriptScanError.readFailed
        }
    }

    private static func physicalLines(of text: String) -> [Substring] {
        var lines: [Substring] = []
        var lineStart = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\n" || character == "\r" || character == "\r\n" {
                lines.append(text[lineStart..<index])
                lineStart = text.index(after: index)
            }
            index = text.index(after: index)
        }
        lines.append(text[lineStart...])
        if lines.count > 1, lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }

    private static func commandToken(in line: Substring) -> String? {
        guard let start = line.firstIndex(where: { $0.isASCII && $0.isLetter }) else {
            return nil
        }
        var end = start
        while end < line.endIndex, isTokenCharacter(line[end]) {
            end = line.index(after: end)
        }
        let token = String(line[start..<end])
        return token.isEmpty ? nil : token
    }

    private static func isTokenCharacter(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        return character.isLetter || character.isNumber || character == "_"
    }
}
