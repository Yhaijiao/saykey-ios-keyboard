import Foundation

struct WordSuggestion: Equatable {
    /// What the suggestion bar shows.
    let text: String
    /// Characters before the cursor that the suggestion replaces: the part of
    /// an English word typed so far, or 0 for a next-word suggestion.
    let replacing: Int
    /// What is inserted when the suggestion is tapped.
    let insertion: String
}

/// Offline word suggestions from bundled public frequency tables: the next
/// word after the text before the cursor (Chinese and English), and
/// completions of an English word that is being typed. These tables never
/// change; what the user types often is counted in `UserLexicon`.
final class WordSuggestions {
    enum Language { case english, chinese }

    static let chineseStarters = ["我", "你", "这", "在", "好", "不", "那", "他"]
    static let englishStarters = ["I", "The", "It", "This", "We", "You"]

    private let chinese: [String: [String]]
    private let english: [String: [String]]
    /// English words by first letter, most frequent first.
    private var words: [UInt8: [String]] = [:]
    /// The first two or three characters of an idiom -> the rest of it,
    /// most used idioms first: 画蛇 -> 添足.
    private var idiomEndings: [String: [String]] = [:]
    /// A xiehouyu riddle -> its answer: 外甥打灯笼 -> 照旧（舅）.
    private var riddles: [String: String] = [:]
    /// The first four characters of a longer riddle -> the rest of it.
    private var riddleEndings: [String: [String]] = [:]

    init(chinese: [String: [String]], english: [String: [String]], words: [String],
         idioms: [String] = [], xiehouyu: [(riddle: String, answer: String)] = []) {
        self.chinese = chinese; self.english = english
        for word in words {
            if let first = word.utf8.first { self.words[first, default: []].append(word) }
        }
        for idiom in idioms {
            let characters = Array(idiom)
            for cut in [2, 3] where cut < characters.count {
                let key = String(characters[..<cut])
                if idiomEndings[key, default: []].count < 4 { idiomEndings[key, default: []].append(String(characters[cut...])) }
            }
        }
        for (riddle, answer) in xiehouyu where riddles[riddle] == nil {
            riddles[riddle] = answer
            let characters = Array(riddle)
            if characters.count > 4 {
                let key = String(characters[..<4])
                if riddleEndings[key, default: []].count < 2 { riddleEndings[key, default: []].append(String(characters[4...])) }
            }
        }
    }

    /// One "riddle<TAB>answer" per line.
    static func parseRiddles(_ text: String) -> [(riddle: String, answer: String)] {
        text.split(separator: "\n").compactMap { line in
            guard let tab = line.firstIndex(of: "\t") else { return nil }
            return (String(line[..<tab]), String(line[line.index(after: tab)...]))
        }
    }

    /// One entry per line: the previous word, a tab, then its followers
    /// separated by spaces, most likely first.
    static func parseTable(_ text: String) -> [String: [String]] {
        var table: [String: [String]] = [:]
        for line in text.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let followers = line[line.index(after: tab)...].split(separator: " ").map(String.init)
            if !followers.isEmpty { table[String(line[..<tab])] = followers }
        }
        return table
    }

    static func bundled() -> WordSuggestions {
        func text(_ name: String) -> String {
            guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
                  let data = try? Data(contentsOf: url) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        return WordSuggestions(chinese: parseTable(text("suggest-zh")), english: parseTable(text("suggest-en")),
                               words: text("suggest-en-words").split(separator: "\n").map(String.init),
                               idioms: text("suggest-idioms").split(separator: "\n").map(String.init),
                               xiehouyu: parseRiddles(text("suggest-xiehouyu")))
    }

    /// Suggestions for the text before the cursor. `language` is the page in
    /// use; it decides what an empty field offers and whether a half-typed
    /// English word is completed (on the pinyin page letters are pinyin).
    /// `user` holds this user's own counts: their frequent words come first
    /// and may be words the bundled tables do not have.
    func suggestions(before context: String, language: Language, limit: Int = 8,
                     user: UserLexicon? = nil) -> [WordSuggestion] {
        let tail = Array(context.suffix(40))
        guard let last = tail.last else { return starters(language, limit) }
        if Self.isHan(last) {
            let run = Array(tail.reversed().prefix(4).prefix(while: Self.isHan).reversed())
            var found: [String] = []
            if let user {
                for length in stride(from: run.count, through: 1, by: -1) {
                    for follower in user.followers(of: String(run.suffix(length))) where !found.contains(follower) {
                        found.append(follower)
                    }
                }
            }
            let learned = found.count
            // The longest known word ending at the cursor decides; shorter
            // endings only fill the bar when that word has few followers.
            for length in stride(from: run.count, through: 1, by: -1) {
                for follower in chinese[String(run.suffix(length))] ?? [] where !found.contains(follower) {
                    found.append(follower)
                }
                if found.count - learned >= 3 { break }
            }
            found = sayings(after: tail, run: run, before: found)
            return found.prefix(limit).map { WordSuggestion(text: $0, replacing: 0, insertion: $0) }
        }
        if Self.isLetter(last) {
            guard language == .english else { return [] }
            let typed = String(tail.reversed().prefix(while: Self.isLetter).reversed())
            guard typed.count <= 24 else { return [] }
            let lower = typed.lowercased()
            var matches = user?.completions(of: lower) ?? []
            for word in words[lower.utf8.first ?? 0] ?? []
            where word.utf8.count > lower.utf8.count && word.utf8.starts(with: lower.utf8) {
                if matches.count >= limit { break }
                if !matches.contains(word) { matches.append(word) }
            }
            return matches.prefix(limit).map { word -> WordSuggestion in
                let shown = Self.styled(word, like: typed)
                return WordSuggestion(text: shown, replacing: typed.count, insertion: shown + " ")
            }
        }
        if last == " " {
            let before = tail.dropLast()
            guard let previous = before.last else { return starters(language, limit) }
            if Self.isLetter(previous) {
                let word = String(before.reversed().prefix(while: Self.isLetter).reversed()).lowercased()
                var followers = user?.followers(of: word) ?? []
                for follower in english[word] ?? [] where !followers.contains(follower) { followers.append(follower) }
                return followers.prefix(limit).map { follower -> WordSuggestion in
                    let shown = follower == "i" ? "I" : follower
                    return WordSuggestion(text: shown, replacing: 0, insertion: shown + " ")
                }
            }
            return ".!?".contains(previous) ? starters(.english, limit) : []
        }
        if last.isNewline { return starters(language, limit) }
        return "。！？，、；：…".contains(last) ? starters(.chinese, limit) : []
    }

    /// Puts idiom and xiehouyu endings among the next words. A finished
    /// riddle or three characters of an idiom are clear signals and lead;
    /// two characters that are also an everyday word ("一个") only add
    /// their idioms after the first few ordinary next words.
    private func sayings(after tail: [Character], run: [Character], before found: [String]) -> [String] {
        var leading: [String] = [], later: [String] = []
        for length in stride(from: min(tail.count, 10), through: 4, by: -1) {
            if let answer = riddles[String(tail.suffix(length))] { leading.append("——" + answer); break }
        }
        if run.count >= 4 { leading += riddleEndings[String(run.suffix(4))] ?? [] }
        if run.count >= 3 { leading += idiomEndings[String(run.suffix(3))] ?? [] }
        if run.count >= 2 {
            let key = String(run.suffix(2))
            if chinese[key] == nil { leading += (idiomEndings[key] ?? []).prefix(3) }
            else { later += (idiomEndings[key] ?? []).prefix(2) }
        }
        var result: [String] = []
        for item in leading where !result.contains(item) { result.append(item) }
        for item in found.prefix(3) where !result.contains(item) { result.append(item) }
        for item in later where !result.contains(item) { result.append(item) }
        for item in found.dropFirst(3) where !result.contains(item) { result.append(item) }
        return result
    }

    private func starters(_ language: Language, _ limit: Int) -> [WordSuggestion] {
        switch language {
        case .chinese:
            return Self.chineseStarters.prefix(limit).map { WordSuggestion(text: $0, replacing: 0, insertion: $0) }
        case .english:
            return Self.englishStarters.prefix(limit).map { WordSuggestion(text: $0, replacing: 0, insertion: $0 + " ") }
        }
    }

    /// Keeps the capitals the user already typed: "Hel" offers "Hello".
    private static func styled(_ word: String, like typed: String) -> String {
        if word == "i" { return "I" }
        if typed.count > 1 && typed == typed.uppercased() { return word.uppercased() }
        if let first = typed.first, first.isUppercase { return word.prefix(1).uppercased() + word.dropFirst() }
        return word
    }
    static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) }
    }
    private static func isLetter(_ character: Character) -> Bool {
        character.isASCII && character.isLetter
    }
}
