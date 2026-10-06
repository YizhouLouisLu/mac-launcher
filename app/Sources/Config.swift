import Foundation

/// A web-search engine entry. Parsed in P0 but only used from P2 onward.
struct SearchEngine: Codable {
    var keyword: String
    var name: String
    var urlTemplate: String
}

/// User configuration.
///
/// Storage is deliberately two-tier: the local copy is authoritative for startup
/// speed, and the iCloud copy is read on a background queue and adopted when it
/// differs. Nothing on the startup path touches iCloud.
///
/// File search is delegated to Spotlight, so there are no depth or file-count knobs:
/// `searchFolders` only scopes which Spotlight hits are kept.
struct Config: Codable {
    var searchFolders: [String]
    /// Search the whole home directory in addition to `searchFolders`. Spotlight queries are
    /// index-based, so widening the scope costs little and is what makes files outside a few
    /// hand-picked folders findable.
    var searchHomeFolder: Bool
    var maxResults: Int
    var hotKey: String
    /// Escape hatch for a crowded menu bar: on a notched display macOS silently hides
    /// overflow status items, so a Dock icon may be the only visible entry point.
    var showInDock: Bool
    var engines: [SearchEngine]
    var snippets: [Snippet]
    /// Alfred-style in-place expansion while typing in any application.
    var autoExpandSnippets: Bool
    /// Engine used for plain queries (no keyword typed); empty disables the row.
    var defaultEngineKeyword: String

    /// Watchlist symbols in feed spelling (`sh600519`, `hk00700`, `usAAPL`).
    var stockWatchlist: [String] = []
    /// How expansion replaces the keyword: "type" (Unicode key events, default) or
    /// "paste" (clipboard + Cmd+V, slower but more compatible with odd targets).
    var snippetInjection: String

    enum CodingKeys: String, CodingKey {
        case searchFolders, searchHomeFolder, maxResults, hotKey, showInDock, engines, snippets, autoExpandSnippets, snippetInjection, stockWatchlist, defaultEngineKeyword
    }

    init() {
        searchFolders = ["~/Desktop", "~/Documents", "~/Downloads", "~/Library/Mathematica"]
        searchHomeFolder = true
        maxResults = 12
        hotKey = "option+space"
        showInDock = false
        engines = [
            SearchEngine(keyword: "g", name: "Google",
                         urlTemplate: "https://www.google.com/search?q={query}"),
            SearchEngine(keyword: "bing", name: "Bing",
                         urlTemplate: "https://www.bing.com/search?q={query}"),
            SearchEngine(keyword: "gh", name: "GitHub",
                         urlTemplate: "https://github.com/search?q={query}"),
            SearchEngine(keyword: "arxiv", name: "arXiv",
                         urlTemplate: "https://arxiv.org/search/?query={query}&searchtype=all"),
            SearchEngine(keyword: "inspire", name: "INSPIRE-HEP",
                         urlTemplate: "https://inspirehep.net/search?q={query}"),
            SearchEngine(keyword: "scholar", name: "Google Scholar",
                         urlTemplate: "https://scholar.google.com/scholar?q={query}"),
            SearchEngine(keyword: "wiki", name: "维基百科",
                         urlTemplate: "https://zh.wikipedia.org/w/index.php?search={query}")
        ]
        snippets = []
        autoExpandSnippets = true
        snippetInjection = "type"
        defaultEngineKeyword = "g"
    }

    /// Folders handed to `mdfind -onlyin`: the home directory (unless disabled) plus the
    /// configured extras, with anything already covered by a parent scope dropped so the
    /// index is not asked for the same tree twice.
    var effectiveSearchFolders: [String] {
        var folders = searchFolders
        if searchHomeFolder { folders.insert("~", at: 0) }
        var kept: [String] = []
        for folder in folders.map({ $0.expandedPath }) {
            let covered = kept.contains { folder == $0 || folder.hasPrefix($0 + "/") }
            if !covered { kept.append(folder) }
        }
        return kept
    }

    /// Every field is optional on disk: a partial config keeps defaults for the rest.
    /// Unknown keys (for example the retired maxFileDepth) are ignored.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Config()
        searchFolders = (try? container.decode([String].self, forKey: .searchFolders)) ?? fallback.searchFolders
        searchHomeFolder = (try? container.decode(Bool.self, forKey: .searchHomeFolder)) ?? fallback.searchHomeFolder
        maxResults = (try? container.decode(Int.self, forKey: .maxResults)) ?? fallback.maxResults
        hotKey = (try? container.decode(String.self, forKey: .hotKey)) ?? fallback.hotKey
        showInDock = (try? container.decode(Bool.self, forKey: .showInDock)) ?? fallback.showInDock
        engines = (try? container.decode([SearchEngine].self, forKey: .engines)) ?? fallback.engines
        snippets = (try? container.decode([Snippet].self, forKey: .snippets)) ?? fallback.snippets
        autoExpandSnippets = (try? container.decode(Bool.self, forKey: .autoExpandSnippets)) ?? fallback.autoExpandSnippets
        snippetInjection = (try? container.decode(String.self, forKey: .snippetInjection)) ?? fallback.snippetInjection
        stockWatchlist = (try? container.decode([String].self, forKey: .stockWatchlist)) ?? fallback.stockWatchlist
        defaultEngineKeyword = (try? container.decode(String.self, forKey: .defaultEngineKeyword)) ?? fallback.defaultEngineKeyword
    }

    // MARK: - watchlist

    /// Read-modify-write against the config file, then mirror immediately.
    ///
    /// The watchlist cannot be updated by rewriting an in-memory copy of the whole config:
    /// that copy goes stale (the palette holds a snapshot, and the iCloud reconcile can
    /// replace it mid-session), so each add silently dropped the previous entries — measured
    /// as every add logging "now 1" and the file ending up with a single symbol.
    @discardableResult
    static func setWatched(_ symbol: String, watched: Bool) -> [String] {
        var fresh = load()
        if watched {
            if !fresh.isWatched(symbol) { fresh.stockWatchlist.append(symbol) }
        } else {
            fresh.stockWatchlist.removeAll { $0.lowercased() == symbol.lowercased() }
        }
        write(fresh, to: AppPaths.localConfigURL)
        mirrorToShared(fresh, synchronous: true)
        return fresh.stockWatchlist
    }

    static func watchlist() -> [String] { load().stockWatchlist }

    /// Same read-modify-write discipline as the watchlist: an engine edit must not be applied
    /// by rewriting a possibly stale in-memory copy of the whole config.
    @discardableResult
    static func setEngine(keyword: String, name: String, urlTemplate: String) -> [SearchEngine] {
        var fresh = load()
        let engine = SearchEngine(keyword: keyword, name: name, urlTemplate: urlTemplate)
        if let index = fresh.engines.firstIndex(where: { $0.keyword.lowercased() == keyword.lowercased() }) {
            fresh.engines[index] = engine
        } else {
            fresh.engines.append(engine)
        }
        write(fresh, to: AppPaths.localConfigURL)
        mirrorToShared(fresh, synchronous: true)
        return fresh.engines
    }

    func isWatched(_ symbol: String) -> Bool {
        stockWatchlist.contains { $0.lowercased() == symbol.lowercased() }
    }

    /// Adds or removes a symbol and writes the config back, so the watchlist follows the
    /// same iCloud-synced path as snippets.
    @discardableResult
    mutating func toggleWatched(_ symbol: String) -> Bool {
        if let index = stockWatchlist.firstIndex(where: { $0.lowercased() == symbol.lowercased() }) {
            stockWatchlist.remove(at: index)
        } else {
            stockWatchlist.append(symbol)
        }
        return isWatched(symbol)
    }

    func jsonData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(self)
    }

    // MARK: - local (startup path)

    /// Loads the local config, creating it on first run. Never touches iCloud.
    /// Engine URLs that are known to be broken. INSPIRE's `/search?q=` redirects to
    /// `/literature?q=` and **drops the query string**, so the page looked like a wrong result
    /// set rather than an empty search (measured by following the redirect).
    private static let brokenEngineURLs: [String: String] = [
        "https://inspirehep.net/search?q={query}": "https://inspirehep.net/literature?q={query}"
    ]

    /// Repairs known-broken defaults, so the fix reaches machines that already have the old
    /// URL in their config instead of only fresh installs.
    private static func migrate(_ config: Config) -> Config {
        var updated = config
        var changed = false
        for index in updated.engines.indices {
            let template = updated.engines[index].urlTemplate
            if let replacement = brokenEngineURLs[template] {
                updated.engines[index].urlTemplate = replacement
                changed = true
                Log.write("migrated engine \(updated.engines[index].keyword): \(template) -> \(replacement)")
            }
        }
        if changed { write(updated, to: AppPaths.localConfigURL) }
        return updated
    }

    static func load() -> Config {
        let local = AppPaths.localConfigURL
        if let data = try? Data(contentsOf: local) {
            do {
                let config = try JSONDecoder().decode(Config.self, from: data)
                Log.write("config loaded from \(local.path)")
                return migrate(config)
            } catch {
                Log.write("config at \(local.path) could not be decoded (\(error)); using defaults")
                return Config()
            }
        }
        let config = bundledDefaults() ?? Config()
        write(config, to: local)
        createdFromDefaults = true
        Log.write("created config at \(local.path) (\(bundledDefaults() != nil ? "bundled" : "built-in") defaults)")
        // Deliberately no mirror here: reconciling decides whether the shared copy should
        // win (a new machine adopting iCloud) or this one should seed it.
        return config
    }

    /// True when this run created the local config because none existed. Used by the
    /// reconciler to prefer the shared copy over freshly written defaults.
    private(set) static var createdFromDefaults = false

    /// `Contents/Resources/default-config.json`, produced by the packaging step: it carries
    /// the snippets, engines and search scope that were configured on the machine this build
    /// came from, so a fresh Mac starts with them instead of an empty list.
    static func bundledDefaults() -> Config? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("default-config.json"),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data) else { return nil }
        return config
    }

    static func write(_ config: Config, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = config.jsonData() else { return }
        do {
            try data.write(to: url)
        } catch {
            Log.write("could not write config to \(url.path): \(error)")
        }
    }

    // MARK: - shared (iCloud, strictly off the startup path)

    /// Shared-config sync is skipped exactly when the local path is isolated but the shared
    /// path is not — that combination is what once let a test config reach the real iCloud
    /// copy. With both paths overridden (a fully isolated test) mirroring is safe and desired;
    /// with neither, it is an ordinary run.
    static var shouldSkipSharedSync: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["MACLAUNCHER_SUPPORT_DIR"] != nil
            && environment["MACLAUNCHER_SHARED_CONFIG"] == nil
    }

    /// `synchronous` is for user-initiated edits (the watchlist): an async mirror can be lost
    /// when the app or a CLI invocation exits immediately afterwards, which was measurable —
    /// the scratch shared file never appeared because `exit(0)` won the race.
    static func mirrorToShared(_ config: Config, synchronous: Bool = false) {
        guard !shouldSkipSharedSync else {
            Log.write("isolated local path without isolated shared path: not mirroring")
            return
        }
        let shared = AppPaths.sharedConfigURL
        if synchronous {
            write(config, to: shared)
            Log.write("config mirrored to \(shared.path) (sync)")
            return
        }
        DispatchQueue.global(qos: .utility).async {
            write(config, to: shared)
            Log.write("config mirrored to \(shared.path)")
        }
    }

    /// Two-way reconciliation by modification time: the **newer** of the local and
    /// shared copies wins and overwrites the other. Runs off the startup path.
    ///
    /// An earlier version adopted the shared copy whenever its bytes differed, which
    /// silently reverted local edits (including the very config that had just been
    /// written). Timestamps make the outcome predictable.
    static func reconcileShared(local: Config, apply: @escaping (Config) -> Void) {
        guard !shouldSkipSharedSync else {
            Log.write("isolated local path without isolated shared path: skipping the iCloud reconcile")
            return
        }
        let shared = AppPaths.sharedConfigURL
        let localURL = AppPaths.localConfigURL
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let localDate = (try? fm.attributesOfItem(atPath: localURL.path))?[.modificationDate] as? Date
            let sharedDate = (try? fm.attributesOfItem(atPath: shared.path))?[.modificationDate] as? Date

            guard let sharedDate = sharedDate else {
                Log.write("no shared config at \(shared.path); mirroring local to it")
                write(local, to: shared)
                return
            }
            guard let sharedData = try? Data(contentsOf: shared),
                  let sharedConfig = try? JSONDecoder().decode(Config.self, from: sharedData) else {
                Log.write("shared config at \(shared.path) is unreadable; keeping local")
                return
            }
            // First run on a new machine: the local file was just created from the bundled
            // defaults, so it is newest by modification time while carrying no user edits.
            // Adopting the shared copy is the only non-destructive choice — mirroring the
            // defaults would silently overwrite whatever the user changed on another Mac.
            if Config.createdFromDefaults {
                write(sharedConfig, to: localURL)
                Log.write("fresh install: adopted the shared config (\(sharedConfig.snippets.count) snippets) "
                          + "instead of overwriting it with bundled defaults")
                DispatchQueue.main.async { apply(sharedConfig) }
                return
            }
            if let localDate = localDate, localDate >= sharedDate {
                // Never mirror a local file that does not parse: a hand-edit with a JSON
                // typo would otherwise overwrite the intact snippets still in iCloud.
                guard let localData = try? Data(contentsOf: localURL),
                      (try? JSONDecoder().decode(Config.self, from: localData)) != nil else {
                    Log.write("local config is newer but does not parse; NOT mirroring to shared")
                    return
                }
                Log.write("local config is newer (local=\(localDate), shared=\(sharedDate)); mirroring local to shared")
                write(local, to: shared)
                return
            }
            write(sharedConfig, to: localURL)
            Log.write("shared config is newer (shared=\(sharedDate)); adopted it (showInDock=\(sharedConfig.showInDock))")
            DispatchQueue.main.async { apply(sharedConfig) }
        }
    }
}
