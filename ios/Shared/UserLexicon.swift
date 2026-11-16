import Foundation

/// What this user types often, counted on the device so their own words
/// rise in the suggestion bar and the pinyin candidates, and words the
/// bundled tables do not know can appear there.
///
/// Only counts of single words and word pairs are kept, never sentences.
/// They live in the keyboard's own storage on this phone and are not sent
/// anywhere.
struct UserLexicon: Codable, Equatable {
    /// Previous word → the word typed after it → times.
    private(set) var followers: [String: [String: Int]] = [:]
    /// English words typed → times.
    private(set) var words: [String: Int] = [:]
    /// Pinyin letters → the text chosen for them → times.
    private(set) var pinyin: [String: [String: Int]] = [:]

    /// Uses before a learned entry is offered ahead of the bundled ones.
    static let minimumUses = 2
    static let defaultsKey = "suggest.userLexicon"
    /// Keys kept per table; rarely used entries are dropped beyond this.
    static let capacity = 1500

    var isEmpty: Bool { followers.isEmpty && words.isEmpty && pinyin.isEmpty }

    static func load(_ defaults: UserDefaults = .standard) -> UserLexicon {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(UserLexicon.self, from: data) else { return UserLexicon() }
        return value
    }
    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    // MARK: Learning

    /// Chinese text was committed after `before`. `letters` is the pinyin it
    /// was typed with, or nil when it came from the suggestion bar.
    mutating func learnChinese(_ text: String, before: String, letters: String? = nil) {
        let characters = Array(text)
        guard (1...8).contains(characters.count), characters.allSatisfy(WordSuggestions.isHan) else { return }
        if let letters { learnPinyin(letters, text: text) }
        // After the word before the cursor, by its last one and two characters.
        let run = Array(before.suffix(2).reversed().prefix(while: WordSuggestions.isHan).reversed())
        for length in stride(from: run.count, through: 1, by: -1) {
            Self.count(&followers, String(run.suffix(length)), text)
        }
        // Inside the word itself: 面团 makes 团 follow 面.
        if (2...4).contains(characters.count) {
            for split in 1...min(2, characters.count - 1) {
                Self.count(&followers, String(characters.prefix(split)), String(characters.dropFirst(split)))
            }
        }
    }

    /// `text` was chosen for the pinyin `letters`.
    mutating func learnPinyin(_ letters: String, text: String) {
        guard !letters.isEmpty, letters.count <= 40, !text.isEmpty, text.count <= 8 else { return }
        Self.count(&pinyin, letters, text)
    }

    /// An English word was just finished at the end of `context`.
    mutating func learnEnglish(endOf context: String) {
        let tail = Array(context.suffix(60))
        let word = String(tail.reversed().prefix(while: Self.isLetter).reversed())
        guard (2...24).contains(word.count) else { return }
        let key = word.lowercased()
        words[key, default: 0] += 1
        if words.count > Self.capacity { words = words.filter { $0.value > 1 } }
        let rest = tail.dropLast(word.count)
        guard rest.last == " " else { return }
        let previous = String(rest.dropLast().reversed().prefix(while: Self.isLetter).reversed())
        if !previous.isEmpty { Self.count(&followers, previous.lowercased(), key) }
    }

    private static func count(_ table: inout [String: [String: Int]], _ key: String, _ value: String) {
        table[key, default: [:]][value, default: 0] += 1
        guard table.count > Self.capacity else { return }
        // Forget what was only ever typed once.
        table = table.compactMapValues { entry in
            let kept = entry.filter { $0.value > 1 }
            return kept.isEmpty ? nil : kept
        }
    }

    // MARK: Lookup

    private static func ranked(_ entry: [String: Int]?) -> [String] {
        (entry ?? [:]).filter { $0.value >= minimumUses }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map(\.key)
    }

    /// Words this user typed after `word` often, most used first.
    func followers(of word: String) -> [String] { Self.ranked(followers[word]) }

    /// English words this user typed often that start with `prefix`.
    func completions(of prefix: String) -> [String] {
        Self.ranked(words.filter { $0.key.count > prefix.count && $0.key.hasPrefix(prefix) })
    }

    /// Puts what this user chose for exactly these letters before the
    /// engine's own order, adding phrases the engine does not know.
    func rerank(_ candidates: [PinyinCandidate], for letters: String) -> [PinyinCandidate] {
        let learned = Self.ranked(pinyin[letters]).map { PinyinCandidate(text: $0, consumed: letters.count) }
        guard !learned.isEmpty else { return candidates }
        return learned + candidates.filter { !learned.contains($0) }
    }

    private static func isLetter(_ character: Character) -> Bool {
        character.isASCII && character.isLetter
    }
}
