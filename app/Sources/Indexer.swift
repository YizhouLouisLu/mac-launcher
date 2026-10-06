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
    static func parse(_ rawQuery: String) -> (quitMode: Bool, query: String, dictionaryPrefix: Bool) {
        let trimmed = rawQuery.trimmed()
        let lower = trimmed.lowercased()
        if lower.hasPrefix("quit ") { return (true, String(trimmed.dropFirst(5)).trimmed(), false) }
        if lower == "quit" { return (true, "", false) }
        if lower.hasPrefix("q ") { return (true, String(trimmed.dropFirst(2)).trimmed(), false) }
        if lower == "q" { return (true, "", false) }
        // `d <word>` (or `英 <word>`) forces a dictionary lookup even when the word also
        // matches applications or files, where the automatic gloss is not enough.
        for prefix in ["d ", "dict ", "英 "] {
            if lower.hasPrefix(prefix) {
                return (false, String(trimmed.dropFirst(prefix.count)).trimmed(), true)
            }
        }
        return (false, trimmed, false)
    }

    /// The web row for a plain query, using the configured default engine. Placed after any
    /// exact title match so that typing an application's name still launches it.
    static func defaultWebSearchItem(for query: String, engines: [SearchEngine], defaultKeyword: String) -> Item? {
        let trimmed = query.trimmed()
        guard trimmed.count >= 2, !defaultKeyword.isEmpty,
              let engine = engines.first(where: { $0.keyword.lowercased() == defaultKeyword.lowercased() }),
              engine.urlTemplate.contains("{query}") else { return nil }
        let url = engine.urlTemplate.replacingOccurrences(
            of: "{query}",
            with: trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed)
        return Item(title: Indexer.searchTitle(engineName: engine.name, query: trimmed),
                    subtitle: "\(engine.keyword) · \(url)",
                    path: url,
                    kind: .webSearch,
                    alternateTitles: [engine.keyword],
                    url: url)
    }

    /// Puts the action rows (web search above dictionary) on top of the ordinary results.
    ///
    /// An engine the user named explicitly always wins the first row — that is what typing a
    /// keyword means. The default-engine row for plain queries keeps one exception: an exact
    /// title match stays above it, so Return still launches the application.
    static func prependActions(to ranked: [Item], rawQuery: String, config: Config) -> [Item] {
        let parsed = parse(rawQuery)
        guard !parsed.quitMode else { return ranked }

        if let search = webSearchItem(for: rawQuery, engines: config.engines) {
            var result = ranked
            if let dictionary = dictionaryRow(rawQuery: rawQuery, ranked: ranked) {
                result.insert(dictionary, at: 0)
            }
            result.insert(search, at: 0)
            return result
        }

        var result = ranked
        let needle = parsed.query.lowercased()
        // Exact matches include alias hits: `设置` matches the settings command through its
        // alternate titles, and that command must keep Return.
        var insertAt = ranked.prefix { item in
            item.searchTitle == needle || item.alternateTitles.contains { $0.lowercased() == needle }
        }.count
        // A stock query is an explicit intent (`st X` or a bare code), so the default-engine
        // row must not sit above those rows.
        // `d <word>` is an explicit dictionary request, so the default-engine row would sit on
        // top of the very row the user asked for.
        let isStockQuery = stockQuery(for: rawQuery) != nil
        let isDictionaryQuery = parsed.dictionaryPrefix
        if !isStockQuery, !isDictionaryQuery,
           let fallback = defaultWebSearchItem(for: parsed.query,
                                              engines: config.engines,
                                              defaultKeyword: config.defaultEngineKeyword) {
            result.insert(fallback, at: min(insertAt, result.count))
            insertAt += 1
        }
        if let dictionary = dictionaryRow(rawQuery: rawQuery, ranked: ranked) {
            result.insert(dictionary, at: min(insertAt, result.count))
        }
        return result
    }

    /// Chinese engine names read better without the surrounding spaces ("用维基百科搜索"), while
    /// Latin names need them ("用 INSPIRE-HEP 搜索").
    static func searchTitle(engineName: String, query: String?) -> String {
        let isChinese = engineName.contains { !$0.isASCII }
        let suffix = query.map { "搜索「\($0)」" } ?? "搜索…"
        return isChinese ? "用\(engineName)\(suffix)" : "用 \(engineName) \(suffix)"
    }

    /// Strips `{query}` from a template to get the engine's own search page, dropping the
    /// dangling `?`/`&`/`=` that would otherwise be left behind.
    static func engineBaseURL(_ template: String) -> String? {
        var base = template.replacingOccurrences(of: "{query}", with: "")
        while let last = base.last, "?&=".contains(last) { base.removeLast() }
        base = base.trimmed()
        return base.isEmpty ? nil : base
    }

    /// The stock lookup a query asks for, if any.
    ///
    /// Explicit prefixes (`st `/`股 `) always trigger; a bare 5–6 digit code does too. Ordinary
    /// words never do — otherwise every word typed would fire a suggest request.
    /// An empty string means "the user asked for the watchlist itself".
    static func stockQuery(for rawQuery: String) -> String? {
        let trimmed = rawQuery.trimmed()
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if ["自选", "自选股", "自选股票"].contains(trimmed) { return "" }
        for prefix in ["st ", "股 "] where lower.hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count)).trimmed()
        }
        if ["st", "股", "stock"].contains(lower) { return "" }
        if (5...6).contains(trimmed.count), trimmed.allSatisfy({ $0.isNumber }) { return trimmed }
        return nil
    }

    /// Dropdown rows for stocks. Quotes may be missing (still loading), in which case the row
    /// says so rather than showing a stale or invented price.
    static func stockItems(hits: [StockSymbol], quotes: [String: StockQuote]) -> [Item] {
        hits.map { hit in
            let code = "\(hit.plainCode) · \(hit.market.rawValue)"
            let subtitle: String
            if let quote = quotes[hit.code] {
                subtitle = "\(code) · \(quote.priceText)  \(quote.changeText)"
            } else {
                subtitle = "\(code) · 行情加载中…"
            }
            return Item(title: hit.name,
                        subtitle: subtitle,
                        path: "",
                        kind: .stock,
                        alternateTitles: [hit.plainCode, hit.code.lowercased()],
                        url: "stock://\(hit.code)")
        }
    }

    /// The single row shown for a bare `st`: open the watchlist.
    static func watchlistItem(count: Int) -> Item {
        Item(title: "打开自选股票",
             subtitle: count == 0 ? "自选为空 —— 先搜索股票，回车即可加入" : "共 \(count) 只，显示实时行情与走势",
             path: "",
             kind: .stock,
             alternateTitles: ["自选"],
             url: "stock://watchlist")
    }

    /// The word whose entry should be offered for this query, if any.
    static func dictionaryWord(rawQuery: String) -> String? {
        let parsed = parse(rawQuery)
        guard !parsed.quitMode, !parsed.query.isEmpty else { return nil }
        if parsed.dictionaryPrefix { return parsed.query }
        return Dictionary.isCandidate(parsed.query) ? parsed.query : nil
    }

    /// Builds the dictionary row: the word, its brief gloss, and `dict://` for the detail
    /// window. Placed first, unless a row already matches the query exactly — typing an
    /// application's exact name must keep launching it with Return.
    private static func dictionaryRow(rawQuery: String, ranked: [Item]) -> Item? {
        guard let word = dictionaryWord(rawQuery: rawQuery),
              let entry = Dictionary.lookUp(word) else { return nil }
        return Item(title: "词典：\(entry.headword)",
                    subtitle: entry.brief,
                    path: "",
                    kind: .dictionary,
                    alternateTitles: [entry.headword],
                    url: "dict://\(entry.headword)")
    }

    static func quitMode(for rawQuery: String) -> Bool {
        parse(rawQuery).quitMode
    }

    // MARK: - search

    /// Builds the web row for an engine keyword. Two modes, decided by the URL template:
    ///
    ///   * template contains `{query}` — search mode: `<keyword> <text>` searches.
    ///   * template has no `{query}`   — direct mode: `<keyword>` alone opens that page,
    ///     which is what a fixed destination (mail, notifications, dashboard) needs.
    ///
    /// Only an exact keyword match counts, so ordinary typing is never hijacked.
    private static func webSearchItem(for rawQuery: String, engines: [SearchEngine]) -> Item? {
        let trimmed = rawQuery.trimmed()
        guard !trimmed.isEmpty else { return nil }

        let separator = trimmed.firstIndex(of: " ")
        let keyword = String(separator.map { trimmed[trimmed.startIndex..<$0] } ?? Substring(trimmed)).lowercased()
        let query = separator.map { String(trimmed[trimmed.index(after: $0)...]).trimmed() } ?? ""
        guard !keyword.isEmpty,
              let engine = engines.first(where: { $0.keyword.lowercased() == keyword }) else { return nil }

        // A search-mode engine with no text yet still shows an option: the engine keyword was
        // typed on purpose, so the row appears at once and opens that engine's search page.
        if query.isEmpty, engine.urlTemplate.contains("{query}") {
            guard let base = Indexer.engineBaseURL(engine.urlTemplate) else { return nil }
            return Item(title: Indexer.searchTitle(engineName: engine.name, query: nil),
                        subtitle: "\(engine.keyword) · 继续输入关键词，直接回车打开 \(engine.name) 搜索页",
                        path: base,
                        kind: .webSearch,
                        alternateTitles: [engine.keyword],
                        url: base)
        }

        let isDirect = !engine.urlTemplate.contains("{query}")
        if isDirect {
            // Extra text after a direct keyword is treated as an ordinary search instead of
            // being silently discarded.
            guard query.isEmpty else { return nil }
            let url = engine.urlTemplate.trimmed()
            guard !url.isEmpty else { return nil }
            return Item(title: "打开 \(engine.name)",
                        subtitle: "\(engine.keyword) · \(url)",
                        path: url,
                        kind: .webSearch,
                        alternateTitles: [engine.keyword],
                        url: url)
        }

        guard !query.isEmpty else { return nil }
        // `urlQueryAllowed` alone leaves & = + ? # unescaped, which would let a query
        // containing them inject extra URL parameters, so those are removed.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        let url = engine.urlTemplate.replacingOccurrences(of: "{query}", with: encoded)
        return Item(title: Indexer.searchTitle(engineName: engine.name, query: query),
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
        // Actions (dictionary, web search) are offered above the ordinary matches.
        return Array(Indexer.prependActions(to: ranked, rawQuery: rawQuery, config: config)
            .prefix(config.maxResults))
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

        // The instant paint may already have contributed action rows; keep exactly one of each.
        candidates.removeAll { $0.kind == .webSearch || $0.kind == .dictionary }
        let ranked = rank(candidates,
                          needle: parsed.query.lowercased(),
                          quitMode: parsed.quitMode,
                          limit: config.maxResults)
        return Array(Indexer.prependActions(to: ranked, rawQuery: rawQuery, config: config)
            .prefix(config.maxResults))
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
