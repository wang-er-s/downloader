import Foundation

/// Vendor-owned execution records. The application translates this wire format.
/// Callbacks are serialized through this lock, including version allocation and
/// atomic publication. No acknowledgement rewrites the current snapshot.
enum ExecutionJournal {
    static let lock = NSRecursiveLock()
    static var lastSamples = [String: UInt64]()
    static var resumeOffsets = [String: Int64]()

    static func directory(_ task: Task) -> URL? {
        guard let data = task.metaData.data(using: .utf8),
              let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = metadata["executionJournal"] as? String else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    @discardableResult static func record(_ task: Task, _ changes: [String: Any]) -> Bool {
        guard let directory = directory(task) else { return true }
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let versions = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" && Int($0.deletingPathExtension().lastPathComponent) != nil }
                .sorted { Int($0.deletingPathExtension().lastPathComponent)! < Int($1.deletingPathExtension().lastPathComponent)! }
            var value: [String: Any] = ["protocolVersion": 1, "downloadedBytes": 0, "totalBytes": NSNull()]
            if let last = versions.last {
                value = try JSONSerialization.jsonObject(with: Data(contentsOf: last)) as! [String: Any]
            }
            let version = (value["receiptVersion"] as? Int ?? 0) + 1
            value["task"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task))
            value.merge(changes) { _, new in new }
            value["receiptVersion"] = version
            let file = directory.appendingPathComponent("\(version).json")
            try JSONSerialization.data(withJSONObject: value).write(to: file, options: .atomic)
            let handle = try FileHandle(forWritingTo: file)
            try handle.synchronize()
            try handle.close()
            return true
        } catch {
            // Do not deliver a receipt that has not been saved.
            NSLog("background_downloader: execution journal write failed")
            return false
        }
    }

    static func bytes(_ task: Task, written: Int64, expected: Int64) {
        lock.lock()
        defer { lock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds / 1_000_000
        if now - (lastSamples[task.taskId] ?? 0) < 1000 { return }
        lastSamples[task.taskId] = now
        // URLSession's cumulative delegate value includes its resumed offset.
        // didResumeAtOffset establishes the minimum accepted cumulative value.
        let bytes = max(written, resumeOffsets[task.taskId] ?? 0)
        record(task, ["downloadedBytes": bytes,
                      "totalBytes": expected < 0 ? NSNull() : NSNumber(value: expected),
                      "sampleMonotonicMs": now])
    }
}
