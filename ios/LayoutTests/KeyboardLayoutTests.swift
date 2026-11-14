import UIKit
import XCTest

final class KeyboardLayoutTests: XCTestCase {
    @MainActor func testFreshKeyboardConstructionAndAlignedRows() async {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let previousKeyWindow = scene?.windows.first { $0.isKeyWindow }
        let window: UIWindow
        if let scene = scene { window = UIWindow(windowScene: scene) }
        else { window = UIWindow(frame: UIScreen.main.bounds) }
        let host = UIViewController()
        host.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousKeyWindow?.makeKeyAndVisible() }
        host.loadViewIfNeeded()
        let controller = KeyboardViewController()
        // This exercises the production UIKit code, including all three pages.
        // Activating constraints between unattached keys crashes at this point.
        controller.loadViewIfNeeded()
        let root = controller.view!
        root.overrideUserInterfaceStyle = .dark
        // Host the controller so UIKit invokes its layout lifecycle. A detached
        // view's layoutIfNeeded does not invoke viewDidLayoutSubviews reliably.
        host.addChild(controller)
        root.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(root)
        let hostHeight = root.heightAnchor.constraint(equalToConstant: 500)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            root.topAnchor.constraint(equalTo: host.view.topAnchor),
            hostHeight
        ])
        controller.didMove(toParent: host)
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        root.setNeedsLayout(); root.layoutIfNeeded()
        // Let the new window finish its appearance/display transaction before
        // inspecting its rendered state and restoring the previous key window.
        try? await Task.sleep(nanoseconds: 150_000_000)
        host.view.layoutIfNeeded(); root.layoutIfNeeded()
        let views = descendants(root)
        let pager = views.first { $0.accessibilityIdentifier == "keyboard-pages" } as! UIScrollView
        XCTAssertEqual(pager.contentSize.width, pager.bounds.width * 3, accuracy: 1)
        XCTAssertEqual(pager.contentOffset.x, pager.bounds.width, accuracy: 1, "The current page is always the center one")
        let selector = views.first { $0.accessibilityIdentifier == "keyboard-mode-selector" } as! UISegmentedControl
        XCTAssertEqual(selector.titleForSegment(at: selector.selectedSegmentIndex), "EN", "The keyboard opens on English")
        for identifier in ["keyboard-header-mic", "keyboard-hide", "keyboard-mode-selector"] {
            let control = views.first { $0.accessibilityIdentifier == identifier }!
            let frame = control.convert(control.bounds, to: root)
            XCTAssertFalse(control.isHidden, identifier)
            XCTAssertGreaterThan(frame.width, 20, identifier)
            XCTAssertGreaterThanOrEqual(frame.minX, 0, identifier)
            XCTAssertLessThanOrEqual(frame.maxX, root.bounds.width, identifier)
        }
        // The voice page is a side page now; it stays centered within its page.
        let mic = views.first { $0.accessibilityIdentifier == "keyboard-voice-button" }!
        let micFrame = mic.convert(mic.bounds, to: root)
        XCTAssertEqual((micFrame.midX - root.bounds.midX).remainder(dividingBy: pager.bounds.width), 0, accuracy: 1)
        // Reproduce the cold extension's size negotiation, not only a detached
        // screenshot at one fixed size. No page may scroll vertically.
        for height in [CGFloat(272), 380, 272] {
            hostHeight.constant = height
            host.view.layoutIfNeeded(); root.layoutIfNeeded()
            XCTAssertEqual(pager.contentSize.height, pager.bounds.height, accuracy: 1)
            XCTAssertEqual(pager.contentOffset.y, 0, accuracy: 1)
            let inPager = mic.convert(mic.bounds, to: pager)
            XCTAssertGreaterThanOrEqual(inPager.minY, 0)
            XCTAssertLessThanOrEqual(inPager.maxY, pager.bounds.height, "Entire mic must be visible without vertical scrolling")
        }
        let hotwords = views.first { $0.accessibilityIdentifier == "keyboard-hotwords" }!
        let hotFrame = hotwords.convert(hotwords.bounds, to: pager)
        XCTAssertGreaterThanOrEqual(hotFrame.minY, 0)
        XCTAssertLessThanOrEqual(hotFrame.maxY, pager.bounds.height)
        let firstKeys = views.filter { $0.accessibilityIdentifier == "key-q" }
        let returns = views.filter { $0.accessibilityIdentifier == "keyboard-return" }
        XCTAssertEqual(firstKeys.count, 2, "English and pinyin pages must both be constructed")
        XCTAssertEqual(returns.count, 3, "Voice and both text pages must be constructed")
        guard firstKeys.count == 2, returns.count == 3 else { return }
        let voiceReturns = returns.filter { $0.bounds.width > 100 }
        XCTAssertEqual(voiceReturns.count, 1)
        if let voiceReturn = voiceReturns.first {
            let offset = voiceReturn.convert(voiceReturn.bounds, to: root).midX - root.bounds.midX
            XCTAssertEqual(offset.remainder(dividingBy: pager.bounds.width), 0, accuracy: 1)
        }
        // Three fixed regions: button bar, strip, pages. The hide button is
        // the right-most control of the bar, with the page selector on its
        // left, and the one line delete shared by all pages sits below it.
        let hideFrame = views.first { $0.accessibilityIdentifier == "keyboard-hide" }.map { $0.convert($0.bounds, to: root) } ?? .zero
        let selectorFrame = selector.convert(selector.bounds, to: root)
        XCTAssertLessThanOrEqual(selectorFrame.maxX, hideFrame.minX)
        XCTAssertEqual(hideFrame.maxX, root.bounds.width - 12, accuracy: 1)
        let lineDeletes = views.filter { $0.accessibilityIdentifier == "keyboard-delete-line" }
        XCTAssertEqual(lineDeletes.count, 1, "One line delete serves every page")
        if let lineDelete = lineDeletes.first {
            let frame = lineDelete.convert(lineDelete.bounds, to: root)
            XCTAssertEqual(frame.minX, hideFrame.minX, accuracy: 1)
            XCTAssertEqual(frame.maxX, hideFrame.maxX, accuracy: 1)
            XCTAssertGreaterThanOrEqual(frame.minY, hideFrame.maxY)
            XCTAssertLessThanOrEqual(frame.maxY, pager.convert(pager.bounds, to: root).minY)
        }
        let firstTop = firstKeys[0].convert(firstKeys[0].bounds, to: root).minY
        XCTAssertGreaterThan(firstKeys[0].bounds.width, 0)
        XCTAssertEqual(firstKeys[1].convert(firstKeys[1].bounds, to: root).minY, firstTop, accuracy: 1)
        let bottom = returns[0].convert(returns[0].bounds, to: root).maxY
        for key in returns {
            XCTAssertEqual(key.bounds.height, 44, accuracy: 1)
            XCTAssertEqual(key.convert(key.bounds, to: root).maxY, bottom, accuracy: 1)
        }
        let image = UIGraphicsImageRenderer(size: root.bounds.size).image { _ in
            root.drawHierarchy(in: root.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Fresh keyboard layout"; attachment.lifetime = .keepAlways
        add(attachment)
        // Shift: one tap shows capitals. A second tap either locks them (quick)
        // or turns them off (slow runner); the double-tap timing itself is
        // covered by KeyboardEditingTests, so accept both here.
        visibleButton("keyboard-shift", in: root).sendActions(for: .primaryActionTriggered)
        XCTAssertNotNil(visibleButton("key-Q", in: root))
        visibleButton("keyboard-shift", in: root).sendActions(for: .primaryActionTriggered)
        if isVisible("key-Q", in: root) {
            visibleButton("keyboard-shift", in: root).sendActions(for: .primaryActionTriggered)
        }
        XCTAssertNotNil(visibleButton("key-q", in: root), "Shift always returns to lowercase")
    }

    @MainActor func testHotwordEditorUsesOwnTextAndUnicodeDelete() async {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let previousKeyWindow = scene?.windows.first { $0.isKeyWindow }
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
        let host = UIViewController(); host.overrideUserInterfaceStyle = .dark
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previousKeyWindow?.makeKeyAndVisible() }
        host.loadViewIfNeeded()
        let controller = KeyboardViewController(); controller.loadViewIfNeeded()
        host.addChild(controller)
        let root = controller.view!; root.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: host.view.topAnchor),
            root.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            root.heightAnchor.constraint(equalToConstant: 440)
        ])
        controller.didMove(toParent: host)
        controller.showHotwordEditor(HotwordFile(id: "hot", name: "hot.txt", text: "开始\n🧑🏽‍💻", revision: "fixture", writable: true))
        host.view.layoutIfNeeded(); root.layoutIfNeeded()
        let editor = descendants(root).first { $0.accessibilityIdentifier == "hotword-editor-text" } as! UITextView
        let delete = visibleButton("keyboard-delete", in: root)
        delete.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(editor.text, "开始\n", "One delete removes the entire composed emoji")
        for letter in "wom" { visibleButton("key-" + String(letter), in: root).sendActions(for: .primaryActionTriggered) }
        await waitForCandidate("candidate-我们", in: root)
        visibleButton("pinyin-expand-candidates", in: root).sendActions(for: .primaryActionTriggered)
        host.view.layoutIfNeeded(); root.layoutIfNeeded()
        XCTAssertFalse(descendants(root).contains { $0.accessibilityIdentifier == "grid-candidate-我们" })
        XCTAssertNotNil(visibleButton("grid-candidate-我妈", in: root))
        visibleButton("candidate-我们", in: root).sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(editor.text, "开始\n我们", "Pinyin selection edits the hotword draft")
        visibleButton("keyboard-return", in: root).sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(editor.text, "开始\n我们\n")
        editor.text = "测试"; editor.selectedRange = NSRange(location: 2, length: 0)
        let space = visibleButton("keyboard-space", in: root)
        space.sendActions(for: .primaryActionTriggered)
        space.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(editor.text, "测试。", "Double space adds a Chinese sentence stop")
        editor.text = ""; editor.selectedRange = NSRange(location: 0, length: 0)
        for letter in "wom" { visibleButton("key-" + String(letter), in: root).sendActions(for: .primaryActionTriggered) }
        space.sendActions(for: .primaryActionTriggered)
        space.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(editor.text, "我们。", "Composition commit counts as the first space tap")
        XCTAssertEqual(editor.attributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor, UIColor.white)
        visibleButton("keyboard-number-toggle", in: root).sendActions(for: .primaryActionTriggered)
        visibleButton("key-1", in: root).sendActions(for: .primaryActionTriggered)
        visibleButton("keyboard-symbol-page", in: root).sendActions(for: .primaryActionTriggered)
        for symbol in ["+", "=", "[", "€"] {
            visibleButton("key-" + symbol, in: root).sendActions(for: .primaryActionTriggered)
        }
        XCTAssertEqual(editor.text, "我们。1+=[€")
        visibleButton("keyboard-symbol-page", in: root).sendActions(for: .primaryActionTriggered)
        XCTAssertNotNil(visibleButton("key-1", in: root))
        visibleButton("keyboard-number-toggle", in: root).sendActions(for: .primaryActionTriggered)
        XCTAssertNotNil(visibleButton("key-q", in: root))
        let spelling = "wozainijiashehuilema"
        let typingStarted = Date()
        for letter in spelling { visibleButton("key-" + String(letter), in: root).sendActions(for: .primaryActionTriggered) }
        print("Rapid pinyin input main-thread seconds: \(Date().timeIntervalSince(typingStarted))")
        let label = descendants(root).first { $0.accessibilityIdentifier == "pinyin-composition" } as! UILabel
        XCTAssertEqual(label.text, spelling, "Rapid typing must not drop letters")
        host.view.layoutIfNeeded(); root.layoutIfNeeded()
        // The spelling shares the second row with its candidates; the button
        // bar above it stays exactly as it is on the English page.
        let candidateLine = descendants(root).first { $0.accessibilityIdentifier == "pinyin-candidate-line" }!
        let candidateArea = descendants(root).first { $0.accessibilityIdentifier == "pinyin-candidates" }!
        XCTAssertFalse(candidateLine.isHidden)
        XCTAssertGreaterThan(label.bounds.width, 20)
        XCTAssertLessThanOrEqual(label.bounds.width, candidateLine.bounds.width * 0.34 + 1)
        XCTAssertLessThanOrEqual(label.convert(label.bounds, to: root).maxX, candidateArea.convert(candidateArea.bounds, to: root).minX)
        XCTAssertGreaterThan(candidateArea.bounds.width, 100)
        let barBottom = visibleButton("keyboard-hide", in: root).convert(CGRect(x: 0, y: 0, width: 1, height: 30), to: root).maxY
        XCTAssertTrue(isVisible("keyboard-mode-selector", in: root), "The button bar stays while pinyin is typed")
        XCTAssertGreaterThanOrEqual(candidateLine.convert(candidateLine.bounds, to: root).minY, barBottom - 1)
        for _ in spelling { visibleButton("keyboard-delete", in: root).sendActions(for: .primaryActionTriggered) }
        for letter in "nihao" { visibleButton("key-" + String(letter), in: root).sendActions(for: .primaryActionTriggered) }
        await waitForCandidate("candidate-你好", in: root)
        XCTAssertEqual(label.text, "nihao", "A stale decoding result cannot replace new input")
        try? await Task.sleep(nanoseconds: 100_000_000)
        host.view.layoutIfNeeded(); root.layoutIfNeeded()
        let hello = visibleButton("candidate-你好", in: root)
        XCTAssertEqual(hello.titleLabel?.text, "你好")
        XCTAssertGreaterThan(hello.titleLabel?.bounds.width ?? 0, 30)
        let image = UIGraphicsImageRenderer(size: root.bounds.size).image { _ in
            root.drawHierarchy(in: root.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Hotword editor with internal keyboard"; attachment.lifetime = .keepAlways; add(attachment)
        visibleButton("candidate-你好", in: root).sendActions(for: .primaryActionTriggered)
        let priorDraft = editor.text ?? ""
        for letter in "womendouyouyigejia" { visibleButton("key-" + String(letter), in: root).sendActions(for: .primaryActionTriggered) }
        await waitForCandidate("candidate-我们都有一个家", in: root)
        XCTAssertEqual(editor.text, priorDraft, "A suggestion must not insert text before selection")
        visibleButton("pinyin-expand-candidates", in: root).sendActions(for: .primaryActionTriggered)
        host.view.layoutIfNeeded(); root.layoutIfNeeded()
        XCTAssertFalse(descendants(root).contains { $0.accessibilityIdentifier == "grid-candidate-我们都有一个家" })
        visibleButton("grid-candidate-我们", in: root).sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(editor.text, priorDraft + "我们")
        XCTAssertEqual(label.text, "douyouyigejia", "A word selection must retain the unmatched spelling")
        space.sendActions(for: .primaryActionTriggered)

        let longSpelling = String(repeating: "nihao", count: 11)
        for letter in longSpelling { visibleButton("key-" + String(letter), in: root).sendActions(for: .primaryActionTriggered) }
        let scroll = descendants(root).first { $0.accessibilityIdentifier == "pinyin-candidates" } as! UIScrollView
        func stripButtons() -> [UIButton] {
            descendants(scroll).compactMap { $0 as? UIButton }.filter { !$0.isHidden }
        }
        for _ in 0..<600 {
            if !stripButtons().isEmpty { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        host.view.layoutIfNeeded(); root.layoutIfNeeded()
        XCTAssertEqual(label.text, longSpelling)
        let buttons = stripButtons()
        XCTAssertGreaterThan(buttons.count, 1)
        XCTAssertGreaterThan(buttons.first?.title(for: .normal)?.count ?? 0, 15)
        for button in buttons {
            XCTAssertGreaterThan(button.bounds.width, 0)
            XCTAssertLessThanOrEqual(button.bounds.width, scroll.bounds.width + 1)
            XCTAssertEqual(button.titleLabel?.numberOfLines, 1)
            XCTAssertEqual(button.titleLabel?.lineBreakMode, .byTruncatingTail)
            XCTAssertEqual(button.titleLabel?.text, button.title(for: .normal))
            XCTAssertGreaterThan(button.titleLabel?.bounds.width ?? 0, 10)
            XCTAssertGreaterThanOrEqual(button.titleLabel?.frame.minX ?? -1, 0)
            XCTAssertLessThanOrEqual(button.titleLabel?.frame.maxX ?? .infinity, button.bounds.width + 0.5)
        }
        for (previous, next) in zip(buttons, buttons.dropFirst()) {
            XCTAssertLessThanOrEqual(previous.frame.maxX, next.frame.minX + 0.5, "Candidate controls must not overlap")
        }
        visibleButton("pinyin-expand-candidates", in: root).sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(stripButtons().count, 1, "The expanded header must show just the primary suggestion")
        host.view.layoutIfNeeded(); root.layoutIfNeeded()
        try? await Task.sleep(nanoseconds: 100_000_000)
        host.view.layoutIfNeeded(); root.layoutIfNeeded()
        let focusedImage = UIGraphicsImageRenderer(size: root.bounds.size).image { _ in
            root.drawHierarchy(in: root.bounds, afterScreenUpdates: true)
        }
        let focusedAttachment = XCTAttachment(image: focusedImage)
        focusedAttachment.name = "Long pinyin primary and short alternatives"; focusedAttachment.lifetime = .keepAlways; add(focusedAttachment)
    }

    @MainActor func testReturnKeepsLettersAndLineDeleteRemovesLines() {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let previousKeyWindow = scene?.windows.first { $0.isKeyWindow }
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
        let host = UIViewController(); host.overrideUserInterfaceStyle = .dark
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previousKeyWindow?.makeKeyAndVisible() }
        host.loadViewIfNeeded()
        let controller = KeyboardViewController(); controller.loadViewIfNeeded()
        host.addChild(controller)
        let root = controller.view!; root.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: host.view.topAnchor),
            root.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            root.heightAnchor.constraint(equalToConstant: 440)
        ])
        controller.didMove(toParent: host)
        controller.showHotwordEditor(HotwordFile(id: "hot", name: "hot.txt", text: "第一行\n第二行", revision: "fixture", writable: true))
        host.view.layoutIfNeeded(); root.layoutIfNeeded()
        let editor = descendants(root).first { $0.accessibilityIdentifier == "hotword-editor-text" } as! UITextView
        for letter in "abc" { visibleButton("key-" + String(letter), in: root).sendActions(for: .primaryActionTriggered) }
        XCTAssertEqual(editor.text, "第一行\n第二行", "Typed pinyin letters stay in the composition")
        visibleButton("keyboard-return", in: root).sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(editor.text, "第一行\n第二行abc", "Return keeps the typed letters as English")
        visibleButton("keyboard-return", in: root).sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(editor.text, "第一行\n第二行abc\n", "Return is a line break when nothing is being typed")
        let lineDelete = visibleButton("keyboard-delete-line", in: root)
        lineDelete.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(editor.text, "第一行\n", "The line and its own line break go together")
        for letter in "xy" { visibleButton("key-" + String(letter), in: root).sendActions(for: .primaryActionTriggered) }
        visibleButton("keyboard-delete-line", in: root).sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(editor.text, "第一行\n", "Line delete first clears letters still being typed")
        visibleButton("keyboard-delete-line", in: root).sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(editor.text, "")
        visibleButton("keyboard-delete-line", in: root).sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(editor.text, "", "Nothing left to delete")
    }

    @MainActor func testHotwordBrowserRespectsWritableFileFlag() {
        let manager = HotwordManagerView(frame: CGRect(x: 0, y: 0, width: 430, height: 272))
        let files = [HotwordFile(id: "hot", name: "hot.txt", text: "CapsWriter", revision: "a", writable: true),
                     HotwordFile(id: "asr", name: "hot-server.txt", text: "演示", revision: "b", writable: false)]
        var editedID: String?
        manager.onEdit = { editedID = $0.id }
        manager.show(files: files)
        let edit = descendants(manager).first { $0.accessibilityIdentifier == "hotword-edit" } as! UIButton
        XCTAssertTrue(edit.isEnabled)
        edit.sendActions(for: .touchUpInside)
        XCTAssertEqual(editedID, "hot")
        manager.show(files: files, selectedID: "asr")
        XCTAssertFalse(edit.isEnabled)
        let content = descendants(manager).first { $0.accessibilityIdentifier == "hotword-file-content" } as! UITextView
        XCTAssertEqual(content.text, "演示")
        XCTAssertFalse(content.isEditable)
    }

    @MainActor private func isVisible(_ identifier: String, in root: UIView) -> Bool {
        descendants(root).contains { view in
            guard view.accessibilityIdentifier == identifier else { return false }
            var current: UIView? = view
            while let item = current {
                if item.isHidden || item.accessibilityElementsHidden { return false }
                current = item.superview
            }
            return true
        }
    }

    @MainActor private func visibleButton(_ identifier: String, in root: UIView) -> UIButton {
        let match = descendants(root).first { view in
            guard view.accessibilityIdentifier == identifier else { return false }
            var current: UIView? = view
            while let item = current {
                if item.isHidden || item.accessibilityElementsHidden { return false }
                current = item.superview
            }
            return true
        }
        XCTAssertNotNil(match, "Missing visible button: " + identifier)
        return match as! UIButton
    }

    @MainActor private func waitForCandidate(_ identifier: String, in root: UIView) async {
        for _ in 0..<300 {
            if descendants(root).contains(where: { $0.accessibilityIdentifier == identifier && !$0.isHidden }) { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(identifier)")
    }

    @MainActor private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}
