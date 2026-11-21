import XCTest

final class WordSuggestionsTests: XCTestCase {
    private let engine = WordSuggestions(
        chinese: WordSuggestions.parseTable("我\t们 的 想\n我们\t可以 要\n天\t气\n今天\t下午 晚上 我们\n一天\t内\n"),
        english: WordSuggestions.parseTable("thank\tyou the\nyou\tare can i\n"),
        words: ["the", "hello", "help", "held", "i", "in"])

    private func texts(_ context: String, _ language: WordSuggestions.Language) -> [String] {
        engine.suggestions(before: context, language: language).map { $0.text }
    }

    func testChineseFollowsTheLongestKnownWord() {
        XCTAssertEqual(texts("我", .chinese), ["们", "的", "想"])
        XCTAssertEqual(texts("今天", .chinese), ["下午", "晚上", "我们"], "今天 wins over 天")
        XCTAssertEqual(texts("明天我们", .chinese), ["可以", "要"])
        XCTAssertEqual(texts("一天", .chinese), ["内", "气"], "A short list is topped up from the shorter ending")
        XCTAssertEqual(texts("hello 我", .english), ["们", "的", "想"], "Chinese text is continued on the English page too")
        XCTAssertEqual(texts("囧", .chinese), [])
        let pick = engine.suggestions(before: "我", language: .chinese)[0]
        XCTAssertEqual(pick, WordSuggestion(text: "们", replacing: 0, insertion: "们"))
    }

    func testIdiomsAndXiehouyuComplete() {
        let sayings = WordSuggestions(
            chinese: WordSuggestions.parseTable("画蛇\t添足\n外甥打灯笼\t——照旧（舅）\n灯笼\t的\n"),
            english: [:], words: [])
        func texts(_ context: String) -> [String] {
            sayings.suggestions(before: context, language: .chinese).map { $0.text }
        }
        XCTAssertEqual(texts("他这是画蛇"), ["添足"])
        XCTAssertEqual(texts("真是外甥打灯笼"), ["——照旧（舅）", "的"], "The longer saying comes before the word")
        XCTAssertEqual(sayings.suggestions(before: "外甥打灯笼", language: .chinese).first?.insertion, "——照旧（舅）")
    }

    func testEnglishNextWordAddsASpace() {
        XCTAssertEqual(engine.suggestions(before: "Thank ", language: .english).first,
                       WordSuggestion(text: "you", replacing: 0, insertion: "you "))
        XCTAssertEqual(texts("thank you ", .english), ["are", "can", "I"])
        XCTAssertEqual(texts("thank you ", .chinese), ["are", "can", "I"])
        XCTAssertEqual(texts("unknown ", .english), [])
        XCTAssertEqual(texts("12 ", .english), [])
    }

    func testEnglishCompletionReplacesTheTypedLetters() {
        XCTAssertEqual(texts("say hel", .english), ["hello", "help", "held"])
        XCTAssertEqual(engine.suggestions(before: "Hel", language: .english).first,
                       WordSuggestion(text: "Hello", replacing: 3, insertion: "Hello "))
        XCTAssertEqual(texts("HEL", .english).first, "HELLO")
        XCTAssertEqual(texts("hello", .english), [], "A finished word offers no longer word here")
        XCTAssertEqual(texts("hel", .chinese), [], "Letters on the pinyin page are not English words")
        XCTAssertEqual(texts("zzz", .english), [])
    }

    func testStartersAtTheBeginningOfASentence() {
        XCTAssertEqual(texts("", .chinese), WordSuggestions.chineseStarters)
        XCTAssertEqual(texts("", .english), WordSuggestions.englishStarters)
        XCTAssertEqual(texts("好的。", .english), WordSuggestions.chineseStarters)
        XCTAssertEqual(texts("Fine. ", .chinese), WordSuggestions.englishStarters)
        XCTAssertEqual(texts("first line\n", .chinese), WordSuggestions.chineseStarters)
        XCTAssertEqual(engine.suggestions(before: "", language: .english).first?.insertion, "I ")
    }
}
