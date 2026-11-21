import Foundation

@main
struct SuggestSmoke {
    static var failures: [UInt] = []
    static func check(_ value: @autoclosure () -> Bool, line: UInt = #line) {
        if !value() { failures.append(line); FileHandle.standardError.write(Data("Suggestion check failed at line \(line)\n".utf8)) }
    }
    static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        func text(_ name: String) throws -> String {
            String(decoding: try Data(contentsOf: folder.appendingPathComponent(name)), as: UTF8.self)
        }
        let started = Date()
        let engine = WordSuggestions(chinese: WordSuggestions.parseTable(try text("suggest-zh.txt")),
                                     english: WordSuggestions.parseTable(try text("suggest-en.txt")),
                                     words: try text("suggest-en-words.txt").split(separator: "\n").map(String.init),
                                     idioms: try text("suggest-idioms.txt").split(separator: "\n").map(String.init),
                                     xiehouyu: WordSuggestions.parseRiddles(try text("suggest-xiehouyu.txt")))
        let loadSeconds = Date().timeIntervalSince(started)
        func texts(_ context: String, _ language: WordSuggestions.Language) -> [String] {
            engine.suggestions(before: context, language: language).map { $0.text }
        }
        for (context, language) in [("我", WordSuggestions.Language.chinese), ("今天", .chinese), ("谢谢", .chinese),
                                    ("不好", .chinese), ("的", .chinese), ("好", .chinese), ("画蛇", .chinese), ("外甥打灯笼", .chinese),
                                    ("一举", .chinese), ("thank ", .english), ("hel", .english), ("I ", .english)] {
            FileHandle.standardError.write(Data("\(context): \(texts(context, language).joined(separator: " "))\n".utf8))
        }
        FileHandle.standardError.write(Data("loaded in \(loadSeconds)s\n".utf8))
        check(texts("我", .chinese).contains("们"))
        check(texts("谢谢", .chinese).first == "你")
        check(texts("明天我们", .chinese).contains("可以"))
        check(texts("不好", .chinese).contains("意思"))
        // Everyday words, not official prose, follow 的.
        check(!texts("的", .chinese).prefix(4).contains("发展"))
        check(!texts("的", .chinese).prefix(4).contains("经济"))
        check(texts("好", .chinese).first == "的")
        check(texts("画蛇", .chinese).first == "添足")
        check(texts("画蛇添", .chinese).first == "足")
        check(texts("外甥打灯笼", .chinese).first == "——照旧（舅）")
        check(texts("黄鼠狼给鸡拜年", .chinese).first == "——没安好心")
        check(texts("一举", .chinese).contains("两得"))
        check(texts("thank ", .english).first == "you")
        check(texts("Thank you. I ", .english).contains("have"))
        check(texts("hel", .english).contains("help"))
        check(engine.suggestions(before: "Hel", language: .english).contains(
            WordSuggestion(text: "Help", replacing: 3, insertion: "Help ")))
        check(texts("hel", .chinese).isEmpty)
        check(texts("", .chinese) == WordSuggestions.chineseStarters)
        check(texts("", .english) == WordSuggestions.englishStarters)
        check(texts("123", .english).isEmpty)
        check(texts("我", .chinese).count <= 8)
        check(loadSeconds < 5)
        if !failures.isEmpty { exit(1) }
        print("Suggestion tables passed")
    }
}
