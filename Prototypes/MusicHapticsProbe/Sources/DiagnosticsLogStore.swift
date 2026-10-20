import Foundation

struct DiagnosticEvent: Codable, Equatable, Sendable {
    let timestamp: String
    let category: String
    let result: String
    let parameters: [String: String]
}

actor DiagnosticsLogStore {
    static let shared = DiagnosticsLogStore()

    private let directoryURL: URL
    private let maximumFileBytes: Int
    private let rotatedFileCount: Int

    init(directoryURL: URL? = nil, maximumFileBytes: Int = 256 * 1024, rotatedFileCount: Int = 3) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.directoryURL = directoryURL ?? documents.appendingPathComponent("Diagnostics", isDirectory: true)
        self.maximumFileBytes = max(1_024, maximumFileBytes)
        self.rotatedFileCount = max(0, rotatedFileCount)
    }

    func record(
        category: String,
        result: String,
        parameters: [String: String] = [:],
        at date: Date = .now
    ) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            var cleanParameters = parameters
                .sorted { $0.key < $1.key }
                .prefix(32)
                .reduce(into: [:]) { partial, pair in
                    partial[Self.bounded(pair.key, limit: 48)] = Self.bounded(pair.value, limit: 160)
                }
            var event = DiagnosticEvent(
                timestamp: ISO8601DateFormatter().string(from: date),
                category: Self.bounded(category, limit: 48),
                result: Self.bounded(result, limit: 96),
                parameters: cleanParameters
            )
            var line = try JSONEncoder().encode(event)
            while line.count > maximumFileBytes, let key = cleanParameters.keys.sorted().last {
                cleanParameters.removeValue(forKey: key)
                event = DiagnosticEvent(
                    timestamp: event.timestamp,
                    category: event.category,
                    result: event.result,
                    parameters: cleanParameters
                )
                line = try JSONEncoder().encode(event)
            }
            guard line.count <= maximumFileBytes else { return }
            line.append(0x0A)

            let currentURL = currentLogURL
            let currentSize = (try? currentURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if currentSize > 0, currentSize + line.count > maximumFileBytes {
                try rotateLogs()
            }

            if !FileManager.default.fileExists(atPath: currentLogURL.path) {
                FileManager.default.createFile(atPath: currentLogURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: currentLogURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // Diagnostics must never interfere with playback or application startup.
        }
    }

    func readAllText() -> String {
        let urls = existingLogURLsOldestFirst
        return urls.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
    }

    func exportURL() throws -> URL {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let url = directoryURL.appendingPathComponent("music-haptics-diagnostics-export.jsonl")
        try Data(readAllText().utf8).write(to: url, options: .atomic)
        return url
    }

    func clear() throws {
        for index in 0...rotatedFileCount {
            let name = index == 0 ? "diagnostics.jsonl" : "diagnostics.\(index).jsonl"
            let url = directoryURL.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        let export = directoryURL.appendingPathComponent("music-haptics-diagnostics-export.jsonl")
        if FileManager.default.fileExists(atPath: export.path) {
            try FileManager.default.removeItem(at: export)
        }
    }

    private var currentLogURL: URL {
        directoryURL.appendingPathComponent("diagnostics.jsonl")
    }

    private var existingLogURLsOldestFirst: [URL] {
        let manager = FileManager.default
        let candidates = (try? manager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return candidates
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent != "music-haptics-diagnostics-export.jsonl" }
            .sorted { left, right in
                func age(_ url: URL) -> Int {
                    if url.lastPathComponent == "diagnostics.jsonl" { return Int.max }
                    let component = url.deletingPathExtension().lastPathComponent
                    guard let index = Int(component.split(separator: ".").last ?? "0") else { return Int.max - 1 }
                    return rotatedFileCount - index
                }
                return age(left) < age(right)
            }
    }

    private func rotateLogs() throws {
        let manager = FileManager.default
        for index in stride(from: rotatedFileCount, through: 1, by: -1) {
            let destination = directoryURL.appendingPathComponent("diagnostics.\(index).jsonl")
            let source = index == 1
                ? currentLogURL
                : directoryURL.appendingPathComponent("diagnostics.\(index - 1).jsonl")
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            if manager.fileExists(atPath: source.path) {
                try manager.moveItem(at: source, to: destination)
            }
        }
        if rotatedFileCount == 0, manager.fileExists(atPath: currentLogURL.path) {
            try manager.removeItem(at: currentLogURL)
        }
    }

    private static func bounded(_ value: String, limit: Int) -> String {
        String(value.prefix(limit)).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }
}
