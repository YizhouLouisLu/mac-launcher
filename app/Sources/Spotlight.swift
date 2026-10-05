import Foundation

/// File search through Spotlight (`mdfind`) instead of directory enumeration.
///
/// Measured rationale: enumerating `~/Desktop`, `~/Documents` or `~/Downloads` from a
/// LaunchServices-launched app blocked indefinitely inside `open()` (iCloud dataless
/// directories / TCC), while `mdfind` answers in 150–310 ms without touching the file
/// system directly.
///
/// Two robustness rules, both learned the hard way here:
///  * the child is reaped by a watchdog after `deadline`, so a stuck index degrades to
///    "no file results" instead of a frozen palette;
///  * `completion` runs on this object's own serial queue, **never** on the main queue,
///    because the command line tools have no main run loop. Callers that touch UI must
///    hop to the main queue themselves.
final class SpotlightSearcher {
    private let queue = DispatchQueue(label: "com.luyizhou.maclauncher.spotlight")

    /// Asynchronously finds file names containing `query` under `folders`.
    /// `completion` receives absolute paths (at most `limit`) on the searcher's queue.
    func search(query: String,
                folders: [String],
                limit: Int,
                deadline: TimeInterval = 3.0,
                completion: @escaping ([String]) -> Void) {
        let trimmed = query.trimmed()
        guard !trimmed.isEmpty else {
            completion([])
            return
        }
        // A quote would break out of the Spotlight query literal.
        let needle = trimmed.replacingOccurrences(of: "'", with: "")
        queue.async {
            let paths = self.runMdfind(needle: needle, folders: folders, limit: limit, deadline: deadline)
            completion(paths)
        }
    }

    private func runMdfind(needle: String,
                           folders: [String],
                           limit: Int,
                           deadline: TimeInterval) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")

        // The scope goes to the index through `-onlyin`. Without it the child returns every
        // match on the machine — `*pdf*` was 20292 paths — and a cap applied to that
        // unsorted stream kept 4 of the 2162 that were actually in scope, which is exactly
        // how a file search ends up "finding nothing".
        var arguments: [String] = []
        for folder in folders {
            arguments.append("-onlyin")
            arguments.append(folder)
        }
        // Modifiers belong outside the quotes: `'*x*c'` means "…and ends with a literal c".
        // A single field only: adding `|| kMDItemDisplayName == …` doubled the query cost
        // (measured 0.42s -> 0.91s over the home directory) and buys nothing for files,
        // whose display name is the file name anyway; app names are indexed separately.
        arguments.append("kMDItemFSName == \"*\(needle)*\"cd")
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
        } catch {
            Log.write("mdfind could not launch: \(error)")
            return []
        }

        // Watchdog on an independent queue: the reading queue below is blocked.
        let watchdog = DispatchWorkItem { [weak process] in
            if let process = process, process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline, execute: watchdog)

        // Bounded read: a one-character query can match tens of thousands of paths, and the
        // ranker only needs a candidate pool, not the whole index dump.
        var data = Data()
        let byteCap = 256 * 1024
        while data.count < byteCap {
            guard let chunk = try? pipe.fileHandleForReading.read(upToCount: 64 * 1024),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }
        if process.isRunning { process.terminate() }
        watchdog.cancel()

        var text = String(data: data, encoding: .utf8) ?? ""
        if !text.hasSuffix("\n"), let lastBreak = text.lastIndex(of: "\n") {
            text = String(text[text.startIndex...lastBreak])   // drop a half-read line
        }

        var seen = Set<String>()
        var results: [String] = []
        for line in text.split(separator: "\n") {
            guard results.count < limit else { break }
            let path = String(line)
            guard !path.isEmpty, !SpotlightSearcher.isJunkPath(path) else { continue }
            guard seen.insert(path).inserted else { continue }
            results.append(path)
        }

        // `terminationStatus` raises an Objective-C exception while the task is still
        // running (it did abort the process when the watchdog had just fired), so it is
        // only read once the process is known to have exited.
        if !process.isRunning, process.terminationStatus != 0, process.terminationStatus != 15 {
            Log.write("mdfind exited with status \(process.terminationStatus) for \"\(needle)\"")
        }
        return results
    }

    /// Paths that flood a name search without ever being what the user meant: application
    /// caches, containers, dependency trees. `~/Library/Mobile Documents` (iCloud Drive) is
    /// deliberately *not* filtered.
    static func isJunkPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        let markers = ["/library/caches/", "/library/containers/", "/library/group containers/",
                       "/library/application support/", "/library/logs/", "/library/developer/",
                       "/library/assistant/", "/library/diagnostics/",
                       "/node_modules/", "/site-packages/", "/.git/", "/.build/", "/.cache/",
                       "/deriveddata/", "/.trash/", "/.venv/", "/.npm/", "/.cargo/"]
        if markers.contains(where: { lower.contains($0) }) { return true }
        // Bundle *internals* are noise, but a `.app` bundle itself is something the user may
        // well be looking for (applications outside the standard /Applications roots).
        if lower.contains(".app/contents/") { return true }
        return false
    }
}
