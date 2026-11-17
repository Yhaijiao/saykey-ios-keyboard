import XCTest

final class UserLexiconTests: XCTestCase {
    private let engine = WordSuggestions(
        chinese: WordSuggestions.parseTable("面\t包 粉 条\n"),
        english: WordSuggestions.parseTable("thank\tyou the\n"),
        words: ["hello", "help", "held"])
    private func texts(_ context: String, _ language: WordSuggestions.Language, _ user: UserLexicon) -> [String] {
        engine.suggestions(before: context, language: language, user: user).map(\.text)
    }

    func testFrequentChineseWordMovesToFront() {
        var user = UserLexicon()
        user.learnChinese("面团", before: "买", letters: "miantuan")
        XCTAssertEqual(texts("面", .chinese, user), ["包", "粉", "条"], "One use changes nothing")
        user.learnChinese("面团", before: "买", letters: "miantuan")
        XCTAssertEqual(texts("面", .chinese, user), ["团", "包", "粉", "条"], "A word the table lacks enters after repeated use")
        XCTAssertEqual(texts("买", .chinese, user), ["面团"])
        for _ in 0..<3 { user.learnChinese("粉", before: "面") }
        XCTAssertEqual(texts("面", .chinese, user), ["粉", "团", "包", "条"], "More uses rank higher")
    }

    func testPinyinChoicesAreRemembered() {
        var user = UserLexicon()
        let engineOrder = [PinyinCandidate(text: "面", consumed: 4), PinyinCandidate(text: "棉", consumed: 4)]
        user.learnPinyin("mian", text: "棉")
        XCTAssertEqual(user.rerank(engineOrder, for: "mian"), engineOrder)
        user.learnPinyin("mian", text: "棉")
        XCTAssertEqual(user.rerank(engineOrder, for: "mian").map(\.text), ["棉", "面"])
        user.learnChinese("面团", before: "", letters: "miantuan"); user.learnChinese("面团", before: "", letters: "miantuan")
        XCTAssertEqual(user.rerank([], for: "miantuan"), [PinyinCandidate(text: "面团", consumed: 8)])
        XCTAssertEqual(user.rerank(engineOrder, for: "mia"), engineOrder, "Other spellings are untouched")
    }

    func testEnglishWordsAndPairs() {
        var user = UserLexicon()
        for _ in 0..<2 { user.learnEnglish(endOf: "say helsinki"); user.learnEnglish(endOf: "thank Jeremy") }
        XCTAssertEqual(texts("hel", .english, user), ["helsinki", "hello", "help", "held"])
        XCTAssertEqual(texts("Hel", .english, user).first, "Helsinki")
        XCTAssertEqual(texts("thank ", .english, user), ["jeremy", "you", "the"])
        user.learnEnglish(endOf: "a"); user.learnEnglish(endOf: "12 "); user.learnEnglish(endOf: "好")
        XCTAssertNil(user.words["a"], "Single letters and non-words are not counted")
    }

    func testOnlyHanTextIsLearnedAsChinese() {
        var user = UserLexicon()
        user.learnChinese("ok", before: "好"); user.learnChinese("", before: "好")
        user.learnChinese("一二三四五六七八九", before: "好")
        XCTAssertTrue(user.isEmpty)
    }

    func testSurvivesSavingAndLoading() {
        let defaults = UserDefaults(suiteName: "UserLexiconTests")!
        defaults.removePersistentDomain(forName: "UserLexiconTests")
        XCTAssertTrue(UserLexicon.load(defaults).isEmpty)
        var user = UserLexicon()
        user.learnChinese("面团", before: "买", letters: "miantuan"); user.learnEnglish(endOf: "thank you")
        user.save(defaults)
        XCTAssertEqual(UserLexicon.load(defaults), user)
        defaults.removePersistentDomain(forName: "UserLexiconTests")
    }
}
