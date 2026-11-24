import Foundation

/// What the keyboard adds after each voice result so the next sentence
/// starts on its own line.
enum AutoNewlineMode: String, CaseIterable {
    /// Nothing is added.
    case off
    /// U+2028 LINE SEPARATOR: shows as a new line but is not "\n", so chat
    /// apps that send on Return keep the text in the box (Shift+Return feel).
    case soft
    /// A plain "\n", the same as the Return key. Some chat apps send on it.
    case hard

    static let defaultsKey = "voice.autoNewline"

    static func load(_ defaults: UserDefaults = .standard) -> AutoNewlineMode {
        defaults.string(forKey: defaultsKey).flatMap(AutoNewlineMode.init(rawValue:)) ?? .soft
    }
    func save(_ defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.defaultsKey) }

    var separator: String {
        switch self {
        case .off: return ""
        case .soft: return "\u{2028}"
        case .hard: return "\n"
        }
    }
    var next: AutoNewlineMode {
        switch self {
        case .off: return .soft
        case .soft: return .hard
        case .hard: return .off
        }
    }
    var hint: String {
        switch self {
        case .off: return "自动换行：关"
        case .soft: return "自动换行：开（软换行，不会触发发送）"
        case .hard: return "自动换行：开（普通换行，个别聊天 App 会发送）"
        }
    }

    /// Text inserted for one voice result. No separator is added after text
    /// that already ends a line (for example a spoken "换行" command).
    func apply(to text: String) -> String {
        guard self != .off, !text.isEmpty, let last = text.last,
              !last.isNewline else { return text }
        return text + separator
    }
}

/// Remembers the last voice insert so one tap can remove exactly that text,
/// and only while the cursor is still right after it in the same field.
struct VoiceUndoRecord {
    private(set) var text: String?
    private(set) var documentID: UUID?

    mutating func record(_ inserted: String, documentID: UUID) {
        text = inserted.isEmpty ? nil : inserted; self.documentID = documentID
    }
    mutating func clear() { text = nil; documentID = nil }
    var isAvailable: Bool { text != nil }

    /// Number of backward deletes needed, or nil if undo is no longer safe:
    /// a different field, or the text before the cursor is not the insert.
    /// Hosts may return only a window of text before the cursor, so a long
    /// insert is matched by its tail.
    func deletions(documentID current: UUID, textBeforeCursor before: String?) -> Int? {
        guard let text = text, documentID == current else { return nil }
        let before = before ?? ""
        // Some hosts only report the current line, which is empty right after
        // an auto newline. Accept that one case: the insert ended a line.
        if before.isEmpty { return text.last?.isNewline == true ? text.count : nil }
        let matches = before.count >= text.count ? before.hasSuffix(text) : text.hasSuffix(before)
        return matches ? text.count : nil
    }
}

/// Lets the keyboard hand off to Lab to refresh a lapsed voice session, then
/// start the recording the user asked for once they come back.
enum VoiceSessionRenewal {
    /// Opened by the keyboard. Lab starts or extends the session to 60 minutes.
    static let url = URL(string: "capswriterlab://renew")!
    static func url(returningTo bundleID: String?, probe: String? = nil) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items: [URLQueryItem] = []
        if let bundleID { items.append(URLQueryItem(name: "return", value: bundleID)) }
        if let probe, isSafeToken(probe) { items.append(URLQueryItem(name: "kd", value: probe)) }
        guard !items.isEmpty else { return url }
        parts.queryItems = items
        return parts.url ?? url
    }
    private static func isSafeToken(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 200
            && value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" })
    }
    private static func query(_ name: String, in url: URL) -> String? {
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == name })?.value
        guard let value, isSafeToken(value) else { return nil }
        return value
    }
    /// The app to send the user back to, if the keyboard could tell.
    static func returnBundleID(from url: URL) -> String? { query("return", in: url) }
    /// The keyboard's privacy-free host probe code, shown in Lab's diagnostics.
    static func probeCode(from url: URL) -> String? { query("kd", in: url) }
    static let minutes = 60
    /// A return to the keyboard within this window still counts as the same tap.
    static let resumeWindow: TimeInterval = 120
    static let pendingKey = "voice.renewRequestedAt"
}
