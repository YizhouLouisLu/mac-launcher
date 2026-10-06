import Foundation

// MARK: - paths

enum AppPaths {
    static var supportDirectory: URL {
        // Test seam: `MACLAUNCHER_SUPPORT_DIR` redirects the config/log away from the real
        // one, so the first-run path (bundled defaults) can be exercised without touching
        // the user's configuration. `HOME` does not work for this — Foundation resolves the
        // home directory through the user record, not the environment.
        if let override = ProcessInfo.processInfo.environment["MACLAUNCHER_SUPPORT_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacLauncher", isDirectory: true)
    }

    /// The file the app actually reads at startup. Always local, so startup can never
    /// depend on a network-backed file provider.
    static var localConfigURL: URL { supportDirectory.appendingPathComponent("config.json") }

    /// The shared copy in iCloud Drive.
    ///
    /// This is a pure path construction on purpose: it performs no file-system check.
    /// Any stat inside `~/Library/Mobile Documents` can block for tens of seconds in
    /// fileproviderd, and a LaunchServices-launched app was measured hanging forever
    /// on it. If Drive is unavailable the read simply fails and the local copy wins.
    static var sharedConfigURL: URL {
        // Test seam, same idea as supportDirectory: lets the reconciliation be exercised
        // against a scratch file instead of the real iCloud Drive copy.
        if let override = ProcessInfo.processInfo.environment["MACLAUNCHER_SHARED_CONFIG"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/MacLauncher/config.json")
    }

    static var logURL: URL { supportDirectory.appendingPathComponent("launcher.log") }

    /// Query history: runtime state, deliberately not part of config.json.
    static var historyURL: URL { supportDirectory.appendingPathComponent("history.json") }
}

// MARK: - logging

enum Log {
    private static let formatter = ISO8601DateFormatter()
    private static let lock = NSLock()

    static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }

        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let fm = FileManager.default
        try? fm.createDirectory(at: AppPaths.supportDirectory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: AppPaths.logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: AppPaths.logURL)
        }
        FileHandle.standardError.write(data)
    }
}

// MARK: - small helpers

extension String {
    var expandedPath: String { (self as NSString).expandingTildeInPath }

    func trimmed() -> String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
