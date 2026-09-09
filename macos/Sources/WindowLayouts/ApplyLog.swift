import Foundation

/// Writes the apply log: ~/Library/Application Support/WindowLayouts/apply.log
enum ApplyLog {
    static let url = LayoutStore.shared.directoryURL.appendingPathComponent("apply.log")
    private static let maxBytes = 512 * 1024
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ line: String) {
        let text = "\(formatter.string(from: Date())) \(line)\n"
        guard let data = text.data(using: .utf8) else { return }
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int), size > maxBytes {
            try? fm.removeItem(at: url)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
