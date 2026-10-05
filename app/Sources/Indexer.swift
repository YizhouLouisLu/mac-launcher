import AppKit

/// Owns the in-memory application index and the ranking rules.
///
/// File results are **not** indexed here: they come from `SpotlightSearcher`, because
/// enumerating the configured folders from this process blocked indefinitely. This
/// class therefore never touches the file system.
final class Indexer {
    static let applicationRoots: [String] = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        // macOS ships Safari (and other system apps) inside a cryptex; the copies in
        // /Applications are symlinks into this directory.
        "/System/Cryptexes/App/System/Applications",
        NSHomeDirectory() + "/Applications"
    ]

    /// Built-in palette commands: always available, ranked alongside everything else so
    /// typing `snippets` or `reload` finds them.
    static let builtinCommands: [Item] = [
        Item(title: "MacLauncher 设置…",
             subtitle: "片段 · 搜索引擎 · 自动展开",
             path: "",
             kind: .command,
             alternateTitles: ["设置", "设置窗口", "偏好", "偏好设置", "preferences", "settings",
                               "snippets", "snippet", "片段", "搜索引擎", "引擎", "config"],
             command: "snippets"),
        Item(title: "重新载入配置",
             subtitle: "重新读取 config.json",
             path: "",
             kind: .command,
             alternateTitles: ["reload", "reload config", "重载", "重新加载", "刷新配置"],
             command: "reload")
    ]

    private let lock = NSLock()
    /// How many Spotlight candidates are turned into rows before ranking. The candidate
    /// stream is unsorted, so a small cap here is what used to hide real matches.
    static let fileCandidateLimit = 300
    private var installed: [Item] = []   // directory scan result, without running info
    private var _apps: [Item] = []
    private var _snippets: [Item] = []

    var apps: [Item] {
        lock.lock(); defer { lock.unlock() }
        return _apps
    }

    var snippets: [Item] {
        lock.lock(); defer { lock.unlock() }
        return _snippets
    }

    /// Rebuilds the snippet rows from configuration. Called at startup, after a reload,
    /// and when a newer shared config is adopted.
    func updateSnippets(_ snippets: [Snippet]) {
        let items = snippets.map { snippet -> Item in
            Item(title: snippet.name.isEmpty ? snippet.keyword : snippet.name,
                 subtitle: "片段 · \(snippet.keyword)",
                 path: "",
                 kind: .snippet,
                 alternateTitles: [snippet.keyword],
                 snippetContent: snippet.content)
        }
        lock.lock()
        _snippets = items
        lock.unlock()
        Log.write("snippets loaded: \(items.count)")
    }

    // MARK: - building the app index

    /// Scans the application directories. This is the only I/O stage; run it once.
    func buildApps() {
        let started = Date()
        var byPath: [String: Item] = [:]

        for root in Indexer.applicationRoots {
            for bundleURL in Indexer.appBundles(in: root, maxDepth: 2) {
                let resolved = bundleURL.resolvingSymlinksInPath().standardizedFileURL
                let path = resolved.path
                if byPath[path] != nil { continue }
                byPath[path] = Indexer.makeAppItem(resolvedPath: path,
                                                  originalFileName: bundleURL.deletingPathExtension().lastPathComponent,
                                                  running: nil)
            }
        }

        let scanned = byPath.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        lock.lock()
        installed = scanned
        lock.unlock()

        refreshRunningState()
        Log.write("app index: \(scanned.count) installed scanned in \(Int(Date().timeIntervalSince(started) * 1000))ms")
    }

    /// Re-overlays live running state. Cheap (no file-system access) and called before
    /// each palette search: without it an app launched after startup would never be
    /// quittable, because quit mode only lists running applications.
    func refreshRunningState() {
        lock.lock()
        let base = installed
        lock.unlock()

        let overlaid = Indexer.overlayRunning(on: base)

        lock.lock()
        _apps = overlaid
        lock.unlock()
    }

    private static func overlayRunning(on base: [Item]) -> [Item] {
        let ownBundleID = Bundle.main.bundleIdentifier
        let running = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular && app.bundleIdentifier != ownBundleID
        }
        var runningByPath: [String: NSRunningApplication] = [:]
        for app in running {
            guard let bundleURL = app.bundleURL else { continue }
            runningByPath[bundleURL.resolvingSymlinksInPath().standardizedFileURL.path] = app
        }

        var result: [Item] = []
        result.reserveCapacity(base.count + runningByPath.count)
        var seen = Set<String>()
        for item in base {
            seen.insert(item.path)
            if let app = runningByPath[item.path] {
                result.append(item.markedRunning(app))
            } else if item.running != nil {
                result.append(item.unmarkedRunning())
            } else {
                result.append(item)
            }
        }
        for (path, app) in runningByPath where !seen.contains(path) {
            let fileName = (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            result.append(Indexer.makeAppItem(resolvedPath: path, originalFileName: fileName, running: app))
        }

        let runningCount = result.filter { $0.running != nil }.count
        Log.write("running state refreshed: \(runningCount) running of \(result.count)")
        return result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Recursive walk that, unlike `FileManager.enumerator`, does **not** skip symlinks
    /// pointing at directories. macOS ships `/Applications/Safari.app` as a symlink into
    /// the cryptex, and the built-in enumerator silently omits it.
    private static func appBundles(in root: String, maxDepth: Int) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root) else { return [] }

        var result: [URL] = []
        func walk(_ directory: URL, depth: Int) {
            guard depth <= maxDepth else { return }
            guard let entries = try? fm.contentsOfDirectory(at: directory,
                                                           includingPropertiesForKeys: nil,
                                                           options: [.skipsHiddenFiles]) else { return }
            for entry in entries {
                if entry.pathExtension.lowercased() == "app" {
                    result.append(entry)
                    continue // never descend into a bundle
                }
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    walk(entry, depth: depth + 1)
                }
            }
        }
        walk(URL(fileURLWithPath: root, isDirectory: true), depth: 1)
        return result
    }

    private static func makeAppItem(resolvedPath: String,
                                    originalFileName: String,
                                    running: NSRunningApplication?) -> Item {
        var displayName = FileManager.default.displayName(atPath: resolvedPath)
        if displayName.lowercased().hasSuffix(".app") {
            displayName = String(displayName.dropLast(4))
        }
        let title = displayName.isEmpty ? originalFileName : displayName
        var alternates = [originalFileName]
        if let localized = running?.localizedName { alternates.append(localized) }
        return Item(title: title,
                    subtitle: resolvedPath,
                    path: resolvedPath,
                    kind: running == nil ? .application : .runningApp,
                    bundleIdentifier: running?.bundleIdentifier,
                    running: running,
                    alternateTitles: alternates)
    }

    // MARK: - query parsing

    /// Splits the optional "quit"/"q" prefix from a raw query. Single source of truth
    /// for both the search path and the UI's action decision.
    static func parse(_ rawQuery: String) -> (quitMode: Bool, query: String) {
        let trimmed = rawQuery.trimmed()
        let lower = trimmed.lowercased()
        if lower.hasPrefix("quit ") { return (true, String(trimmed.dropFirst(5)).trimmed()) }
        if lower == "quit" { return (true, "") }
        if lower.hasPrefix("q ") { return (true, String(trimmed.dropFirst(2)).trimmed()) }
        if lower == "q" { return (true, "") }
        return (false, trimmed)
    }

    static func quitMode(for rawQuery: String) -> Bool {
        parse(rawQuery).quitMode
    }

    // MARK: - search

    /// Builds the "search the web" row for a `<engine keyword> <query>` input. Only an
    /// exact keyword match counts, so ordinary typing is never hijacked by a search row.
    private static func webSearchItem(for rawQuery: String, engines: [SearchEngine]) -> Item? {
        let trimmed = rawQuery.trimmed()
        guard let separator = trimmed.firstIndex(of: " ") else { return nil }
        let keyword = String(trimmed[trimmed.startIndex..<separator]).lowercased()
        let query = String(trimmed[trimmed.index(after: separator)...]).trimmed()
        guard !keyword.isEmpty, !query.isEmpty,
              let engine = engines.first(where: { $0.keyword.lowercased() == keyword }) else { return nil }
        // `urlQueryAllowed` alone leaves & = + ? # unescaped, which would let a query
        // containing them inject extra URL parameters, so those are removed.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        let url = engine.urlTemplate.replacingOccurrences(of: "{query}", with: encoded)
        return Item(title: "用 \(engine.name) 搜索「\(query)」",
                    subtitle: "\(engine.keyword) · \(url)",
                    path: url,
                    kind: .webSearch,
                    alternateTitles: [engine.keyword],
                    url: url)
    }

    /// Instant application-only results, used for the first paint of the palette.
    func searchApps(rawQuery: String, config: Config) -> [Item] {
        let parsed = Indexer.parse(rawQuery)
        if parsed.query.isEmpty {
            let pool = parsed.quitMode ? apps.filter { $0.running != nil } : apps
            return Array(pool.prefix(config.maxResults))
        }
        // Snippets and built-in commands compete with applications in normal mode;
        // quit mode is applications only.
        var candidates = apps
        if !parsed.quitMode {
            lock.lock()
            candidates.append(contentsOf: _snippets)
            lock.unlock()
            candidates.append(contentsOf: Indexer.builtinCommands)
        }
        let ranked = rank(candidates,
                          needle: parsed.query.lowercased(),
                          quitMode: parsed.quitMode,
                          limit: config.maxResults)
        // A web search is an action, so it is offered above the ordinary matches.
        if !parsed.quitMode,
           let search = Indexer.webSearchItem(for: rawQuery, engines: config.engines) {
            var withSearch = ranked
            withSearch.insert(search, at: 0)
            return Array(withSearch.prefix(config.maxResults))
        }
        return ranked
    }

    /// Merges Spotlight file paths with the app results so both compete on one score
    /// scale. In quit mode only applications are considered.
    func merge(rawQuery: String,
               apps appCandidates: [Item],
               filePaths: [String],
               config: Config) -> [Item] {
        let parsed = Indexer.parse(rawQuery)
        // An empty query (or bare "q") keeps the instant app list; there is nothing for
        // Spotlight to contribute.
        guard !parsed.query.isEmpty else {
            return Array(appCandidates.prefix(config.maxResults))
        }

        var candidates: [Item] = []
        if !parsed.quitMode {
            let needle = parsed.query.lowercased()
            // Score and trim the paths *before* building rows: mdfind can hand back a few
            // thousand candidates and only the best handful is ever displayed.
            candidates = filePaths
                .map { path -> (path: String, score: Int) in
                    let name = (path as NSString).lastPathComponent
                    return (path, Ranking.fileScore(name: name, pathLower: path.lowercased(), query: needle))
                }
                .filter { $0.score > 0 }
                .sorted { lhs, rhs in
                    lhs.score != rhs.score ? lhs.score > rhs.score : lhs.path < rhs.path
                }
                .prefix(Indexer.fileCandidateLimit)
                .map { entry -> Item in
                    let path = entry.path
                    let rawName = (path as NSString).lastPathComponent
                    // An application bundle found through Spotlight behaves like an
                    // application: launchable by name, with the app icon and badge.
                    let isAppBundle = rawName.hasSuffix(".app")
                    let name = isAppBundle ? (rawName as NSString).deletingPathExtension : rawName
                    let isFolder = !isAppBundle && Indexer.isDirectory(path)
                    let depth = path.lowercased().split(separator: "/").count
                    let kind: ItemKind = isAppBundle ? .application : (isFolder ? .folder : .file)
                    return Item(title: name,
                                subtitle: (path as NSString).deletingLastPathComponent,
                                path: path,
                                kind: kind,
                                pathDepthBonus: Ranking.depthBonus(for: depth))
                }
        }
        candidates.append(contentsOf: appCandidates)

        // The instant paint may already have contributed a web-search row; keep exactly one.
        candidates.removeAll { $0.kind == .webSearch }
        let ranked = rank(candidates,
                          needle: parsed.query.lowercased(),
                          quitMode: parsed.quitMode,
                          limit: config.maxResults)
        if !parsed.quitMode,
           let search = Indexer.webSearchItem(for: rawQuery, engines: config.engines) {
            var withSearch = ranked
            withSearch.insert(search, at: 0)
            return Array(withSearch.prefix(config.maxResults))
        }
        return ranked
    }

    private func rank(_ candidates: [Item], needle: String, quitMode: Bool, limit: Int) -> [Item] {
        var scored: [(item: Item, score: Int)] = []

        for item in candidates {
            if quitMode && item.running == nil { continue }

            var best = Ranking.titleScore(searchTitle: item.searchTitle,
                                          initialsLower: item.initialsLower,
                                          query: needle)
            for (index, alternate) in item.alternateSearchTitles.enumerated() {
                let score = Ranking.titleScore(searchTitle: alternate,
                                               initialsLower: item.alternateInitialsLowers[index],
                                               query: needle)
                if let score = score, score > (best ?? 0) { best = score }
            }
            if best == nil {
                best = Ranking.pathScore(pathLower: item.pathLower, query: needle)
            }
            guard let score = best else { continue }
            scored.append((item, score + item.pathDepthBonus + (item.running != nil ? 50 : 0)))
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.item.title.count != rhs.item.title.count { return lhs.item.title.count < rhs.item.title.count }
            if lhs.item.title != rhs.item.title { return lhs.item.title < rhs.item.title }
            return lhs.item.path < rhs.item.path
        }

        return scored.prefix(limit).map { $0.item }
    }

    /// `lstat` rather than Foundation: a plain syscall cannot block on a dataless iCloud
    /// file, and this runs for at most a few dozen display rows.
    static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }
}
