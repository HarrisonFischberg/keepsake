import Foundation

/// Any JSON value, for the parts of a record the screens read loosely (a kind's details).
public enum JSONValue: Codable, Hashable, Sendable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var number: Double? { if case .number(let n) = self { n } else { nil } }
    public var array: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    public subscript(key: String) -> JSONValue? { if case .object(let o) = self { o[key] } else { nil } }
}

public struct SearchResult: Decodable, Sendable {
    public let items: [Save]
    /// The query that matched: the person's, or its correction ("Showing results for …").
    public let query: String
    public let corrected: Bool
}

public struct PlacesView: Decodable, Sendable {
    public struct City: Decodable, Sendable, Hashable { public let city: String; public let items: [Save] }
    public struct StateGroup: Decodable, Sendable, Hashable { public let state: String; public let cities: [City] }
    public struct Waiting: Decodable, Sendable, Hashable {
        public let item: Save
        /// "no place name", "no state" (places.js placeReviewReasons).
        public let reasons: [String]
    }
    public let groups: [StateGroup]
    public let review: [Waiting]
}

/// A place a save can go: a Lifestyle view ("kind:place") or a collection.
public struct Destination: Decodable, Sendable, Hashable, Identifiable {
    public let value: String
    public let label: String
    /// "lifestyle" or "collection".
    public let group: String
    public let kind: String?
    public var id: String { value }
}

/// A save's own screen: the save plus what Chrome's code formats for it.
public struct SaveDetail: Decodable, Sendable {
    public struct Maps: Decodable, Sendable { public let google: String?; public let apple: String? }
    public let item: Save
    /// "Squats 3×12 rest 60s" (kinds.js formatExercise).
    public let exercises: [String]
    public let goals: [GoalView]
    public let maps: Maps?
    /// "25 min" (formatMinutes).
    public let time: String
    /// Where the details came from ("Recipe read by AI"), or nothing.
    public let sourceLabel: String?
    /// The fields your AI provider drafted because the save didn't say them ("ingredients", "steps", "exercises").
    public let drafted: [String]?
}

public struct GoalView: Decodable, Sendable {
    public struct Goal: Decodable, Sendable { public let id: String; public let itemId: String; public let kind: String; public let startsOn: String; public let endsOn: String? }
    public struct Week: Decodable, Sendable, Hashable { public let week: Int; public let count: Int; public let target: Int; public let met: Bool; public let current: Bool; public let past: Bool }
    public struct Progress: Decodable, Sendable {
        public let status: String
        public let summary: String
        public let ring: Double
        public let strip: [Week]?
        public let lastWeekNote: String?
    }
    public let goal: Goal
    public let progress: Progress
}

extension Library {
    func argsJSON(_ args: [Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: args, options: .fragmentsAllowed), as: UTF8.self)
    }

    /// Saves Keepsake wasn't sure where to put (Chrome's Review).
    public func review() async throws -> [Save] { try await prepare(); return try await core.call("views.review", as: [Save].self) }

    /// One Lifestyle view or kind ("place", "recipe", "workout", "video", "article", "media", "book", "product").
    public func saves(ofKind kind: String) async throws -> [Save] { try await prepare(); return try await core.call("views.ofKind", [kind], as: [Save].self) }

    public func saves(inCollection id: String) async throws -> [Save] { try await prepare(); return try await core.call("views.inCollection", [id], as: [Save].self) }

    public func search(_ query: String) async throws -> SearchResult { try await prepare(); return try await core.call("views.search", [query], as: SearchResult.self) }

    public func places() async throws -> PlacesView { try await prepare(); return try await core.call("views.places", as: PlacesView.self) }

    public func detail(_ id: String) async throws -> SaveDetail? {
        try await prepare()
        return try await core.call("views.detail", [id], as: SaveDetail?.self)
    }

    public func goals(for itemId: String) async throws -> [GoalView] { try await prepare(); return try await core.call("views.goals", [itemId], as: [GoalView].self) }

    // MARK: writes

    public func destinations() async throws -> [Destination] { try await prepare(); return try await core.call("views.destinations", as: [Destination].self) }

    /// Puts saves in a Lifestyle view or a collection; returns its name ("Places", "Kitchen").
    @discardableResult
    public func put(_ ids: [String], in destination: String, learn: String = "light") async throws -> String {
        try await prepare()
        return try await core.call("views.put", [ids, destination, learn], as: String.self)
    }

    /// Sends saves to Review, for when you're not sure where they go.
    public func toReview(_ ids: [String]) async throws { try await prepare(); try await core.call("views.toReview", [ids]) }

    /// Undo right after a save: it's removed outright, never reaching the Trash.
    public func undoSave(_ id: String) async throws { try await core.call("views.undoSave", [id]) }

    /// Edits fields by hand; the shared store records them in `userFields` so AI and lookups leave them alone.
    public func update(_ id: String, _ patch: [String: Any]) async throws { try await core.call("store.updateItem", [id, patch]) }

    /// Files saves into a collection and learns from it (Chrome's Move / Review).
    public func move(_ ids: [String], to collectionId: String) async throws { try await core.call("store.moveItems", [ids, collectionId]) }

    /// Creates a collection, or returns the one with that name (case, plural and "&"/"and" differences allowed).
    @discardableResult
    public func createCollection(named name: String) async throws -> SaveCollection {
        struct Created: Decodable { let collection: SaveCollection }
        try await prepare()
        return try await core.call("store.createCollection", [["name": name]], as: Created.self).collection
    }

    /// Renames a collection, changes its keywords (what files saves there) or pins it.
    public func updateCollection(_ id: String, _ patch: [String: Any]) async throws { try await core.call("store.updateCollection", [id, patch]) }

    /// Deletes a collection; its saves go back to Review (Chrome's rule).
    public func deleteCollection(_ id: String) async throws { try await core.call("store.deleteCollection", [id]) }

    /// "3× a week for 4 weeks".
    @discardableResult
    public func createGoal(itemId: String, perWeek: Int, weeks: Int) async throws -> String {
        let g = try await core.call("store.createGoal", [["itemId": itemId, "kind": "frequency", "spec": ["perWeek": perWeek, "weeks": weeks]]]) as? [String: Any]
        return g?["id"] as? String ?? ""
    }

    /// One-tap check-in; returns its id for Undo.
    @discardableResult
    public func checkIn(goalId: String, sets: Int? = nil, reps: Int? = nil, seconds: Int? = nil, note: String? = nil, at: Date? = nil) async throws -> String {
        var result: [String: Any] = [:]
        if let sets { result["sets"] = sets }
        if let reps { result["reps"] = reps }
        if let seconds { result["durationSeconds"] = seconds }
        if let note { result["note"] = note }
        var opts: [String: Any] = [:]
        if let at { opts["at"] = ISO8601DateFormatter.keepsake.string(from: at) }
        let c = try await core.call("store.addCheckin", [goalId, result, opts]) as? [String: Any]
        return c?["id"] as? String ?? ""
    }

    public func undoCheckIn(_ id: String) async throws { try await core.call("store.removeCheckin", [id]) }
}

/// What the widgets read (written by the app to the App Group; the widget never runs the shared code).
public struct WidgetSnapshot: Codable, Sendable {
    public struct Week: Codable, Sendable, Hashable { public let week: Int; public let met: Bool; public let count: Int; public let target: Int; public let current: Bool }
    public struct Goal: Codable, Sendable, Identifiable {
        public let goalId: String
        public let itemId: String
        public let title: String
        public let summary: String
        public let ring: Double
        public let weeks: [Week]
        public var id: String { goalId }
    }
    public struct Latest: Codable, Sendable { public let id: String; public let title: String; public let kind: String; public let fact: String }
    public let at: String
    public let count: Int
    public let goals: [Goal]
    public let latest: Latest?

    public static func url(appGroup: String = "group.com.harrisonfischberg.keepsake") throws -> URL {
        URL(fileURLWithPath: try RecordDatabase.defaultPath(appGroup: appGroup)).deletingLastPathComponent().appendingPathComponent("widgets.json")
    }

    /// The last snapshot the app wrote, if any.
    public static func read() -> WidgetSnapshot? {
        guard let url = try? url(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}

extension Library {
    /// Rewrites the widgets' snapshot. Call after anything that changes what they show.
    @discardableResult
    public func writeWidgetSnapshot() async throws -> WidgetSnapshot {
        try await prepare()
        let json = try await core.callJSON("views.widgetSnapshot")
        let snap = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(json.utf8))
        try Data(json.utf8).write(to: try WidgetSnapshot.url(), options: .atomic)
        return snap
    }
}

public struct ReviewSuggestions: Decodable, Sendable {
    public struct Pick: Decodable, Sendable, Hashable, Identifiable { public let value: String; public let label: String; public let isNew: Bool; public var id: String { value } }
    /// Why Keepsake wasn't sure (the categorizer's reason).
    public let reason: String
    public let picks: [Pick]
}

public struct AIChange: Decodable, Sendable, Identifiable {
    public struct Change: Decodable, Sendable, Hashable { public let field: String; public let from: String?; public let to: String? }
    public let id: String
    public let at: String
    public let itemId: String?
    public let itemTitle: String?
    public let changes: [Change]
    public let reason: String?
    public let undone: Bool
}

/// What Fix with AI did to saves in Review.
public struct AIFixReport: Decodable, Sendable {
    public struct Filed: Decodable, Sendable { public let id: String; public let collection: String }
    public let checked: Int
    public let changed: Int
    public let filed: [Filed]
    public let error: String
    /// The AI change log entries it wrote, for Undo.
    public let logIds: [String]?
}

extension Library {
    /// Runs the after-save work that is turned on (AI tidy, fill-in with AI and Lookups).
    public func finishSaves() async throws { try await prepare(); try await core.call("views.finishSaves") }
    public func fixPlace(_ id: String) async throws -> Save { try await core.call("views.fixPlace", [id], as: Save.self) }
    public func aiLog() async throws -> [AIChange] { try await prepare(); return try await core.call("views.aiLog", as: [AIChange].self) }
    @discardableResult public func undoAI(_ ids: [String]) async throws -> Int { try await core.call("views.undoAi", [ids], as: Int.self) }
    /// Optional AI is on and a key is set.
    public func aiReady() async -> Bool { (try? await core.call("views.aiReady") as? Bool) ?? false }
    /// Chrome's Fix with AI for saves in Review: files the ones the AI is confident about.
    public func fixWithAI(_ ids: [String]) async throws -> AIFixReport { try await prepare(); return try await core.call("views.fixWithAI", [ids], as: AIFixReport.self) }
    public func testAI() async throws { try await core.call("views.testAi") }
    public func suggestions(for id: String) async throws -> ReviewSuggestions { try await core.call("views.suggestions", [id], as: ReviewSuggestions.self) }
    /// Files a save from Review and learns from it strongly (Chrome's Review filing).
    @discardableResult public func file(_ id: String, into target: String) async throws -> String { try await core.call("views.file", [id, target], as: String.self) }

    public func settings() async throws -> [String: Any] { try await prepare(); return (try await core.call("store.getSettings") as? [String: Any]) ?? [:] }
    public func updateSettings(_ patch: [String: Any]) async throws { try await core.call("store.updateSettings", [patch]) }
    public func aiKey() async throws -> String { (try await core.call("store.getSecret", ["aiApiKey"]) as? String) ?? "" }
    public func setAIKey(_ key: String) async throws { try await core.call("store.setSecret", ["aiApiKey", key]) }
    /// Erases the whole library on this device (Chrome's Delete all local data).
    public func eraseEverything() async throws {
        try await core.call("store.clearAll")
        try await core.call("store.init")
    }
}
