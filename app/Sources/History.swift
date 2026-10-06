import Foundation

/// Query history for the palette: pressing Up on an empty search field steps back through
/// what was run before, the way Alfred does.
///
/// Kept in its own file next to the config rather than in the config itself: it is runtime
/// state, not configuration, and it is meant to be inspectable and cheap to clear.
final class QueryHistory {
    static let shared = QueryHistory()

    /// Newest first.
    private(set) var entries: [String] = []
    private var cursor: Int?
    private let limit = 50
    private let url = AppPaths.historyURL

    private init() {
        load()
    }

    // MARK: - recording

    /// Called when a row is actually run, so the history holds queries that did something
    /// rather than every prefix typed on the way there.
    func record(_ query: String) {
        let trimmed = query.trimmed()
        cursor = nil
        guard !trimmed.isEmpty else { return }
        entries.removeAll { $0.lowercased() == trimmed.lowercased() }
        entries.insert(trimmed, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        save()
    }

    // MARK: - navigation

    /// Up: step towards older queries. Nil when there is nothing to recall **or the oldest
    /// entry is already showing** — without that second case the caller can never tell that
    /// history is exhausted, and a loop over this call never terminates (measured: it hung).
    func stepBack() -> String? {
        guard !entries.isEmpty else { return nil }
        if let current = cursor, current >= entries.count - 1 { return nil }
        let next = min((cursor ?? -1) + 1, entries.count - 1)
        cursor = next
        return entries[next]
    }

    /// Down: step towards newer queries; an empty string means "back to an empty field".
    func stepForward() -> String {
        guard let current = cursor else { return "" }
        if current <= 0 {
            cursor = nil
            return ""
        }
        cursor = current - 1
        return entries[current - 1]
    }

    var isBrowsing: Bool { cursor != nil }

    func stopBrowsing() {
        cursor = nil
    }

    /// Used by the footer hint.
    var hasEntries: Bool { !entries.isEmpty }

    func clear() {
        entries = []
        cursor = nil
        save()
    }

    // MARK: - persistence

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
        entries = Array(decoded.prefix(limit))
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }
}
