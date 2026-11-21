import Foundation

@main
struct PinyinSmoke {
    static var failures: [UInt] = []
    static func check(_ value: @autoclosure () -> Bool, line: UInt = #line) {
        if !value() { failures.append(line); FileHandle.standardError.write(Data("Pinyin check failed at line \(line)\n".utf8)) }
    }
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let lexicon = try JSONDecoder().decode([String: [String]].self, from: data)
        let costsURL = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("pinyin-costs.json")
        let costs = try JSONDecoder().decode([String: [Double]].self, from: Data(contentsOf: costsURL))
        let syllablesURL = costsURL.deletingLastPathComponent().appendingPathComponent("pinyin-syllables.json")
        let syllables = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: syllablesURL))
        let engine = PinyinEngine(lexicon: lexicon, costs: costs, syllables: syllables)
        for input in ["shunv", "shu", "jikongge", "shuangjikongge", "wom", "wm", "nihaom", "nihm", "womxianz", "wmxianzai", "woaini", "womendouyouyigejia"] {
            let values = engine.candidates(for: input).map { "\($0.text):\($0.consumed)" }.joined(separator: ", ")
            FileHandle.standardError.write(Data("\(input): \(values)\n".utf8))
        }
        check(engine.candidates(for: "nihao").first?.text == "你好")
        check(engine.candidates(for: "zhongwen").first?.text == "中文")
        check(engine.candidates(for: "ceshi").first?.text == "测试")
        check(engine.candidates(for: "zhongguo").first?.text == "中国")
        let fixture = PinyinEngine(lexicon: ["nihao": ["你好"], "ma": ["吗"], "xing": ["行", "星"]])
        check(fixture.candidates(for: "nihaoma").first == PinyinCandidate(text: "你好吗", consumed: 7))
        check(fixture.candidates(for: "xing").count == 2)
        check(fixture.candidates(for: "xi").first?.consumed == 2)
        check(fixture.candidates(for: "").isEmpty)
        check(engine.candidates(for: "wo").first == PinyinCandidate(text: "我", consumed: 2))
        check(engine.candidates(for: "wom").first == PinyinCandidate(text: "我们", consumed: 3))
        check(engine.candidates(for: "wome").first == PinyinCandidate(text: "我们", consumed: 4))
        check(engine.candidates(for: "women").first == PinyinCandidate(text: "我们", consumed: 5))
        check(engine.candidates(for: "WOM").first?.text == "我们")
        let mixed = PinyinEngine(lexicon: ["wo": ["我"], "women": ["我们"], "zhongguo": ["中国"], "zhong": ["中"]])
        check(mixed.candidates(for: "wom").first?.consumed == 3)
        check(mixed.candidates(for: "zhongg").first == PinyinCandidate(text: "中国", consumed: 6))
        check(mixed.candidates(for: "wog").first == PinyinCandidate(text: "我", consumed: 2))
        check(mixed.candidates(for: "woaini").first?.consumed == 2)
        check(mixed.candidates(for: String(repeating: "a", count: 65)).isEmpty)
        let wom = engine.candidates(for: "wom")
        check(wom.contains { $0.text == "我妈" && $0.consumed == 3 })
        check(wom.contains { $0.text == "我没" && $0.consumed == 3 })
        check(wom.filter { $0.consumed == 3 }.count >= 5)
        check(engine.candidates(for: "nihaom").first == PinyinCandidate(text: "你好吗", consumed: 6))
        check(engine.candidates(for: "nihaoma").first?.text == "你好吗")
        check(engine.candidates(for: "nihaom").contains { $0.text == "你好妈" && $0.consumed == 6 })
        check(engine.candidates(for: "woaini").contains { $0.text == "我爱你" && $0.consumed == 6 })
        let sentence = engine.candidates(for: "womendouyouyigejia")
        check(sentence.contains { $0.text == "我们都有一个家" && $0.consumed == 18 })
        check(sentence.contains { $0.text == "我们" && $0.consumed == 5 })
        for input in ["womendouyouyigejia", "sijdhjhs", "wojshsbjdbbsbbdbjsj", String(repeating: "nihao", count: 11)] {
            let options = engine.candidates(for: input)
            check(options.first?.consumed == input.count)
            check((options.first?.text.count ?? 0) > 4)
            check(options.count <= 20)
            check(options.dropFirst().allSatisfy { $0.consumed < input.count && $0.text.count <= 4 })
        }
        let partial = engine.candidates(for: "jsjjshdbdvjhs")
        check(!partial.isEmpty && partial.count <= 20)
        check(partial.dropFirst().allSatisfy { $0.text.count <= 4 })
        check(engine.candidates(for: "wom").count <= 40)
        check(engine.candidates(for: "wm").first == PinyinCandidate(text: "我们", consumed: 2))
        check(engine.candidates(for: "WM").contains { $0.text == "我妈" && $0.consumed == 2 })
        check(engine.candidates(for: "nihm").first == PinyinCandidate(text: "你好吗", consumed: 4))
        check(engine.candidates(for: "womxianz").first == PinyinCandidate(text: "我们现在", consumed: 8))
        check(engine.candidates(for: "wmxianzai").first?.text == "我们现在")
        check(engine.candidates(for: "womxianz").contains { $0.text == "我们" && $0.consumed == 3 })
        check(engine.candidates(for: "nihaom").count <= 40)
        let shunv = engine.candidates(for: "shunv")
        check(shunv.first == PinyinCandidate(text: "淑女", consumed: 5))
        check(shunv.contains { $0.text == "熟女" && $0.consumed == 5 })
        check(!shunv.contains { ["属女", "书女", "数女"].contains($0.text) })
        check(shunv.prefix(18).filter { $0.text.count == 1 && $0.consumed == 3 }.count >= 12)
        for character in ["书", "数", "输", "树", "属", "熟", "舒", "叔"] {
            check(shunv.contains { $0.text == character && $0.consumed == 3 })
        }
        check(engine.candidates(for: "shu").count >= 20)
        check(engine.candidates(for: "jikongge").contains { $0.text == "击" && $0.consumed == 2 })
        check(engine.candidates(for: "kongge").first?.text == "空格")
        check(engine.candidates(for: "shuangjikongge").first?.text == "双击空格")
        check(engine.candidates(for: "ni1").isEmpty)
        // Common idioms by full spelling and by initials.
        check(engine.candidates(for: "huashetianzu").first?.text == "画蛇添足")
        check(engine.candidates(for: "yishierniao").first?.text == "一石二鸟")
        check(engine.candidates(for: "hstz").contains { $0.text == "画蛇添足" })
        var delivery = VoiceResultDelivery()
        let documentID = UUID()
        delivery.begin("job1", documentID: documentID)
        delivery.receive(id: "stale", text: "不要插入")
        check(delivery.take(visible: true, documentID: documentID) == nil)
        delivery.receive(id: "job1", text: "自动上屏")
        check(delivery.take(visible: false, documentID: documentID) == nil)
        check(delivery.take(visible: true, documentID: documentID)?.text == "自动上屏")
        delivery.receive(id: "job1", text: "重复结果")
        check(delivery.take(visible: true, documentID: documentID) == nil)
        delivery.begin("job2", documentID: documentID); delivery.receive(id: "job2", text: "")
        check(delivery.take(visible: true, documentID: documentID) == nil)
        delivery.receive(id: "job2", text: "取消的结果"); delivery.reset()
        check(delivery.take(visible: true, documentID: documentID) == nil)
        delivery.begin("job3", documentID: documentID); delivery.receive(id: "job3", text: "下一次录音")
        check(delivery.take(visible: true, documentID: documentID)?.id == "job3")
        delivery.begin("job4", documentID: documentID)
        delivery.receive(id: "job4", text: "旧输入框文字")
        check(delivery.take(visible: true, documentID: UUID()) == nil)
        check(delivery.take(visible: true, documentID: documentID) == nil)
        let started = Date()
        var slowestKey: TimeInterval = 0
        let typing = "wozainijiashehuilema"
        var buffer = ""
        for letter in typing {
            buffer.append(letter)
            let keyStarted = Date()
            _ = engine.candidates(for: buffer)
            slowestKey = max(slowestKey, Date().timeIntervalSince(keyStarted))
        }
        print("Pinyin sequential-prefix decode seconds: \(Date().timeIntervalSince(started)); slowest prefix seconds: \(slowestKey)")
        for input in ["womxianz", "nihm", "womendouyouyigejia", String(repeating: "w", count: 64)] {
            check(engine.candidates(for: input).count <= 40)
        }
        guard failures.isEmpty else { fatalError("Pinyin checks failed at lines \(failures)") }
        print("Pinyin + voice delivery checks passed; bundled keys: \(lexicon.count); stress seconds: \(Date().timeIntervalSince(started))")
    }
}

