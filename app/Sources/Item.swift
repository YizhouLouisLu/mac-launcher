import AppKit

enum ItemKind: String {
    case runningApp = "app(running)"
    case application = "app"
    case file = "file"
    case folder = "folder"
    case snippet = "snippet"
    case command = "command"
    case webSearch = "web"
}

/// One searchable row.
///
/// `searchTitle`, `pathLower` and the initials are precomputed at index time so that
/// a keystroke never lowercases tens of thousands of strings.
///
/// `alternateTitles` exist because a bundle has several names: the file name
/// ("Finder") and the localised display name ("访达"). Which one macOS hands back
/// depends on the API, so both are indexed and either can be typed. Snippets use the
/// same slot for their keyword.
struct Item {
    let title: String
    let subtitle: String
    let path: String
    let kind: ItemKind
    let bundleIdentifier: String?
    let running: NSRunningApplication?
    /// Set for `.snippet` rows: the text that gets pasted into the frontmost app.
    let snippetContent: String?
    /// Set for `.command` rows: the built-in action the palette should run.
    let command: String?
    /// Set for `.webSearch` rows: the URL to open in the default browser.
    let url: String?
    /// File rows only: a small bonus so a shallower path wins a tie against a deep copy of
    /// the same name, and so equal scores still have a deterministic order.
    let pathDepthBonus: Int

    let searchTitle: String
    let pathLower: String
    let initialsLower: String

    let alternateTitles: [String]
    let alternateSearchTitles: [String]
    let alternateInitialsLowers: [String]

    init(title: String,
         subtitle: String,
         path: String,
         kind: ItemKind,
         bundleIdentifier: String? = nil,
         running: NSRunningApplication? = nil,
         alternateTitles: [String] = [],
         snippetContent: String? = nil,
         command: String? = nil,
         url: String? = nil,
         pathDepthBonus: Int = 0) {
        self.title = title
        self.subtitle = subtitle
        self.path = path
        self.kind = kind
        self.bundleIdentifier = bundleIdentifier
        self.running = running
        self.snippetContent = snippetContent
        self.command = command
        self.url = url
        self.pathDepthBonus = pathDepthBonus

        self.searchTitle = title.lowercased()
        self.pathLower = path.lowercased()
        self.initialsLower = Ranking.initials(of: title).lowercased()

        let normalized = Item.normalize(alternateTitles, excluding: title)
        self.alternateTitles = normalized
        self.alternateSearchTitles = normalized.map { $0.lowercased() }
        self.alternateInitialsLowers = normalized.map { Ranking.initials(of: $0).lowercased() }
    }

    var canQuit: Bool { running != nil }

    func markedRunning(_ app: NSRunningApplication) -> Item {
        var alternates = alternateTitles
        if let localized = app.localizedName { alternates.append(localized) }
        return Item(title: title,
                    subtitle: subtitle,
                    path: path,
                    kind: .runningApp,
                    bundleIdentifier: app.bundleIdentifier,
                    running: app,
                    alternateTitles: alternates,
                    snippetContent: snippetContent,
                    command: command,
                    url: url,
                    pathDepthBonus: pathDepthBonus)
    }

    /// Live running state is re-overlaid on every palette show, so the same item has to
    /// be able to go back to "not running" without losing its aliases.
    func unmarkedRunning() -> Item {
        Item(title: title,
             subtitle: subtitle,
             path: path,
             kind: .application,
             bundleIdentifier: bundleIdentifier,
             running: nil,
             alternateTitles: alternateTitles,
             snippetContent: snippetContent,
             command: command,
             url: url,
             pathDepthBonus: pathDepthBonus)
    }

    private static func normalize(_ candidates: [String], excluding title: String) -> [String] {
        var seen: Set<String> = [title.lowercased()]
        var result: [String] = []
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            result.append(trimmed)
        }
        return result
    }
}
