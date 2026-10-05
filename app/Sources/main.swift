import AppKit

// Command line surface (used for objective testing and for scripting):
//   MacLauncher --selftest          index apps, exercise Spotlight search, exit
//   MacLauncher --query "saf"       print ranked rows for a query, exit
//   MacLauncher --apps              print every indexed application, exit
//   MacLauncher                     run the launcher

let arguments = CommandLine.arguments

if arguments.contains("--apps") {
    runAppList()
    exit(0)
}

if let index = arguments.firstIndex(of: "--quit"), index + 1 < arguments.count {
    runQuit(arguments[index + 1])
    exit(0)
}

if arguments.contains("--scopes") {
    let config = Config.load()
    print("# searchHomeFolder=\(config.searchHomeFolder) configured=\(config.searchFolders)")
    for folder in config.effectiveSearchFolders {
        let exists = FileManager.default.fileExists(atPath: folder) ? "ok" : "MISSING"
        print("\(folder)\t\(exists)")
    }
    exit(0)
}

if arguments.contains("--reconcile-test") {
    let config = Config.load()
    print("# local before: snippets=\(config.snippets.count) hotKey=\(config.hotKey) showInDock=\(config.showInDock)")
    let semaphore = DispatchSemaphore(value: 0)
    Config.reconcileShared(local: config) { _ in semaphore.signal() }
    _ = semaphore.wait(timeout: .now() + 6)
    let after = Config.load()
    print("# local after : snippets=\(after.snippets.count) hotKey=\(after.hotKey) showInDock=\(after.showInDock)")
    let sharedURL = AppPaths.sharedConfigURL
    if let data = try? Data(contentsOf: sharedURL),
       let decoded = try? JSONDecoder().decode(Config.self, from: data) {
        print("# shared      : snippets=\(decoded.snippets.count) hotKey=\(decoded.hotKey)")
    } else {
        print("# shared      : (none)")
    }
    exit(0)
}

if arguments.contains("--hotkey-test") {
    let samples = ["option+space", "ctrl+option+space", "cmd+shift+k", "ctrl+space", "cmd+space",
                   "f5", "shift+f5", "cmd+shift+p", "a", "cmd+spacebar", "ctrl+alt+delete",
                   "cmd+shift+3", "option+`", "ctrl+shift+left"]
    for spec in samples {
        if let parsed = HotKey.parse(spec: spec) {
            let canonical = HotKey.describe(keyCode: parsed.keyCode, modifiers: parsed.modifiers)
            let warning = HotKey.conflictWarning(spec: spec).map { "  ⚠️ \($0)" } ?? ""
            print("\(spec.padding(toLength: 22, withPad: " ", startingAt: 0)) ok  key=\(parsed.keyCode)\tdisplay=\(HotKey.display(spec: spec))\tcanonical=\(canonical)\(warning)")
        } else {
            print("\(spec.padding(toLength: 22, withPad: " ", startingAt: 0)) REJECTED (needs a modifier and a known key)")
        }
    }
    exit(0)
}

if let index = arguments.firstIndex(of: "--expand-test"), index + 1 < arguments.count {
    runExpandTest(arguments[index + 1])
    exit(0)
}

if let index = arguments.firstIndex(of: "--type-test"), index + 1 < arguments.count {
    runTypeTest(arguments[index + 1])
    exit(0)
}

/// Measures the two ways of injecting text into the frontmost application, because event
/// posting turned out to cost ~10 ms per call and the count of calls dominates latency.
func runTypeTest(_ sample: String) {
    guard Paster.isTrusted else {
        print("Accessibility permission is not granted")
        exit(3)
    }
    print("sample=\"\(sample)\" utf16=\(sample.utf16.count)")

    var started = Date()
    Paster.typeTextInPlace(sample)
    print("per-character: \(Int(Date().timeIntervalSince(started) * 1000))ms (\(sample.utf16.count * 2) posts)")

    usleep(400_000)
    started = Date()
    Paster.postWholeString(sample)
    print("whole-string : \(Int(Date().timeIntervalSince(started) * 1000))ms (2 posts)")
}

if let index = arguments.firstIndex(of: "--caret-test"), index + 1 < arguments.count {
    let delay = (index + 2 < arguments.count) ? Double(arguments[index + 2]) ?? 120 : 120
    let arrows = !arguments.contains("--no-arrows")
    runCaretTest(arguments[index + 1], delayMs: delay, arrows: arrows)
    exit(0)
}

if arguments.contains("--selftest") {
    runSelfTest()
    exit(0)
}

if let index = arguments.firstIndex(of: "--query"), index + 1 < arguments.count {
    runQuery(arguments[index + 1])
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()

// MARK: - command line helpers

func makeAppIndex(config: Config) -> Indexer {
    let indexer = Indexer()
    indexer.buildApps()
    indexer.updateSnippets(config.snippets)
    return indexer
}

/// Exercises exactly the same resolution path the palette uses in quit mode, so the
/// quit behaviour can be verified without driving the GUI.
func runQuit(_ query: String) {
    let config = Config.load()
    let indexer = makeAppIndex(config: Config.load())
    let candidates = indexer.searchApps(rawQuery: "q \(query)", config: config)
    guard let item = candidates.first, let app = item.running else {
        print("no running application matches \"\(query)\"")
        exit(2)
    }
    print("quitting \(item.title) [\(item.bundleIdentifier ?? "?")] pid=\(app.processIdentifier)")
    if !app.terminate() {
        print("terminate() was refused (the app may have unsaved changes)")
        exit(3)
    }
    // `NSRunningApplication.isTerminated` lags behind reality, so probe the process.
    let pid = app.processIdentifier
    for _ in 0..<30 {
        if !isProcessAlive(pid) { break }
        usleep(100_000)
    }
    let gone = !isProcessAlive(pid)
    print(gone ? "terminated" : "still running after 3s")
    exit(gone ? 0 : 4)
}

/// Feeds a sample string through the same matching rule the live expander uses, so the
/// expansion logic can be verified without typing into a real application.
func runExpandTest(_ sample: String) {
    let config = Config.load()
    let expandable = SnippetExpander.expandable(config.snippets)
    print("# \(config.snippets.count) snippets, \(expandable.count) auto-expandable")
    for snippet in config.snippets {
        let auto = expandable.contains { $0.keyword == snippet.keyword }
        print("  \(snippet.keyword)  [\(auto ? "auto-expand" : "palette-only")]  \(snippet.name)")
    }
    var buffer = ""
    var hits: [String] = []
    for character in sample {
        if character == "\n" {
            buffer = ""
            continue
        }
        buffer.append(character)
        if let match = SnippetExpander.match(snippets: config.snippets, buffer: buffer) {
            let (text, backoff) = Snippet.cursorSplit(match.content)
            let rendered = text.replacingOccurrences(of: "\n", with: "\\n")
            let caret = backoff > 0 ? " + 光标回退 \(backoff)" : ""
            hits.append("\(buffer) => \(match.keyword) [\(rendered)]\(caret)")
            buffer = ""
        }
    }
    print("# fed \"\(sample)\" -> \(hits.isEmpty ? "no expansion" : hits.joined(separator: ", "))")
}

/// Runs only the injection half of an expansion against the frontmost application.
/// The keystroke monitor cannot be driven by synthetic input, so this is how the caret
/// placement gets measured against a target that reports its own insertion point.
func runCaretTest(_ keyword: String, delayMs: Double, arrows: Bool) {
    let config = Config.load()
    guard let snippet = config.snippets.first(where: { $0.keyword == keyword }) else {
        print("no snippet with keyword \"\(keyword)\"")
        exit(2)
    }
    guard Paster.isTrusted else {
        print("Accessibility permission is not granted")
        exit(3)
    }
    let (text, backoff) = Snippet.cursorSplit(snippet.content)
    print("keyword=\(keyword) delete=\(snippet.keyword.count) paste=\"\(text)\" backoff=\(backoff) delay=\(Int(delayMs))ms arrows=\(arrows)")

    Paster.postBackspaces(count: snippet.keyword.count)
    usleep(60_000)
    Paster.pasteInPlace(text)
    if arrows, backoff > 0 {
        usleep(useconds_t(delayMs * 1000))
        Paster.postLeftArrows(count: backoff)
    }
    usleep(300_000)
    print("done")
}

func isProcessAlive(_ pid: pid_t) -> Bool {
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
}

/// Blocking Spotlight search, for the command line tools only.
func spotlightPaths(query: String, config: Config, deadline: TimeInterval = 8) -> (paths: [String], ms: Int) {
    let trimmed = Indexer.parse(query).query
    guard !trimmed.isEmpty else { return ([], 0) }
    let started = Date()
    let semaphore = DispatchSemaphore(value: 0)
    var paths: [String] = []
    SpotlightSearcher().search(query: trimmed,
                               folders: config.effectiveSearchFolders,
                               limit: Indexer.fileCandidateLimit,
                               deadline: deadline) { result in
        paths = result
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + deadline + 2)
    return (paths, Int(Date().timeIntervalSince(started) * 1000))
}

func runAppList() {
    let indexer = makeAppIndex(config: Config.load())
    print("# \(indexer.apps.count) apps")
    for item in indexer.apps {
        print("\(item.running != nil ? "R" : "-")\t\(item.title)\t\(item.path)")
    }
}

func runQuery(_ query: String) {
    let config = Config.load()
    let indexer = makeAppIndex(config: Config.load())
    let apps = indexer.searchApps(rawQuery: query, config: config)
    let spotlight = spotlightPaths(query: query, config: config)
    let merged = indexer.merge(rawQuery: query,
                               apps: apps,
                               filePaths: spotlight.paths,
                               config: config)
    print("# query \"\(query)\" -> \(merged.count) rows  (apps indexed=\(indexer.apps.count), app hits=\(apps.count), spotlight hits=\(spotlight.paths.count) in \(spotlight.ms)ms)")
    for result in merged {
        print("\(result.kind.rawValue)\t\(result.title)\t\(result.path)")
    }
}

func runSelfTest() {
    let config = Config.load()
    Log.write("--- selftest ---")
    Log.write("local config: \(AppPaths.localConfigURL.path)")
    Log.write("shared config: \(AppPaths.sharedConfigURL.path)")
    Log.write("search folders: \(config.searchFolders.joined(separator: ", "))")

    if let parsed = HotKey.parse(spec: config.hotKey) {
        Log.write("hotkey spec: \(config.hotKey) -> keyCode=\(parsed.keyCode) modifiers=\(parsed.modifiers) [\(HotKey.describe(keyCode: parsed.keyCode, modifiers: parsed.modifiers))]")
    } else {
        Log.write("hotkey spec not understood: \(config.hotKey)")
    }
    let registered = HotKeyManager.shared.register(spec: config.hotKey) {}
    Log.write("hotkey registration from selftest: \(registered ? "OK" : "FAILED")")

    let indexer = makeAppIndex(config: Config.load())
    Log.write("apps indexed: \(indexer.apps.count)")

    for query in ["saf", "term", "xcode", "christoffel", "readme", "q ", "q term"] {
        let started = Date()
        let apps = indexer.searchApps(rawQuery: query, config: config)
        let appMs = Int(Date().timeIntervalSince(started) * 1000)
        let spotlight = spotlightPaths(query: query, config: config)
        let merged = indexer.merge(rawQuery: query,
                                   apps: apps,
                                   filePaths: spotlight.paths,
                                   config: config)
        let summary = merged.prefix(5).map { "\($0.title)[\($0.kind.rawValue)]" }.joined(separator: " | ")
        Log.write("query \"\(query)\": appHits=\(apps.count) in \(appMs)ms, spotlightHits=\(spotlight.paths.count) in \(spotlight.ms)ms -> \(merged.count) rows :: \(summary)")
    }
    Log.write("--- selftest done ---")
}
