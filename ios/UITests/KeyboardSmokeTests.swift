import XCTest

final class KeyboardSmokeTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func findAndTap(_ element: XCUIElement, in app: XCUIApplication) {
        // XCTest scrolls table cells into view before tapping. Stale cell frames
        // during Settings navigation must not be used as screen coordinates.
        XCTAssertTrue(element.waitForExistence(timeout: 15), app.debugDescription)
        element.tap()
    }

    func testKeyboardInputAndModeCycle() {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        findAndTap(settings.staticTexts["General"].firstMatch, in: settings)
        findAndTap(settings.cells["Keyboard"].firstMatch, in: settings)
        findAndTap(settings.cells["KEYBOARDS"].firstMatch, in: settings)
        let installed = settings.cells.matching(NSPredicate(format: "label CONTAINS %@", "SayKey Lab")).firstMatch
        if !installed.exists {
            findAndTap(settings.cells["AddNewKeyboard"].firstMatch, in: settings)
            let thirdParty = settings.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "SayKey Lab")).firstMatch
            findAndTap(thirdParty, in: settings)
        }
        settings.terminate()

        let app = XCUIApplication()
        app.terminate()
        app.launch()
        let editor = app.textViews["lab-editor"]
        // Cold shared runners can return from launch before the app has a
        // foreground window (orientation 0, empty AX tree). Activate explicitly
        // rather than treating that setup delay as a keyboard input failure.
        if !editor.waitForExistence(timeout: 30) {
            attach(app, name: "Main app activation retry")
            app.activate()
        }
        XCTAssertTrue(editor.waitForExistence(timeout: 30), app.debugDescription)
        app.buttons["清空测试区"].firstMatch.tap()
        editor.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 15) {
            attach(app, name: "Keyboard activation retry")
            editor.tap()
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        dismissSystemTypingIntroduction(in: app, wait: true)
        // The keyboard opens on its letter page; the hide button in the top
        // bar tells it apart from the system keyboard.
        let testButton = app.buttons["keyboard-voice-button"]
        let marker = app.buttons["keyboard-hide"]
        for _ in 0..<6 {
            if marker.exists { break }
            dismissSystemTypingIntroduction(in: app, wait: false)
            let next = app.buttons["Next keyboard"].firstMatch
            if next.waitForExistence(timeout: 5) {
                next.tap()
                if marker.waitForExistence(timeout: 30) { break }
            }
            // On a cold shared runner, UIKit may take >40s to launch the
            // extension and its first host connection can expire. Refocus the
            // editor so the now-warm extension gets a fresh host connection.
            if !app.keyboards.firstMatch.exists {
                attach(app, name: "Cold extension connection retry")
                editor.tap()
                if marker.waitForExistence(timeout: 15) { break }
            }
        }
        XCTAssertTrue(marker.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["key-h"].waitForExistence(timeout: 5), "Letters are the first page")
        XCTAssertTrue(app.buttons["keyboard-header-newline"].exists, "Auto newline is in the bar on the letter page")
        // The page opens in pinyin; the key beside 123 switches to English.
        switchLanguage(to: "英文", in: app)
        XCTAssertTrue(app.buttons["keyboard-header-mic"].exists, "Letter pages can start voice input")
        let pageBounds = app.scrollViews["keyboard-pages"].frame
        XCTAssertLessThanOrEqual(pageBounds.height, 216, "Normal compact body must not retain the extra footer row")
        app.buttons["keyboard-return"].tap()
        XCTAssertTrue((editor.value as? String ?? "").hasSuffix("\n"))
        let voiceReturnBottom = app.buttons["keyboard-return"].frame.maxY

        let selector = app.segmentedControls["keyboard-mode-selector"]
        let englishTop = app.buttons["key-q"].frame.minY
        for letter in "hello" { app.buttons["key-" + String(letter)].tap() }
        XCTAssertTrue((editor.value as? String ?? "").hasSuffix("hello"))
        // Finishing a word offers likely next words; tapping one inserts it.
        app.buttons["keyboard-space"].tap()
        let nextWord = app.buttons["suggestion-all"]
        XCTAssertTrue(nextWord.waitForExistence(timeout: 10), "hello is followed by a suggestion bar")
        nextWord.tap()
        XCTAssertTrue((editor.value as? String ?? "").hasSuffix("hello all "))
        // One tap on shift capitalizes exactly one letter.
        // The page is rebuilt after shift changes; wait for the new keys the
        // same way the page swipes below do.
        app.buttons["keyboard-shift"].tap()
        XCTAssertTrue(app.buttons["key-H"].waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["key-H"].tap()
        XCTAssertTrue(app.buttons["key-i"].waitForExistence(timeout: 15), "Shift turns off after one letter")
        app.buttons["key-i"].tap()
        XCTAssertTrue((editor.value as? String ?? "").hasSuffix("hello all Hi"))
        attach(app, name: "English keyboard")

        app.scrollViews["keyboard-pages"].swipeLeft()
        XCTAssertTrue(testButton.waitForExistence(timeout: 5), "Voice is the second page")
        XCTAssertGreaterThanOrEqual(testButton.frame.minY, pageBounds.minY)
        XCTAssertLessThanOrEqual(testButton.frame.maxY, pageBounds.maxY)
        XCTAssertEqual(app.buttons["keyboard-return"].frame.maxY, voiceReturnBottom, accuracy: 1)

        // With two pages, the next swipe is back on the letters.
        app.scrollViews["keyboard-pages"].swipeLeft()
        waitForMode(0, in: selector)
        XCTAssertTrue(app.buttons["key-q"].waitForExistence(timeout: 5))
        switchLanguage(to: "中文拼音", in: app)
        XCTAssertEqual(app.buttons["key-q"].frame.minY, englishTop, accuracy: 1)
        XCTAssertEqual(app.buttons["keyboard-return"].frame.maxY, voiceReturnBottom, accuracy: 1)
        attach(app, name: "Aligned idle Chinese keyboard")
        for letter in "nihao" { app.buttons["key-" + String(letter)].tap() }
        let candidate = app.buttons["candidate-你好"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 5))
        attach(app, name: "Chinese pinyin candidates")
        candidate.tap()
        XCTAssertTrue((editor.value as? String ?? "").hasSuffix("你好"))
        for letter in "wo" { app.buttons["key-" + String(letter)].tap() }
        XCTAssertTrue(app.buttons["candidate-我"].waitForExistence(timeout: 5))
        // Candidate scrolling belongs to the candidate row, not the page pager.
        app.scrollViews["pinyin-candidates"].swipeLeft()
        XCTAssertTrue(app.staticTexts["pinyin-composition"].exists)
        app.buttons["key-m"].tap()
        let unfinished = app.buttons["candidate-我们"]
        XCTAssertTrue(unfinished.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["candidate-我妈"].exists)
        attach(app, name: "Unfinished wom predicts women")
        app.buttons["pinyin-expand-candidates"].tap()
        let gridChoice = app.buttons["grid-candidate-我妈"]
        XCTAssertTrue(gridChoice.waitForExistence(timeout: 5))
        XCTAssertTrue(gridChoice.isHittable)
        XCTAssertFalse(app.buttons["grid-candidate-我们"].exists)
        XCTAssertTrue(unfinished.isHittable)
        attach(app, name: "Expanded pinyin candidate grid")
        unfinished.tap()
        XCTAssertFalse(gridChoice.isHittable, "Selecting the primary suggestion collapses the grid")
        XCTAssertTrue((editor.value as? String ?? "").hasSuffix("你好我们"))
        for letter in "nihaom" { app.buttons["key-" + String(letter)].tap() }
        XCTAssertTrue(app.buttons["candidate-你好吗"].waitForExistence(timeout: 5))
        attach(app, name: "Composed nihaom phrase")
        app.buttons["candidate-你好吗"].tap()
        XCTAssertTrue((editor.value as? String ?? "").hasSuffix("你好我们你好吗"))
        for (spelling, text) in [("wm", "我们"), ("nihm", "你好吗"), ("womxianz", "我们现在")] {
            for letter in spelling { app.buttons["key-" + String(letter)].tap() }
            let mixed = app.buttons["candidate-" + text]
            XCTAssertTrue(mixed.waitForExistence(timeout: 5))
            mixed.tap()
            XCTAssertTrue((editor.value as? String ?? "").hasSuffix(text))
        }
        // Return keeps the typed pinyin letters as English.
        for letter in "ok" { app.buttons["key-" + String(letter)].tap() }
        app.buttons["keyboard-return"].tap()
        XCTAssertTrue((editor.value as? String ?? "").hasSuffix("我们现在ok"))
        attach(app, name: "Chinese pinyin keyboard")
        app.scrollViews["keyboard-pages"].swipeRight()
        waitForMode(1, in: selector)
        XCTAssertTrue(testButton.waitForExistence(timeout: 5))
        attach(app, name: "Voice test keyboard")
        // Direct mode selection uses the same sliding transition.
        selector.buttons.element(boundBy: 0).tap()
        waitForMode(0, in: selector)
        XCTAssertTrue(app.buttons["key-h"].waitForExistence(timeout: 5))
        switchLanguage(to: "英文", in: app)
        for _ in 0..<30 { app.buttons["key-a"].tap() }
        let before = (editor.value as? String ?? "").count
        app.buttons["keyboard-delete"].tap()
        XCTAssertEqual((editor.value as? String ?? "").count, before - 1)
        app.buttons["keyboard-delete"].press(forDuration: 1.6)
        let afterHold = editor.value as? String ?? ""
        XCTAssertLessThan(afterHold.count, before - 3)
        Thread.sleep(forTimeInterval: 0.35)
        XCTAssertEqual(editor.value as? String ?? "", afterHold, "Deletion must stop on release")
        // Line delete removes what was typed on the current line only.
        app.buttons["keyboard-return"].tap()
        for letter in "line" { app.buttons["key-" + String(letter)].tap() }
        XCTAssertTrue((editor.value as? String ?? "").hasSuffix("\nline"))
        app.buttons["keyboard-delete-line"].tap()
        XCTAssertEqual(editor.value as? String ?? "", afterHold + "\n")
        // The hide button takes the whole keyboard off the screen.
        marker.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: marker)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed)
    }

    private func waitForMode(_ index: Int, in selector: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"),
                                                    object: selector.buttons.element(boundBy: index))
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
    /// Taps 中/英 and waits for the rebuilt page to report the language.
    private func switchLanguage(to label: String, in app: XCUIApplication) {
        app.buttons["keyboard-language"].tap()
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label),
                                                    object: app.buttons["keyboard-language"])
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed)
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func dismissSystemTypingIntroduction(in app: XCUIApplication, wait: Bool) {
        let introduction = app.staticTexts.matching(NSPredicate(format:
            "label BEGINSWITH %@", "Speed up your typing by sliding your finger")).firstMatch
        let visible = wait ? introduction.waitForExistence(timeout: 3) : introduction.exists
        if visible {
            let proceed = app.buttons["Continue"].firstMatch
            XCTAssertTrue(proceed.waitForExistence(timeout: 3))
            proceed.tap()
        }
    }
}
