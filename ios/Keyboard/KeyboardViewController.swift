import UIKit
import SwiftUI

private final class KeyboardPagingScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

final class KeyboardViewController: UIInputViewController, UIScrollViewDelegate {
    /// Page order, left to right. English is the page the keyboard opens on.
    private enum Mode: Int { case english, voice, pinyin }
    private var mode: Mode = .english
    private var shiftState = ShiftState.off
    private var lastShiftTap = Date.distantPast
    private var symbols = false
    private var extraSymbols = false
    private var composition = ""
    private lazy var pinyin = PinyinEngine()
    private let candidateQueue = DispatchQueue(label: "org.capswriterlab.pinyin", qos: .userInitiated)
    private let candidateLock = NSLock()
    private var candidateGeneration = 0
    private var displayedComposition = ""
    private let content = UIStackView()
    private let pager = KeyboardPagingScrollView()
    private let pageStrip = UIStackView()
    private weak var modeSelector: UISegmentedControl?
    /// Second row while pinyin is being typed: spelling, candidates, expand.
    private weak var pinyinLine: UIStackView?
    private var pageWidth: CGFloat = 0
    private var centeringPages = false
    private var changingPage = false
    private var heightConstraint: NSLayoutConstraint?
    private weak var globe: UIButton?
    private weak var feedback: UILabel?
    private weak var candidateRow: UIStackView?
    private weak var candidateScroll: UIScrollView?
    private var candidateWidths: [NSLayoutConstraint] = []
    private weak var compositionLabel: UILabel?
    private var lastSpaceAt = Date.distantPast
    private var spaceCommittedComposition = false
    private weak var expandCandidatesButton: UIButton?
    private let candidateGrid = UIScrollView()
    private let candidateGridRows = UIStackView()
    private var candidatesExpanded = false
    private var displayedCandidates: [PinyinCandidate] = []
    private var gridLayoutWidth: CGFloat = 0
    private weak var switchFooter: UIStackView?
    private var showsSwitchFooter = false
    private weak var hotEditor: UITextView?
    private weak var hotEditorBar: UIStackView?
    private var hotRevision = ""
    private var hotFileID = "hot"
    /// File text the phone's new words are appended to; nil when editing the whole file.
    private var hotAppendBase: String?
    private var hotPairing: BridgePairing?
    private var hotRequest = UUID()
    private weak var hotManager: HotwordManagerView?
    private weak var hotEditorStatus: UILabel?
    private weak var hotSaveButton: UIButton?
    private weak var hotCancelButton: UIButton?
    private weak var hotAddButton: UIButton?
    private var hotSaving = false
    private var previewedText: String?
    private var bridgeRequestID = UUID()
    private var bridgePairing: BridgePairing?
    private var voicePairing: BridgePairing?
    private var voiceID: String?
    private var voiceState = "idle"
    private var voiceDelivery = VoiceResultDelivery()
    private var voiceMessage = "Tap to speak" {
        didSet { if voiceMessage != oldValue { voiceMessageAt = Date() } }
    }
    /// When the status text last changed; the letter pages show it briefly.
    private var voiceMessageAt = Date.distantPast
    private var statusClearStamp: Date?
    private weak var brandLabel: UILabel?
    private weak var headerMic: UIButton?
    /// Live draft from the service's streaming model while recording. Shown in
    /// the hint line only; the accurate final text is what gets inserted.
    private var voiceDraft = ""
    private var draftPlacement = VoiceDraftPlacement.load()
    /// The draft currently placed in the text field as marked text.
    private var inlineDraft = InlineVoiceDraft()
    private var voiceTimer: Timer?
    private var voiceBusy = false
    private var voicePolling = false
    /// First failed result poll in the current run of failures.
    private var voiceFailureSince: Date?
    private var voiceRevision = UUID()
    private weak var voiceHint: UILabel?
    private weak var voiceButton: UIButton?
    private weak var voiceContainer: UIView?
    private var voiceIntentHost: UIViewController?
    private var voiceAgentReady: Bool?
    private var readinessTimer: Timer?
    private var readinessRequest = UUID()
    private var readinessPolling = false
    private var intentWarmupID: UUID?
    private var intentWarmupDocumentID: UUID?
    private var voiceStarted = Date.distantPast
    private var autoNewline = AutoNewlineMode.load()
    private var voiceUndo = VoiceUndoRecord()
    private weak var undoButton: UIButton?
    private weak var newlineButton: UIButton?
    private var resumeRequest: UUID?
    private var appeared = false
    private var deleteTimer: Timer?
    private var deleteStarted = Date.distantPast
    private weak var deleteGesture: UILongPressGestureRecognizer?
    private var deletingLines = false
    private var suggester: WordSuggestions?
    private var suggesterLoading = false
    private let suggestionScroll = KeyboardPagingScrollView()
    private let suggestionRow = UIStackView()
    private var suggestions: [WordSuggestion] = []
    private var suggestionRefreshPending = false
    /// The last insert was a tapped suggestion that added its own space.
    private var suggestionSpace = false

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        appeared = false
        stopVoiceReadiness()
        cancelIntentWarmup()
        removeVoiceIntentControl()
        stopDeleting()
        resumeRequest = nil
        // Never leave a draft behind in a field the keyboard no longer sees;
        // a result that finishes meanwhile is inserted on return as usual.
        clearInlineDraft()
        voiceTimer?.invalidate(); voiceTimer = nil
        if voiceID == nil { voiceRevision = UUID(); voiceBusy = false }
        if ["pending", "recording"].contains(voiceState) { cancelVoice() }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
        voiceAgentReady = nil
        if hasFullAccess { BridgePairingStore.markKeyboardReady() }
        refreshBridgePairing()
        updatePreferredHeight()
        insertVoiceResultIfReady()
        scheduleSuggestions()
        if voiceID != nil && ["stopping", "processing"].contains(voiceState) { scheduleVoicePoll() }
        updateVoice(); startVoiceReadiness()
        resumeAfterRenewalIfNeeded()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Lab.background
        heightConstraint = view.heightAnchor.constraint(equalToConstant: 272)
        heightConstraint?.priority = .defaultHigh; heightConstraint?.isActive = true
        content.axis = .vertical; content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12)
        ])
        render()
    }
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        // The cursor moved or the host changed the text: suggest for the new place.
        scheduleSuggestions()
    }
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        if appeared { updatePreferredHeight() }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = pager.bounds.width
        layoutPages(center: width > 0 && abs(width - pageWidth) > 0.5)
        let gridWidth = candidateGrid.bounds.width
        if candidatesExpanded && gridWidth > 0 && abs(gridWidth - gridLayoutWidth) > 0.5 {
            rebuildCandidateGrid()
        }
    }
    private func updatePreferredHeight() {
        showsSwitchFooter = appeared && extensionContext != nil && needsInputModeSwitchKey
        switchFooter?.isHidden = !showsSwitchFooter
        globe?.isHidden = !showsSwitchFooter
        // Every page has the same three regions: button bar, suggestion
        // strip, keys. The voice page keeps the strip empty, so switching
        // pages never changes the panel's height.
        let height: CGFloat = 310 + (showsSwitchFooter ? 52 : 0) + (hotEditor == nil ? 0 : 144)
        if heightConstraint?.constant != height {
            heightConstraint?.constant = height
            view.invalidateIntrinsicContentSize(); view.setNeedsLayout()
        }
    }
    private func layoutPages(center: Bool) {
        let width = pager.bounds.width
        guard width > 0, pager.bounds.height > 0 else { return }
        // The strip is constrained to the viewport height, including the cold
        // extension's first resize. It cannot acquire vertical scroll content.
        pageStrip.layoutIfNeeded()
        pageWidth = width
        if center {
            centeringPages = true
            pager.setContentOffset(CGPoint(x: width, y: 0), animated: false)
            centeringPages = false
        }
        if pager.contentOffset.y != 0 { pager.contentOffset.y = 0 }
    }
    private func changeMode(_ next: Mode) {
        guard !hotSaving else { modeSelector?.selectedSegmentIndex = mode.rawValue; return }
        if hotEditor != nil && next == .voice { modeSelector?.selectedSegmentIndex = mode.rawValue; return }
        guard next != mode, !changingPage, !pager.isDragging, !pager.isDecelerating else {
            modeSelector?.selectedSegmentIndex = mode.rawValue; return
        }
        stopDeleting()
        animatePage((next.rawValue - mode.rawValue + 3) % 3 == 1 ? 2 : 0)
    }
    private func animatePage(_ index: Int) {
        guard pageWidth > 0 else { return }
        let destination = CGFloat(index) * pageWidth
        if abs(pager.contentOffset.x - destination) < 0.5 {
            finishPage(); return
        }
        changingPage = true
        if UIAccessibility.isReduceMotionEnabled {
            pager.setContentOffset(CGPoint(x: destination, y: 0), animated: false)
            finishPage()
        } else { pager.setContentOffset(CGPoint(x: destination, y: 0), animated: true) }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishPage() }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { stopDeleting() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { finishPage() }
    }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { finishPage() }
    private func finishPage() {
        guard !centeringPages, pageWidth > 0 else { return }
        changingPage = false
        let index = max(0, min(2, Int((pager.contentOffset.x / pageWidth).rounded())))
        guard index != 1 else { modeSelector?.selectedSegmentIndex = mode.rawValue; return }
        let next = pageMode(offset: index == 2 ? 1 : 2)
        if mode == .pinyin && next != .pinyin { commitComposition() }
        // A recording keeps running across pages: it can be started and
        // stopped from the header microphone on the letter pages too.
        mode = next; shiftState = .off; symbols = false; extraSymbols = false; render()
    }
    private func row(_ views: [UIView], equal: Bool = true) -> UIStackView {
        let row = UIStackView(arrangedSubviews: views); row.spacing = 5
        if equal { row.distribution = .fillEqually }; return row
    }
    private func key(_ title: String, symbol: String? = nil, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title; configuration.baseBackgroundColor = Lab.surface
        configuration.baseForegroundColor = .white; configuration.imagePadding = 8
        if let symbol = symbol { configuration.image = UIImage(systemName: symbol) }
        let button = KeyboardKeyButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.configuration?.cornerStyle = .medium
        button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 2, bottom: 6, trailing: 2)
        button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { input in
            var output = input; output.font = UIFont.systemFont(ofSize: 23); return output
        }
        button.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 22)
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true; return button
    }
    private func keyRow(_ views: [UIView], equal: Bool = true) -> KeyboardKeyRow {
        let result = KeyboardKeyRow(arrangedSubviews: views); result.spacing = 5
        if equal { result.distribution = .fillEqually }
        return result
    }
    /// The page `offset` steps to the right. While the hotword editor is open
    /// there is no voice page, so swiping just flips between EN and 拼.
    private func pageMode(offset: Int) -> Mode {
        let next = Mode(rawValue: (mode.rawValue + offset) % 3) ?? .voice
        guard hotEditor != nil, next == .voice else { return next }
        return mode == .pinyin ? .english : .pinyin
    }
    private func render() {
        stopDeleting()
        removeVoiceIntentControl()
        if mode != .voice { cancelIntentWarmup() }
        if content.arrangedSubviews.isEmpty { buildChrome() }
        centeringPages = true
        for item in pageStrip.arrangedSubviews { pageStrip.removeArrangedSubview(item); item.removeFromSuperview() }
        for (index, delta) in [2, 0, 1].enumerated() {
            let pageMode = self.pageMode(offset: delta)
            let page = UIStackView(); page.axis = .vertical; page.spacing = 8
            page.isUserInteractionEnabled = index == 1; page.accessibilityElementsHidden = index != 1
            page.addArrangedSubview(UIView())
            if pageMode == .voice { renderVoice(content: page) } else { renderLetters(mode: pageMode, content: page) }
            pageStrip.addArrangedSubview(page)
        }
        modeSelector?.selectedSegmentIndex = mode.rawValue
        view.layoutIfNeeded(); layoutPages(center: true)
        centeringPages = false; updateCandidates(); updateVoice()
        if appeared && (mode == .voice || readinessTimer == nil) { startVoiceReadiness() }
    }
    private func buildChrome() {
        let brand = Lab.label("◖ SayKey", size: 19); brand.font = .boldSystemFont(ofSize: 19)
        brand.numberOfLines = 1; brand.lineBreakMode = .byTruncatingTail
        brand.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        brand.accessibilityIdentifier = "keyboard-brand"
        brandLabel = brand
        let selector = UISegmentedControl(items: ["EN", "", "拼"])
        selector.setImage(UIImage(systemName: "waveform"), forSegmentAt: Mode.voice.rawValue)
        selector.backgroundColor = UIColor(white: 0.13, alpha: 1)
        selector.selectedSegmentTintColor = UIColor(white: 0.28, alpha: 1)
        selector.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        selector.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        selector.selectedSegmentIndex = mode.rawValue
        modeSelector = selector
        selector.accessibilityIdentifier = "keyboard-mode-selector"
        selector.addAction(UIAction { [weak self, weak selector] _ in
            self?.changeMode(Mode(rawValue: selector?.selectedSegmentIndex ?? 0) ?? .voice)
        }, for: .valueChanged)
        selector.widthAnchor.constraint(equalToConstant: 126).isActive = true
        // Small and only shown when there is something to undo, so it never
        // looks like the auto-newline key on the voice page.
        var undoConfig = UIButton.Configuration.tinted()
        undoConfig.title = "撤回"; undoConfig.image = UIImage(systemName: "arrow.uturn.backward")
        undoConfig.imagePadding = 3; undoConfig.cornerStyle = .capsule; undoConfig.baseForegroundColor = .systemOrange
        undoConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        undoConfig.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8)
        undoConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { input in
            var output = input; output.font = .systemFont(ofSize: 13, weight: .semibold); return output
        }
        let undo = UIButton(configuration: undoConfig, primaryAction: UIAction { [weak self] _ in self?.undoVoiceInsert() })
        undo.accessibilityIdentifier = "keyboard-voice-undo"
        undo.accessibilityLabel = "撤回上一段语音"
        undo.isHidden = true; undoButton = undo
        // Starts and stops voice input from the letter pages; the voice page
        // has its own large microphone, so this one is hidden there.
        let mic = Lab.button("", symbol: "mic.fill") { [weak self] in self?.tapVoice() }
        mic.configuration?.baseBackgroundColor = UIColor(white: 0.94, alpha: 1)
        mic.configuration?.baseForegroundColor = .black
        mic.configuration?.contentInsets = .zero
        mic.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        mic.widthAnchor.constraint(equalToConstant: 52).isActive = true
        mic.heightAnchor.constraint(equalToConstant: 30).isActive = true
        mic.accessibilityIdentifier = "keyboard-header-mic"
        headerMic = mic
        // Takes the whole SayKey panel off the screen so the text behind it
        // can be read. Tapping the text field brings it back.
        let hide = Lab.button("", symbol: "keyboard.chevron.compact.down") { [weak self] in self?.hidePanel() }
        hide.configuration?.contentInsets = .zero
        hide.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 15)
        hide.widthAnchor.constraint(equalToConstant: 38).isActive = true
        hide.heightAnchor.constraint(equalToConstant: 30).isActive = true
        hide.accessibilityIdentifier = "keyboard-hide"
        hide.accessibilityLabel = "收起 SayKey"
        hide.accessibilityHint = "收起后点一下输入框即可再次打开"
        let headerSpace = UIView()
        headerSpace.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        // The hide button is the right-most control; the page selector sits
        // to its left. This row never changes, whatever is being typed.
        let header = row([brand, undo, headerSpace, mic, selector, hide], equal: false); header.alignment = .center
        let headerHeight = header.heightAnchor.constraint(equalToConstant: 32)
        headerHeight.priority = .defaultHigh; headerHeight.isActive = true
        content.addArrangedSubview(header)
        // Second row, present on every page. Letter pages show next-word
        // suggestions here, or the pinyin being typed with its candidates.
        // The voice page leaves it empty apart from the line delete key.
        let composition = Lab.label("", size: 15, color: Lab.muted)
        composition.accessibilityIdentifier = "pinyin-composition"
        composition.numberOfLines = 1
        // A long spelling keeps its newest letters in view.
        composition.lineBreakMode = .byTruncatingHead
        composition.setContentHuggingPriority(.required, for: .horizontal)
        composition.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        compositionLabel = composition
        let candidatesScroll = KeyboardPagingScrollView(); candidatesScroll.showsHorizontalScrollIndicator = false
        candidatesScroll.delaysContentTouches = false
        candidatesScroll.accessibilityIdentifier = "pinyin-candidates"; candidateScroll = candidatesScroll
        let candidates = UIStackView(); candidates.axis = .horizontal; candidates.spacing = 6
        candidates.translatesAutoresizingMaskIntoConstraints = false; candidatesScroll.addSubview(candidates)
        candidateRow = candidates
        let expand = Lab.button("", symbol: "chevron.down") { [weak self] in
            guard let self = self else { return }; self.setCandidatesExpanded(!self.candidatesExpanded)
        }
        expand.configuration?.contentInsets = .zero
        expand.widthAnchor.constraint(equalToConstant: 30).isActive = true
        expand.accessibilityIdentifier = "pinyin-expand-candidates"
        expand.setContentCompressionResistancePriority(UILayoutPriority(600), for: .vertical)
        expandCandidatesButton = expand
        let candidateLine = row([composition, candidatesScroll, expand], equal: false)
        candidateLine.spacing = 6
        candidateLine.accessibilityIdentifier = "pinyin-candidate-line"
        candidateLine.isHidden = true; pinyinLine = candidateLine
        suggestionScroll.showsHorizontalScrollIndicator = false
        suggestionScroll.delaysContentTouches = false
        suggestionScroll.accessibilityIdentifier = "suggestion-bar"
        suggestionRow.axis = .horizontal; suggestionRow.spacing = 6
        suggestionRow.translatesAutoresizingMaskIntoConstraints = false; suggestionScroll.addSubview(suggestionRow)
        suggestionScroll.isHidden = true
        let stripContent = UIView()
        for item in [suggestionScroll, candidateLine] as [UIView] {
            item.translatesAutoresizingMaskIntoConstraints = false; stripContent.addSubview(item)
            NSLayoutConstraint.activate([
                item.topAnchor.constraint(equalTo: stripContent.topAnchor),
                item.bottomAnchor.constraint(equalTo: stripContent.bottomAnchor),
                item.leadingAnchor.constraint(equalTo: stripContent.leadingAnchor),
                item.trailingAnchor.constraint(equalTo: stripContent.trailingAnchor)
            ])
        }
        // Directly below the hide button and away from the letter keys, so
        // a whole line is not deleted by a slip of the thumb.
        let lineDelete = lineDeleteKey()
        lineDelete.setContentCompressionResistancePriority(UILayoutPriority(600), for: .vertical)
        let strip = row([stripContent, lineDelete], equal: false)
        strip.accessibilityIdentifier = "keyboard-strip"
        // Below the header's priority: when the host squeezes the keyboard,
        // the strip gives up its room before any key does.
        let stripHeight = strip.heightAnchor.constraint(equalToConstant: 30)
        stripHeight.priority = UILayoutPriority(700)
        NSLayoutConstraint.activate([
            candidates.topAnchor.constraint(equalTo: candidatesScroll.contentLayoutGuide.topAnchor),
            candidates.bottomAnchor.constraint(equalTo: candidatesScroll.contentLayoutGuide.bottomAnchor),
            candidates.leadingAnchor.constraint(equalTo: candidatesScroll.contentLayoutGuide.leadingAnchor),
            candidates.trailingAnchor.constraint(equalTo: candidatesScroll.contentLayoutGuide.trailingAnchor),
            candidates.heightAnchor.constraint(equalTo: candidatesScroll.frameLayoutGuide.heightAnchor),
            composition.widthAnchor.constraint(lessThanOrEqualTo: candidateLine.widthAnchor, multiplier: 0.34),
            suggestionRow.topAnchor.constraint(equalTo: suggestionScroll.contentLayoutGuide.topAnchor),
            suggestionRow.bottomAnchor.constraint(equalTo: suggestionScroll.contentLayoutGuide.bottomAnchor),
            suggestionRow.leadingAnchor.constraint(equalTo: suggestionScroll.contentLayoutGuide.leadingAnchor),
            suggestionRow.trailingAnchor.constraint(equalTo: suggestionScroll.contentLayoutGuide.trailingAnchor),
            suggestionRow.heightAnchor.constraint(equalTo: suggestionScroll.frameLayoutGuide.heightAnchor),
            lineDelete.widthAnchor.constraint(equalToConstant: 38),
            stripHeight
        ])
        content.addArrangedSubview(strip)
        pager.delegate = self; pager.isPagingEnabled = true; pager.bounces = false
        pager.alwaysBounceVertical = false; pager.showsVerticalScrollIndicator = false
        pager.showsHorizontalScrollIndicator = false; pager.isDirectionalLockEnabled = true
        pager.delaysContentTouches = false; pager.canCancelContentTouches = true
        pager.contentInsetAdjustmentBehavior = .never; pager.clipsToBounds = true
        pager.accessibilityIdentifier = "keyboard-pages"
        pageStrip.axis = .horizontal; pageStrip.spacing = 0; pageStrip.distribution = .fillEqually
        pageStrip.translatesAutoresizingMaskIntoConstraints = false
        pager.addSubview(pageStrip)
        NSLayoutConstraint.activate([
            pageStrip.topAnchor.constraint(equalTo: pager.contentLayoutGuide.topAnchor),
            pageStrip.bottomAnchor.constraint(equalTo: pager.contentLayoutGuide.bottomAnchor),
            pageStrip.leadingAnchor.constraint(equalTo: pager.contentLayoutGuide.leadingAnchor),
            pageStrip.trailingAnchor.constraint(equalTo: pager.contentLayoutGuide.trailingAnchor),
            pageStrip.widthAnchor.constraint(equalTo: pager.frameLayoutGuide.widthAnchor, multiplier: 3),
            pageStrip.heightAnchor.constraint(equalTo: pager.frameLayoutGuide.heightAnchor)
        ])
        content.addArrangedSubview(pager)
        candidateGrid.backgroundColor = Lab.background
        candidateGrid.accessibilityIdentifier = "pinyin-candidate-grid"
        candidateGrid.isHidden = true; candidateGrid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(candidateGrid)
        candidateGridRows.axis = .vertical; candidateGridRows.spacing = 1
        candidateGridRows.translatesAutoresizingMaskIntoConstraints = false; candidateGrid.addSubview(candidateGridRows)
        NSLayoutConstraint.activate([
            candidateGrid.topAnchor.constraint(equalTo: pager.topAnchor),
            candidateGrid.bottomAnchor.constraint(equalTo: pager.bottomAnchor),
            candidateGrid.leadingAnchor.constraint(equalTo: pager.leadingAnchor),
            candidateGrid.trailingAnchor.constraint(equalTo: pager.trailingAnchor),
            candidateGridRows.topAnchor.constraint(equalTo: candidateGrid.contentLayoutGuide.topAnchor),
            candidateGridRows.bottomAnchor.constraint(equalTo: candidateGrid.contentLayoutGuide.bottomAnchor),
            candidateGridRows.leadingAnchor.constraint(equalTo: candidateGrid.contentLayoutGuide.leadingAnchor),
            candidateGridRows.trailingAnchor.constraint(equalTo: candidateGrid.contentLayoutGuide.trailingAnchor),
            candidateGridRows.widthAnchor.constraint(equalTo: candidateGrid.frameLayoutGuide.widthAnchor)
        ])
        let globe = key("", symbol: "globe") {}
        globe.isHidden = true
        globe.accessibilityLabel = "切换键盘，按住选择输入法"
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        globe.widthAnchor.constraint(equalToConstant: 45).isActive = true; self.globe = globe
        let note = Lab.label("", size: 10, color: Lab.muted)
        note.textAlignment = .center; self.feedback = note
        let footer = row([globe, note], equal: false)
        footer.isHidden = true; switchFooter = footer; content.addArrangedSubview(footer)
    }
    private func renderVoice(content: UIStackView) {
        let hint = Lab.label(voiceMessage, size: 14, color: Lab.muted)
        hint.numberOfLines = 1
        hint.heightAnchor.constraint(equalToConstant: 22).isActive = true
        hint.lineBreakMode = .byTruncatingTail
        hint.textAlignment = .center; content.addArrangedSubview(hint)
        hint.isUserInteractionEnabled = true
        hint.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(hintTapped)))
        hint.accessibilityTraits.insert(.button)
        hint.accessibilityHint = "切换实时草稿显示位置"
        voiceHint = hint
        let mic = Lab.button("", symbol: "mic.fill") { [weak self] in self?.tapVoice() }
        mic.configuration?.baseBackgroundColor = UIColor(white: 0.94, alpha: 1)
        mic.configuration?.baseForegroundColor = .black
        mic.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 35)
        mic.accessibilityIdentifier = "keyboard-voice-button"
        mic.widthAnchor.constraint(equalToConstant: 152).isActive = true
        mic.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        mic.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let container = UIView()
        mic.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(mic)
        NSLayoutConstraint.activate([
            mic.topAnchor.constraint(equalTo: container.topAnchor), mic.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            mic.leadingAnchor.constraint(equalTo: container.leadingAnchor), mic.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        voiceButton = mic; voiceContainer = container; updateVoice()
        let micLeft = UIView(), micRight = UIView()
        let micRow = row([micLeft, container, micRight], equal: false)
        content.addArrangedSubview(micRow)
        micLeft.widthAnchor.constraint(equalTo: micRight.widthAnchor).isActive = true
        content.addArrangedSubview(keyRow([
            key("space") { [weak self] in self?.space() },
            key("@") { [weak self] in self?.input("@") }, deleteKey()
        ]))
        let enter = returnKey(); enter.widthAnchor.constraint(equalToConstant: 152).isActive = true
        let left = UIView(), right = UIView()
        let hotwords = key("", symbol: "text.badge.plus") { [weak self] in self?.openHotwords() }
        hotwords.accessibilityIdentifier = "keyboard-hotwords"
        hotwords.accessibilityLabel = "查看与编辑热词"
        hotwords.translatesAutoresizingMaskIntoConstraints = false; right.addSubview(hotwords)
        let newline = key("", symbol: "arrow.turn.down.left") { [weak self] in self?.toggleAutoNewline() }
        newline.accessibilityIdentifier = "keyboard-auto-newline"
        newlineButton = newline
        let leftKeys = UIStackView(arrangedSubviews: [newline]); leftKeys.spacing = 5
        leftKeys.translatesAutoresizingMaskIntoConstraints = false; left.addSubview(leftKeys)
        let lastRow = row([left, enter, right], equal: false)
        NSLayoutConstraint.activate([
            left.widthAnchor.constraint(equalTo: right.widthAnchor),
            leftKeys.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            leftKeys.centerYAnchor.constraint(equalTo: left.centerYAnchor),
            leftKeys.trailingAnchor.constraint(lessThanOrEqualTo: left.trailingAnchor),
            newline.widthAnchor.constraint(equalToConstant: 44),
            hotwords.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            hotwords.centerYAnchor.constraint(equalTo: right.centerYAnchor),
            hotwords.widthAnchor.constraint(equalToConstant: 44)
        ])
        content.addArrangedSubview(lastRow)
        updateVoiceEditKeys()
    }

    private func voiceCall(_ path: String, value: [String: Any]? = nil, jobID: String? = nil,
                           completion: @escaping (Result<BridgeReply, Error>) -> Void) {
        BridgeClient.call(pairing: voicePairing,
                          path: path, value: value, jobID: jobID, completion: completion)
    }

    private func refreshBridgePairing() {
        let next = hasFullAccess ? BridgePairingStore.activePairing() : nil
        guard bridgePairing != next else { return }
        bridgePairing = next
        readinessRequest = UUID(); readinessPolling = false; voiceAgentReady = nil
        cancelIntentWarmup()
        if voicePairing != nil { cancelVoice() }
        hotRequest = UUID(); bridgeRequestID = UUID(); previewedText = nil
        hotManager?.removeFromSuperview()
        if hotEditor != nil {
            setHotSaving(false)
            hotEditorStatus?.text = "识别服务已切换，草稿仍保留。请切回原服务后保存。"
        }
        viewIfLoaded?.viewWithTag(700)?.removeFromSuperview()
    }

    private func tapVoice() {
        guard hasFullAccess else { voiceMessage = "请在键盘设置允许完全访问，再点击录音。"; updateVoice(); return }
        refreshBridgePairing()
        guard !voiceBusy else { return }
        if voiceState == "recording", let id = voiceID {
            voiceRevision = UUID(); let revision = voiceRevision; voicePolling = false
            voiceBusy = true; voiceMessage = "正在结束录音…"; updateVoice()
            voiceCall("/v1/voice/stop", value: ["id": id]) { [weak self] result in
                guard let self = self, self.voiceID == id, self.voiceRevision == revision else { return }
                self.voiceBusy = false
                if case .failure(let error) = result, BridgeError.isTransient(error) {
                    // Recording keeps going on the phone; let the user tap stop again.
                    self.voiceMessage = "网络不稳，停止未送达 · 请再点一次停止"; self.updateVoice(); return
                }
                self.handleVoice(result)
            }
            return
        }
        guard !["pending", "stopping", "processing"].contains(voiceState) else { return }
        resumeRequest = nil
        guard let pairing = bridgePairing else {
            voiceMessage = "请在 Lab 配对识别服务。"; updateVoice(); return
        }
        // Lab extends its session each time a recording starts, so a live
        // session always has room. Only a lapsed one needs a trip to Lab.
        // Not known to be on: go straight to Lab without asking the computer
        // first. If Lab was already running it sends the user back at once.
        if voiceAgentReady != true && canOpenContainingApp { renewSessionInLab(); return }
        guard voiceAgentReady == true else { checkSessionThenRecord(pairing); return }
        startRecording(pairing)
    }
    private func checkSessionThenRecord(_ pairing: BridgePairing) {
        voiceRevision = UUID(); let revision = voiceRevision
        voiceBusy = true; voiceMessage = "正在检查语音会话…"; updateVoice()
        BridgeClient.call(pairing: pairing, path: "/v1/status", timeout: 3) { [weak self] result in
            guard let self = self, self.voiceRevision == revision, self.voiceID == nil else { return }
            self.voiceBusy = false
            if case .success(let reply) = result {
                self.voiceAgentReady = reply.agent_ready == true
                if reply.voice_enabled == true && reply.agent_ready != true { self.renewSessionInLab(); return }
            }
            // Unknown (network) state: try anyway; a failure shows its own message.
            self.startRecording(pairing)
        }
    }
    private func renewSessionInLab() {
        let defaults = UserDefaults.standard
        defaults.set(Date().timeIntervalSince1970, forKey: VoiceSessionRenewal.pendingKey)
        if openContainingApp(VoiceSessionRenewal.url(returningTo: hostBundleID)) {
            voiceMessage = "正在打开 Lab 开启语音会话，马上回来…"
        } else {
            defaults.removeObject(forKey: VoiceSessionRenewal.pendingKey)
            voiceMessage = "语音会话已结束，请打开 SayKey Lab 重新开启。"
        }
        updateVoice()
    }
    /// Keyboards have no public API to open their containing app. Walk the
    /// responder chain to the host UIApplication and send it the open message
    /// dynamically (the typed method is unavailable to extensions).
    private func openContainingApp(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, current.responds(to: selector), let method = current.method(for: selector) {
                typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
                unsafeBitCast(method, to: Open.self)(current, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }
    /// The host app's bundle ID, when iOS still reports it, so Lab can send
    /// the user straight back. Newer iOS versions usually hide it.
    private var hostBundleID: String? {
        let key = "_hostBundleID"
        guard let parent = parent, parent.responds(to: NSSelectorFromString(key)),
              let id = parent.value(forKey: key) as? String,
              !id.isEmpty, id != "<null>", !id.hasPrefix("org.capswriterlab") else { return nil }
        return id
    }
    private var canOpenContainingApp: Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication { return current.responds(to: selector) }
            responder = current.next
        }
        return false
    }
    /// Coming back from Lab after a renewal continues the tap that sent the
    /// user there: wait briefly for the fresh session, then start recording.
    private func resumeAfterRenewalIfNeeded() {
        let defaults = UserDefaults.standard
        let requested = defaults.double(forKey: VoiceSessionRenewal.pendingKey)
        guard requested > 0 else { return }
        defaults.removeObject(forKey: VoiceSessionRenewal.pendingKey)
        guard Date().timeIntervalSince1970 - requested < VoiceSessionRenewal.resumeWindow,
              hasFullAccess, hotEditor == nil, voiceID == nil, voiceState == "idle",
              let pairing = BridgePairingStore.activePairing() else { return }
        let request = UUID(); resumeRequest = request
        voiceMessage = "语音会话已续上 · 正在开始录音…"; updateVoice()
        waitForSession(pairing, request: request, deadline: Date().addingTimeInterval(8))
    }
    private func waitForSession(_ pairing: BridgePairing, request: UUID, deadline: Date) {
        guard resumeRequest == request, appeared, voiceID == nil, voiceState == "idle", !voiceBusy else { return }
        guard Date() < deadline else {
            resumeRequest = nil
            voiceMessage = "Lab 还没开启语音会话，点麦克风重试。"; updateVoice(); return
        }
        BridgeClient.call(pairing: pairing, path: "/v1/status", timeout: 2) { [weak self] result in
            guard let self = self, self.resumeRequest == request else { return }
            if case .success(let reply) = result, reply.agent_ready == true {
                self.resumeRequest = nil; self.voiceAgentReady = true
                guard self.appeared, self.voiceID == nil, self.voiceState == "idle", !self.voiceBusy else { return }
                self.startRecording(pairing); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.waitForSession(pairing, request: request, deadline: deadline)
            }
        }
    }
    private func startRecording(_ pairing: BridgePairing) {
        voicePairing = pairing
        voiceRevision = UUID(); let revision = voiceRevision
        let documentID = textDocumentProxy.documentIdentifier
        voiceState = "pending"
        voiceBusy = true; voiceMessage = "正在连接语音会话…"; updateVoice()
        voiceCall("/v1/voice/start", value: [:]) { [weak self] result in
            guard let self = self else { return }
            guard self.voiceRevision == revision else {
                if case .success(let reply) = result, let id = reply.id {
                    BridgeClient.call(pairing: pairing, path: "/v1/voice/cancel", value: ["id": id]) { _ in }
                }
                return
            }
            self.voiceBusy = false
            if case .success(let reply) = result {
                self.voiceID = reply.id
                if let id = reply.id { self.voiceDelivery.begin(id, documentID: documentID) }
                self.voiceStarted = Date(); self.scheduleVoicePoll()
            }
            self.handleVoice(result)
        }
    }
    /// Session status is tracked on every page, so the header microphone
    /// knows whether it can record at once or must renew the session in Lab.
    private var canPollReadiness: Bool {
        appeared && hotEditor == nil && extensionContext != nil && hasFullAccess
    }
    private var canUseVoiceIntent: Bool {
        if #available(iOS 18.0, *) { return canPollReadiness && mode == .voice }
        return false
    }
    private func startVoiceReadiness() {
        guard canPollReadiness else { return }
        if readinessTimer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refreshVoiceReadiness() }
            readinessTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        refreshVoiceReadiness()
    }
    private func stopVoiceReadiness() {
        readinessTimer?.invalidate(); readinessTimer = nil
        readinessRequest = UUID(); readinessPolling = false
    }
    private func refreshVoiceReadiness() {
        guard canPollReadiness else { return }
        refreshBridgePairing()
        guard voiceID == nil, !voiceBusy, !readinessPolling else { return }
        readinessPolling = true; let request = readinessRequest
        BridgeClient.call(pairing: bridgePairing,
                          path: "/v1/status", timeout: 3) { [weak self] result in
            guard let self = self, self.readinessRequest == request else { return }
            self.readinessPolling = false
            if case .success(let reply) = result { self.voiceAgentReady = reply.agent_ready == true }
            else { self.voiceAgentReady = nil }
            self.updateVoice()
        }
    }
    private func updateVoiceIntentControl() {
        let showIntent = canUseVoiceIntent && voiceID == nil && voiceState == "idle"
            && (voiceAgentReady != true || intentWarmupID != nil) && !canOpenContainingApp
        guard showIntent, let container = voiceContainer else { removeVoiceIntentControl(); return }
        if #available(iOS 18.0, *) {
            let control = KeyboardVoiceIntentControl(isEnabled: !voiceBusy) { [weak self] in self?.beginIntentWarmup() }
            if let host = voiceIntentHost as? UIHostingController<KeyboardVoiceIntentControl> {
                host.rootView = control
            } else {
                let host = UIHostingController(rootView: control)
                voiceIntentHost = host; addChild(host)
                host.view.backgroundColor = .clear; host.view.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(host.view)
                NSLayoutConstraint.activate([
                    host.view.topAnchor.constraint(equalTo: container.topAnchor), host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                    host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor)
                ])
                host.didMove(toParent: self)
            }
            voiceButton?.isHidden = true
            voiceButton?.accessibilityElementsHidden = true
            if voiceMessage == "Tap to speak" { voiceHint?.text = "后台启动实验 · 点击麦克风" }
        }
    }
    private func removeVoiceIntentControl() {
        voiceIntentHost?.willMove(toParent: nil)
        voiceIntentHost?.view.removeFromSuperview(); voiceIntentHost?.removeFromParent(); voiceIntentHost = nil
        voiceButton?.isHidden = false; voiceButton?.accessibilityElementsHidden = false
    }
    private func cancelIntentWarmup() {
        if intentWarmupID != nil && voiceID == nil { voiceBusy = false }
        intentWarmupID = nil; intentWarmupDocumentID = nil
    }
    private func beginIntentWarmup() {
        guard canUseVoiceIntent, !voiceBusy, voiceID == nil, voiceState == "idle" else { return }
        let request = UUID(); intentWarmupID = request
        intentWarmupDocumentID = textDocumentProxy.documentIdentifier
        voiceBusy = true; voiceMessage = "正在尝试后台开启语音…"; updateVoice()
        // Background start keeps the user in place. If it doesn't come up
        // quickly, fall back to the round trip through Lab.
        pollIntentWarmup(request, deadline: Date().addingTimeInterval(canOpenContainingApp ? 8 : 20))
    }
    private func intentWarmupTimedOut() {
        guard canOpenContainingApp else { failIntentWarmup("后台启动未成功，请在 Lab 检查权限和配对后重试。"); return }
        cancelIntentWarmup(); renewSessionInLab()
    }
    private func failIntentWarmup(_ message: String) {
        cancelIntentWarmup(); voiceAgentReady = false
        voiceMessage = message; updateVoice()
    }
    private func pollIntentWarmup(_ request: UUID, deadline: Date) {
        refreshBridgePairing()
        guard intentWarmupID == request else { return }
        guard appeared, mode == .voice, view.window != nil else { cancelIntentWarmup(); return }
        guard textDocumentProxy.documentIdentifier == intentWarmupDocumentID else {
            failIntentWarmup("输入框已改变，点击麦克风重试。"); return
        }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            intentWarmupTimedOut(); return
        }
        BridgeClient.call(pairing: bridgePairing,
                          path: "/v1/status", timeout: min(2.5, max(0.25, remaining))) { [weak self] result in
            guard let self = self, self.intentWarmupID == request else { return }
            guard self.appeared, self.mode == .voice, self.view.window != nil else { self.cancelIntentWarmup(); return }
            guard self.textDocumentProxy.documentIdentifier == self.intentWarmupDocumentID else {
                self.failIntentWarmup("输入框已改变，点击麦克风重试。"); return
            }
            guard Date() < deadline else {
                self.intentWarmupTimedOut(); return
            }
            if case .success(let reply) = result, reply.agent_ready == true {
                self.cancelIntentWarmup(); self.voiceAgentReady = true; self.updateVoice()
                self.tapVoice(); return
            }
            if case .failure(let error) = result, let bridgeError = error as? BridgeError {
                switch bridgeError {
                case .invalidAddress, .invalidToken, .message:
                    self.failIntentWarmup(bridgeError.localizedDescription); return
                default: break
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.pollIntentWarmup(request, deadline: deadline) }
        }
    }
    private func scheduleVoicePoll() {
        voiceTimer?.invalidate()
        let timer = Timer(timeInterval: 0.45, repeats: true) { [weak self] _ in self?.pollVoice() }
        voiceTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func pollVoice() {
        refreshBridgePairing()
        guard !voiceBusy, !voicePolling, let id = voiceID else { return }
        if Date().timeIntervalSince(voiceStarted) > Double(Lab.maxRecordingSeconds + 200) { cancelVoice(); resetVoice("语音任务超时，请重试。"); return }
        voicePolling = true; let revision = voiceRevision
        voiceCall("/v1/voice/result", jobID: id) { [weak self] result in
            guard let self = self, self.voiceID == id, self.voiceRevision == revision else { return }
            self.voicePolling = false
            // One dropped poll on cellular must not cancel a long recording.
            // Only a sustained outage, or the service's own answer, ends the job.
            if case .failure(let error) = result, BridgeError.isTransient(error) {
                let since = self.voiceFailureSince ?? Date(); self.voiceFailureSince = since
                if Date().timeIntervalSince(since) < Self.voicePollGrace {
                    self.voiceMessage = "网络不稳，正在重连…"; self.updateVoice(); return
                }
            }
            self.voiceFailureSince = nil
            self.handleVoice(result)
        }
    }
    private static let voicePollGrace: TimeInterval = 20
    private func handleVoice(_ result: Result<BridgeReply, Error>) {
        switch result {
        case .failure(let error):
            voiceAgentReady = nil
            cancelVoice(); resetVoice(error.localizedDescription)
        case .success(let reply):
            voiceState = reply.state ?? "idle"
            if ["recording", "stopping", "processing"].contains(voiceState),
               let partial = reply.partial?.trimmingCharacters(in: .whitespacesAndNewlines), !partial.isEmpty {
                voiceDraft = partial
                showInlineDraft()
            }
            switch voiceState {
            case "pending": voiceMessage = "正在启动手机录音，请稍候…"
            case "recording": voiceMessage = "正在录音 · 说完点击停止（最长 5 分钟）"
            case "stopping", "processing": voiceMessage = "正在识别语音，完成后自动上屏…"
            case "done":
                voiceTimer?.invalidate(); voiceTimer = nil
                let text = reply.text ?? ""
                if text.isEmpty { resetVoice("没有识别到文字，点击重试。") }
                else if let id = voiceID {
                    voiceDelivery.receive(id: id, text: text)
                    voiceMessage = "识别完成"
                    insertVoiceResultIfReady()
                }
            case "error", "cancelled", "consumed": resetVoice(reply.error ?? "请重新开始录音。")
            default: break
            }
            updateVoice()
        }
    }
    private func insertVoiceResultIfReady() {
        // A completion arriving while the keyboard is hidden must wait for its
        // host connection, and must never insert the same job twice.
        guard appeared, viewIfLoaded?.window != nil, voiceState == "done", hotEditor == nil else { return }
        let documentID = textDocumentProxy.documentIdentifier
        guard voiceDelivery.documentID == documentID else {
            cancelVoice(); resetVoice("输入框已改变，请重新录音。"); return
        }
        guard let delivery = voiceDelivery.take(visible: true, documentID: documentID) else { return }
        let pairing = voicePairing
        clearInlineDraft()
        commitComposition()
        let inserted = autoNewline.apply(to: delivery.text)
        textDocumentProxy.insertText(inserted)
        scheduleSuggestions()
        voiceUndo.record(inserted, documentID: documentID)
        resetVoice("已上屏 · 不满意可点上方撤回")
        BridgeClient.call(pairing: pairing, path: "/v1/voice/consume", value: ["id": delivery.id]) { _ in }
    }
    private func updateVoice() {
        let showDraft = draftPlacement == .hint && !voiceDraft.isEmpty
            && ["recording", "stopping", "processing"].contains(voiceState)
        voiceHint?.text = showDraft ? voiceDraft : voiceMessage
        // A draft keeps its newest words in view; status messages keep their start.
        voiceHint?.lineBreakMode = showDraft ? .byTruncatingHead : .byTruncatingTail
        voiceHint?.textColor = showDraft ? .white : Lab.muted
        voiceHint?.accessibilityLabel = showDraft ? "实时草稿：\(voiceDraft)" : nil
        let recording = voiceState == "recording"
        voiceButton?.configuration?.title = recording ? "停止" : ""
        voiceButton?.configuration?.image = UIImage(systemName: recording ? "stop.fill" : "mic.fill")
        voiceButton?.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: recording ? 22 : 35)
        voiceButton?.accessibilityLabel = recording ? "停止录音" : "开始真实语音输入"
        // Polling requests don't disable the stop button, so a tap is never silently lost.
        voiceButton?.isEnabled = !voiceBusy && !["pending", "stopping", "processing"].contains(voiceState)
        updateVoiceIntentControl()
        updateVoiceEditKeys()
    }
    private func updateVoiceEditKeys() {
        let idle = voiceID == nil && voiceState == "idle"
        undoButton?.isHidden = !(idle && voiceUndo.isAvailable)
        updateHeader()
        guard let newline = newlineButton else { return }
        let on = autoNewline != .off
        newline.configuration?.baseBackgroundColor = autoNewline == .hard ? UIColor.systemOrange : (on ? UIColor.systemBlue : Lab.surface)
        newline.configuration?.baseForegroundColor = on ? .white : Lab.muted
        newline.accessibilityLabel = autoNewline.hint
    }
    /// Header state shared by all pages: the microphone mirrors the voice
    /// page's button, and on the letter pages the brand slot doubles as the
    /// voice status line while something is happening.
    private func updateHeader() {
        let active = voiceID != nil || voiceBusy || voiceState != "idle"
        let fresh = Date().timeIntervalSince(voiceMessageAt) < 5
        let showStatus = mode != .voice && hotEditor == nil && (active || fresh)
        let showDraft = showStatus && draftPlacement == .hint && !voiceDraft.isEmpty
            && ["recording", "stopping", "processing"].contains(voiceState)
        if let brand = brandLabel {
            brand.text = showStatus ? (showDraft ? voiceDraft : voiceMessage) : "◖ SayKey"
            brand.font = showStatus ? UIFont.systemFont(ofSize: 12) : UIFont.boldSystemFont(ofSize: 19)
            brand.textColor = showStatus && !showDraft ? Lab.muted : UIColor.white
            brand.lineBreakMode = showDraft ? .byTruncatingHead : .byTruncatingTail
            // The undo capsule takes the brand's place while it is offered.
            brand.isHidden = !showStatus && undoButton?.isHidden == false
        }
        if showStatus && !active && statusClearStamp != voiceMessageAt {
            let stamp = voiceMessageAt; statusClearStamp = stamp
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.1) { [weak self] in
                guard let self = self, self.voiceMessageAt == stamp else { return }
                self.updateHeader()
            }
        }
        guard let mic = headerMic else { return }
        let recording = voiceState == "recording"
        mic.isHidden = mode == .voice || hotEditor != nil
        mic.configuration?.image = UIImage(systemName: recording ? "stop.fill" : "mic.fill")
        mic.configuration?.baseBackgroundColor = recording ? UIColor.systemRed : UIColor(white: 0.94, alpha: 1)
        mic.configuration?.baseForegroundColor = recording ? UIColor.white : UIColor.black
        mic.accessibilityLabel = recording ? "停止录音" : "开始语音输入"
        mic.isEnabled = !voiceBusy && !["pending", "stopping", "processing"].contains(voiceState)
    }
    private func hidePanel() {
        stopDeleting()
        dismissKeyboard()
    }
    private func tapShift() {
        let now = Date()
        shiftState = shiftState.tapped(sincePrevious: now.timeIntervalSince(lastShiftTap))
        lastShiftTap = now; render()
    }
    private func toggleAutoNewline() {
        autoNewline = autoNewline.next; autoNewline.save()
        voiceMessage = autoNewline.hint; updateVoice()
    }
    private func undoVoiceInsert() {
        guard voiceID == nil, voiceState == "idle", hotEditor == nil, voiceUndo.isAvailable else { return }
        let proxy = textDocumentProxy
        guard let count = voiceUndo.deletions(documentID: proxy.documentIdentifier,
                                              textBeforeCursor: proxy.documentContextBeforeInput) else {
            voiceUndo.clear(); voiceMessage = "光标已移动或换了输入框，无法撤回。"; updateVoice(); return
        }
        for _ in 0..<count { proxy.deleteBackward() }
        voiceUndo.clear(); voiceMessage = "已撤回上一段语音"; updateVoice()
    }
    /// Put the newest draft into the text field as marked text: underlined,
    /// cursor after it, and replaced as a whole by the next draft or the result.
    private func showInlineDraft() {
        guard draftPlacement == .inline, appeared, hotEditor == nil, composition.isEmpty else { return }
        let proxy = textDocumentProxy
        applyInlineDraft(inlineDraft.update(draft: voiceDraft, documentID: proxy.documentIdentifier,
                                            expectedDocument: voiceDelivery.documentID))
    }
    private func clearInlineDraft() { applyInlineDraft(inlineDraft.clear()) }
    private func applyInlineDraft(_ action: InlineVoiceDraft.Action) {
        let proxy = textDocumentProxy
        switch action {
        case .none: break
        case .mark(let text):
            proxy.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
        case .clear:
            proxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
            proxy.unmarkText()
        }
    }
    @objc private func hintTapped() { toggleDraftPlacement() }
    private func toggleDraftPlacement() {
        guard voiceID == nil, voiceState == "idle", !voiceBusy else { return }
        draftPlacement = draftPlacement.next; draftPlacement.save()
        voiceMessage = draftPlacement.hint; updateVoice()
    }
    private func resetVoice(_ message: String) {
        voiceTimer?.invalidate(); voiceTimer = nil
        voiceID = nil; voicePairing = nil; voiceDelivery.reset(); voiceState = "idle"; voiceBusy = false
        voiceDraft = ""; clearInlineDraft()
        voiceRevision = UUID(); voicePolling = false; voiceFailureSince = nil
        voiceMessage = message; updateVoice()
        refreshVoiceReadiness()
    }
    private func cancelVoice() {
        if let id = voiceID { voiceCall("/v1/voice/cancel", value: ["id": id]) { _ in } }
        resetVoice("录音已取消 · 点击重新开始")
    }
    private func renderLetters(mode: Mode, content: UIStackView) {
        let punctuation = mode == .pinyin ? "。，？！、" : ".,?!'"
        let layouts = symbols ? (extraSymbols ? ["[]{}#%^*+=", "_\\|~<>€£¥•", punctuation] : ["1234567890", "-/:;()$&@\"", punctuation]) : ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        var letterWidth: NSLayoutDimension?
        var sizingConstraints: [NSLayoutConstraint] = []
        for (index, line) in layouts.enumerated() {
            var buttons: [UIView] = []
            var shiftButton: UIButton?
            if index == 2 && !symbols {
                let shift = key("", symbol: mode == .pinyin ? "shift" : shiftState.symbolName) { [weak self] in
                    guard let self = self else { return }
                    if self.mode == .pinyin { self.changeMode(.english) } else { self.tapShift() }
                }
                shift.accessibilityIdentifier = "keyboard-shift"
                shift.accessibilityLabel = mode == .pinyin ? "切换到英文" : "大小写切换"
                shift.accessibilityHint = mode == .pinyin ? nil : "点一下大写一个字母，快速点两下锁定大写"
                shiftButton = shift
                buttons.append(shift)
            }
            if index == 2 && symbols {
                let more = key(extraSymbols ? "123" : "#+=") { [weak self] in
                    guard let self = self else { return }; self.extraSymbols.toggle(); self.render()
                }
                more.accessibilityIdentifier = "keyboard-symbol-page"
                more.accessibilityLabel = extraSymbols ? "返回数字符号" : "更多符号"
                buttons.append(more)
            }
            for letter in line {
                let title = !symbols && mode == .english && shiftState.isOn ? String(letter).uppercased() : String(letter)
                let button = key(title) { [weak self] in self?.input(title) }
                if index == 0 && letterWidth == nil { letterWidth = button.widthAnchor }
                if !symbols && index > 0, let width = letterWidth { sizingConstraints.append(button.widthAnchor.constraint(equalTo: width)) }
                button.accessibilityIdentifier = "key-" + title; buttons.append(button)
            }
            if index == 2 {
                let delete = deleteKey()
                if let shift = shiftButton { sizingConstraints.append(delete.widthAnchor.constraint(equalTo: shift.widthAnchor)) }
                buttons.append(delete)
            }
            if !symbols && index == 1 {
                let left = UIView(), right = UIView()
                sizingConstraints.append(left.widthAnchor.constraint(equalTo: right.widthAnchor))
                content.addArrangedSubview(keyRow([left] + buttons + [right], equal: false))
            } else { content.addArrangedSubview(keyRow(buttons, equal: symbols || index == 0)) }
        }
        // Cross-view constraints require a shared ancestor. All rows must be
        // attached to this page before any inter-key sizing is activated.
        NSLayoutConstraint.activate(sizingConstraints)
        let number = key(symbols ? "ABC" : "123") { [weak self] in
            guard let self = self else { return }; self.commitComposition(); self.symbols.toggle(); self.extraSymbols = false; self.render()
        }
        number.accessibilityIdentifier = "keyboard-number-toggle"
        number.widthAnchor.constraint(equalToConstant: 74).isActive = true
        let space = key(mode == .pinyin ? "拼" : "EN") { [weak self] in self?.space() }
        space.accessibilityLabel = "空格 / 选字"
        space.accessibilityIdentifier = "keyboard-space"
        space.contentHorizontalAlignment = .trailing
        space.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { input in
            var output = input; output.font = UIFont.systemFont(ofSize: 13); output.foregroundColor = Lab.muted; return output
        }
        let enter = returnKey(); enter.widthAnchor.constraint(equalToConstant: 74).isActive = true
        enter.configuration?.title = ""; enter.configuration?.image = UIImage(systemName: "return")
        enter.configuration?.baseBackgroundColor = UIColor(white: 0.94, alpha: 1)
        enter.configuration?.baseForegroundColor = .black
        content.addArrangedSubview(keyRow([number, space, enter], equal: false))
    }
    private func returnKey() -> UIButton {
        let button = key("return") { [weak self] in
            guard let self = self else { return }
            self.spaceCommittedComposition = false; self.lastSpaceAt = .distantPast
            // Like the iPhone pinyin keyboard: Space picks the Chinese
            // candidate, Return keeps the typed letters as they are.
            if self.composition.isEmpty { self.insertText("\n") } else { self.commitLetters() }
        }
        button.accessibilityIdentifier = "keyboard-return"; return button
    }
    private func input(_ text: String) {
        guard !hotSaving else { return }
        lastSpaceAt = .distantPast; spaceCommittedComposition = false
        // Like the iPhone keyboard: punctuation typed right after a tapped
        // suggestion takes the place of the space that suggestion added.
        if suggestionSpace && text.count == 1 && ".,?!;:".contains(text) && editingContext().hasSuffix(" ") {
            deleteCharacter()
        }
        suggestionSpace = false
        if mode == .pinyin && !symbols && text.count == 1 && text.allSatisfy({ $0 >= "a" && $0 <= "z" }) {
            guard composition.count < 64 else { return }; composition += text; updateCandidates()
        } else {
            commitComposition(); insertText(text)
            if mode == .english && !symbols && shiftState == .once {
                shiftState = shiftState.afterCharacter; render()
            }
        }
    }
    private func space() {
        guard !hotSaving else { return }
        suggestionSpace = false
        if composition.isEmpty {
            if spaceCommittedComposition && Date().timeIntervalSince(lastSpaceAt) < 0.4 {
                insertText(mode == .pinyin ? "。" : ". ")
                lastSpaceAt = .distantPast; spaceCommittedComposition = false; return
            }
            spaceCommittedComposition = false
            let context = editingContext()
            let preceding = context.dropLast().last
            if Date().timeIntervalSince(lastSpaceAt) < 0.4, context.hasSuffix(" "),
               let preceding = preceding, preceding.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
                deleteCharacter(); insertText(mode == .pinyin ? "。" : ". ")
                lastSpaceAt = .distantPast
            } else { insertText(" "); lastSpaceAt = Date() }
        } else { commitComposition(); lastSpaceAt = Date(); spaceCommittedComposition = true }
    }
    /// The text before the cursor, in the hotword editor or the host's field.
    private func editingContext() -> String {
        guard let editor = hotEditor else {
            // Hosted outside a keyboard extension (layout tests) there is no field.
            return extensionContext == nil ? "" : (textDocumentProxy.documentContextBeforeInput ?? "")
        }
        let text = editor.text as NSString
        return text.substring(to: min(editor.selectedRange.location, text.length))
    }
    /// Refreshes the bar once the current key press is fully handled, so the
    /// host has reported the text as it now stands.
    private func scheduleSuggestions() {
        guard !suggestionRefreshPending else { return }
        suggestionRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            self?.suggestionRefreshPending = false; self?.refreshSuggestions()
        }
    }
    private func refreshSuggestions() {
        // Typing a pinyin letter withdraws the suggestions: the candidates
        // take over the same row until that word is committed.
        let composing = mode == .pinyin && !composition.isEmpty
        let visible = mode != .voice && !composing
        suggestionScroll.isHidden = !visible
        guard visible, voiceID == nil else { showSuggestions([]); return }
        guard let suggester = suggester else { loadSuggester(); showSuggestions([]); return }
        showSuggestions(suggester.suggestions(before: editingContext(),
                                              language: mode == .pinyin ? .chinese : .english))
    }
    private func loadSuggester() {
        guard !suggesterLoading else { return }
        suggesterLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = WordSuggestions.bundled()
            DispatchQueue.main.async { [weak self] in
                self?.suggester = loaded; self?.refreshSuggestions()
            }
        }
    }
    private func showSuggestions(_ next: [WordSuggestion]) {
        guard next != suggestions || suggestionRow.arrangedSubviews.count != next.count else { return }
        suggestions = next
        for view in suggestionRow.arrangedSubviews { suggestionRow.removeArrangedSubview(view); view.removeFromSuperview() }
        let font = UIFont.systemFont(ofSize: 16)
        for suggestion in next {
            let button = candidateButton(grid: false) { [weak self] in self?.chooseSuggestion(suggestion) }
            button.setTitle(suggestion.text, for: .normal)
            button.titleLabel?.font = font
            button.layer.cornerRadius = 15
            button.accessibilityIdentifier = "suggestion-" + suggestion.text
            let width = ceil((suggestion.text as NSString).size(withAttributes: [.font: font]).width) + 22
            button.widthAnchor.constraint(equalToConstant: max(40, width)).isActive = true
            suggestionRow.addArrangedSubview(button)
        }
        suggestionScroll.setContentOffset(.zero, animated: false)
    }
    private func chooseSuggestion(_ suggestion: WordSuggestion) {
        guard !hotSaving, composition.isEmpty, suggestions.contains(suggestion) else { return }
        // Replacing a half-typed word deletes text, so make sure the field
        // still ends with what the suggestion was made for.
        if suggestion.replacing > 0 {
            let current = suggester?.suggestions(before: editingContext(), language: .english) ?? []
            guard current.contains(suggestion) else { scheduleSuggestions(); return }
        }
        lastSpaceAt = .distantPast; spaceCommittedComposition = false
        for _ in 0..<suggestion.replacing { deleteCharacter() }
        insertText(suggestion.insertion)
        suggestionSpace = suggestion.insertion.hasSuffix(" ")
        if mode == .english && !symbols && shiftState == .once { shiftState = .off; render() }
    }
    private func clearVoiceUndo() {
        guard voiceUndo.isAvailable else { return }
        voiceUndo.clear(); updateVoiceEditKeys()
    }
    private func deleteCharacter() {
        guard !hotSaving else { return }
        suggestionSpace = false; scheduleSuggestions()
        clearInlineDraft()
        spaceCommittedComposition = false
        if composition.isEmpty {
            if let editor = hotEditor {
                let text = editor.text as NSString
                let selected = editor.selectedRange
                let location = min(selected.location, text.length)
                var range = NSRange(location: location, length: min(selected.length, text.length - location))
                if range.length == 0 && range.location > 0 {
                    range = text.rangeOfComposedCharacterSequence(at: range.location - 1)
                }
                if range.length > 0 {
                    editor.textStorage.replaceCharacters(in: range, with: "")
                    editor.selectedRange = NSRange(location: range.location, length: 0)
                }
            } else { textDocumentProxy.deleteBackward(); clearVoiceUndo() }
        }
        else { composition.removeLast(); updateCandidates() }
    }
    /// Removes the text before the cursor back to the previous line break.
    private func deleteLine() {
        guard !hotSaving else { return }
        suggestionSpace = false; scheduleSuggestions()
        clearInlineDraft()
        spaceCommittedComposition = false; lastSpaceAt = .distantPast
        guard composition.isEmpty else { composition = ""; updateCandidates(); return }
        if let editor = hotEditor {
            let text = editor.text as NSString
            let selected = editor.selectedRange
            guard selected.length == 0 else { deleteCharacter(); return }
            let location = min(selected.location, text.length)
            let length = LineDeletion.suffix(before: text.substring(to: location)).utf16.count
            guard length > 0 else { return }
            let range = NSRange(location: location - length, length: length)
            editor.textStorage.replaceCharacters(in: range, with: "")
            editor.selectedRange = NSRange(location: range.location, length: 0)
            return
        }
        let proxy = textDocumentProxy
        if let selected = proxy.selectedText, !selected.isEmpty {
            proxy.deleteBackward(); clearVoiceUndo(); return
        }
        // Hosts may report only part of the text before the cursor. An empty
        // report still gets one delete, so a held key keeps moving.
        let count = LineDeletion.suffix(before: proxy.documentContextBeforeInput ?? "").count
        for _ in 0..<max(1, count) { proxy.deleteBackward() }
        clearVoiceUndo()
    }
    private func lineDeleteKey() -> UIButton {
        let button = Lab.button("", symbol: "delete.left.fill") { [weak self] in self?.deleteLine() }
        button.configuration?.contentInsets = .zero
        button.configuration?.baseForegroundColor = .systemOrange
        button.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 15)
        button.accessibilityIdentifier = "keyboard-delete-line"
        button.accessibilityLabel = "删除整行"
        button.accessibilityHint = "短按删除光标前的一整行，长按连续删除"
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(lineDeleteHeld(_:)))
        gesture.minimumPressDuration = 0.4
        button.addGestureRecognizer(gesture)
        return button
    }
    @objc private func lineDeleteHeld(_ gesture: UILongPressGestureRecognizer) { held(gesture, lines: true) }
    private func deleteKey() -> UIButton {
        let button = key("", symbol: "delete.left") { [weak self] in self?.deleteCharacter() }
        button.accessibilityIdentifier = "keyboard-delete"
        button.accessibilityLabel = "删除"
        button.accessibilityHint = "短按删除一个字符，长按加速连续删除"
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(deleteHeld(_:)))
        gesture.minimumPressDuration = 0.4
        button.addGestureRecognizer(gesture)
        return button
    }
    @objc private func deleteHeld(_ gesture: UILongPressGestureRecognizer) { held(gesture, lines: false) }
    private func deleteStep() {
        if deletingLines { deleteLine() } else { deleteCharacter() }
    }
    private func held(_ gesture: UILongPressGestureRecognizer, lines: Bool) {
        switch gesture.state {
        case .began:
            stopDeleting(); deleteGesture = gesture; deleteStarted = Date(); deletingLines = lines
            deleteStep(); scheduleDeletion()
        case .changed:
            if let button = gesture.view, !button.bounds.insetBy(dx: -10, dy: -10).contains(gesture.location(in: button)) { stopDeleting() }
        case .ended, .cancelled, .failed: stopDeleting()
        default: break
        }
    }
    private func scheduleDeletion() {
        let elapsed = Date().timeIntervalSince(deleteStarted)
        let interval = deletingLines ? (elapsed > 1.5 ? 0.18 : 0.3)
            : (elapsed > 2 ? 0.04 : (elapsed > 0.9 ? 0.075 : 0.12))
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            guard let self = self, let gesture = self.deleteGesture,
                  gesture.view?.window != nil, (gesture.state == .began || gesture.state == .changed) else { return }
            self.deleteStep(); self.scheduleDeletion()
        }
        deleteTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func stopDeleting() { deleteTimer?.invalidate(); deleteTimer = nil; deleteGesture = nil }
    private func choose(_ candidate: PinyinCandidate) {
        guard displayedComposition == composition, displayedCandidates.contains(candidate) else { return }
        insertText(candidate.text)
        composition = String(composition.dropFirst(candidate.consumed)); updateCandidates()
    }
    private func commitComposition() {
        guard !composition.isEmpty else { return }
        var remaining = composition, text = ""
        while !remaining.isEmpty {
            // Most commits use the already displayed result. A fast space tap
            // may precede decoding; serialize that fallback with the worker.
            let options = remaining == displayedComposition ? displayedCandidates : candidateQueue.sync { pinyin.candidates(for: remaining) }
            if let first = options.first {
                text += first.text; remaining = String(remaining.dropFirst(first.consumed))
            } else { text += remaining; remaining = "" }
        }
        insertText(text); composition = ""
        updateCandidates()
    }
    /// Puts the typed pinyin letters into the text as plain letters.
    private func commitLetters() {
        guard !composition.isEmpty else { return }
        let letters = composition
        insertText(letters); composition = ""
        updateCandidates()
    }
    private func updateCandidates() {
        candidateLock.lock(); candidateGeneration += 1; let generation = candidateGeneration; candidateLock.unlock()
        let composing = mode == .pinyin && !composition.isEmpty
        pinyinLine?.isHidden = !composing
        if !composing { setCandidatesExpanded(false) }
        compositionLabel?.text = composition
        suggestionScroll.isHidden = mode == .voice || composing
        scheduleSuggestions()
        displayedComposition = ""; displayedCandidates = []
        candidateRow?.arrangedSubviews.forEach { $0.isHidden = true }
        expandCandidatesButton?.isEnabled = false
        rebuildCandidateGrid()
        guard composing else { return }
        let buffer = composition
        candidateQueue.async { [weak self] in
            guard let self = self else { return }
            self.candidateLock.lock(); let current = self.candidateGeneration; self.candidateLock.unlock()
            guard generation == current else { return }
            let candidates = self.pinyin.candidates(for: buffer)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.mode == .pinyin, self.composition == buffer else { return }
                self.candidateLock.lock(); let current = self.candidateGeneration; self.candidateLock.unlock()
                guard generation == current else { return }
                self.applyCandidates(candidates, for: buffer)
            }
        }
    }
    private func applyCandidates(_ candidates: [PinyinCandidate], for buffer: String) {
        displayedCandidates = candidates; displayedComposition = buffer
        refreshCandidateStrip()
        expandCandidatesButton?.isEnabled = candidatesExpanded || candidates.count > 1
        rebuildCandidateGrid()
    }
    private func candidateButton(grid: Bool, action: @escaping () -> Void) -> UIButton {
        let button = PinyinCandidateButton(frame: .zero)
        button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: grid ? 20 : 18)
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.titleLabel?.adjustsFontSizeToFitWidth = false
        button.titleLabel?.textAlignment = .center
        button.clipsToBounds = true
        button.contentEdgeInsets = UIEdgeInsets(top: 0, left: grid ? 3 : 9, bottom: 0, right: grid ? 3 : 9)
        button.layer.cornerRadius = grid ? 0 : 16
        button.backgroundColor = grid ? Lab.background : Lab.surface
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }
    private func refreshCandidateStrip() {
        guard let row = candidateRow, let scroll = candidateScroll else { return }
        let visibleCount = candidatesExpanded ? min(1, displayedCandidates.count) : displayedCandidates.count
        while row.arrangedSubviews.count < visibleCount {
            let index = row.arrangedSubviews.count
            let button = candidateButton(grid: false) { [weak self] in
                guard let self = self, self.displayedComposition == self.composition,
                      self.displayedCandidates.indices.contains(index) else { return }
                self.choose(self.displayedCandidates[index])
            }
            row.addArrangedSubview(button)
            let width = button.widthAnchor.constraint(equalToConstant: 36)
            width.priority = UILayoutPriority(999)
            NSLayoutConstraint.activate([width, button.widthAnchor.constraint(lessThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor)])
            candidateWidths.append(width)
        }
        for (index, view) in row.arrangedSubviews.enumerated() {
            guard let button = view as? UIButton, index < visibleCount else { view.isHidden = true; continue }
            let title = displayedCandidates[index].text
            button.setTitle(title, for: .normal)
            candidateWidths[index].constant = max(36, ceil((title as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 18)]).width) + 18)
            button.accessibilityIdentifier = "candidate-" + title
            button.isHidden = false
        }
        scroll.setContentOffset(.zero, animated: false)
    }
    private func setCandidatesExpanded(_ expanded: Bool) {
        candidatesExpanded = expanded && mode == .pinyin && !composition.isEmpty
        candidateGrid.isHidden = !candidatesExpanded
        pageStrip.isHidden = candidatesExpanded
        pager.isScrollEnabled = !candidatesExpanded
        pager.accessibilityElementsHidden = candidatesExpanded
        expandCandidatesButton?.configuration?.image = UIImage(systemName: candidatesExpanded ? "chevron.up" : "chevron.down")
        expandCandidatesButton?.accessibilityLabel = candidatesExpanded ? "收起候选词" : "展开全部候选词"
        refreshCandidateStrip()
        if candidatesExpanded { rebuildCandidateGrid(); candidateGrid.setContentOffset(.zero, animated: false) }
    }
    private func rebuildCandidateGrid() {
        guard candidatesExpanded else { return }
        for view in candidateGridRows.arrangedSubviews {
            candidateGridRows.removeArrangedSubview(view); view.removeFromSuperview()
        }
        let columns = 6
        gridLayoutWidth = candidateGrid.bounds.width
        let availableWidth = gridLayoutWidth > 0 ? gridLayoutWidth : view.bounds.width - 24
        let unitWidth = max(1, availableWidth / CGFloat(columns))
        var buttons: [UIView] = []
        var gridConstraints: [NSLayoutConstraint] = []
        var used = 0
        func finishRow() {
            guard !buttons.isEmpty else { return }
            if used < columns {
                let spacer = UIView()
                gridConstraints.append(spacer.widthAnchor.constraint(equalTo: candidateGridRows.widthAnchor, multiplier: CGFloat(columns - used) / CGFloat(columns)))
                buttons.append(spacer)
            }
            let gridRow = row(buttons, equal: false); gridRow.spacing = 0
            candidateGridRows.addArrangedSubview(gridRow)
            NSLayoutConstraint.activate(gridConstraints); gridConstraints = []
            let separator = UIView(); separator.backgroundColor = UIColor(white: 0.23, alpha: 1)
            separator.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
            candidateGridRows.addArrangedSubview(separator)
            buttons = []; used = 0
        }
        for candidate in displayedCandidates.dropFirst() {
            let titleWidth = (candidate.text as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 20)]).width
            let span = min(columns, max(1, Int(ceil((titleWidth + 12) / unitWidth))))
            if used + span > columns { finishRow() }
            let button = candidateButton(grid: true) { [weak self] in self?.choose(candidate) }
            button.setTitle(candidate.text, for: .normal)
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            gridConstraints.append(button.widthAnchor.constraint(equalTo: candidateGridRows.widthAnchor, multiplier: CGFloat(span) / CGFloat(columns)))
            button.accessibilityIdentifier = "grid-candidate-" + candidate.text
            buttons.append(button); used += span
            if used == columns { finishRow() }
        }
        finishRow()
    }

    private func insertText(_ text: String) {
        guard !hotSaving else { return }
        clearInlineDraft()
        clearVoiceUndo()
        scheduleSuggestions()
        guard let editor = hotEditor else { textDocumentProxy.insertText(text); return }
        let length = (editor.text as NSString).length
        let selected = editor.selectedRange
        let location = min(selected.location, length)
        let range = NSRange(location: location, length: min(selected.length, length - location))
        editor.textStorage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: [.font: editor.font ?? UIFont.systemFont(ofSize: 16), .foregroundColor: UIColor.white]))
        editor.selectedRange = NSRange(location: range.location + text.utf16.count, length: 0)
        editor.scrollRangeToVisible(editor.selectedRange)
    }
    private func openHotwords() {
        guard !voiceBusy, voiceID == nil,
              !["pending", "recording", "stopping", "processing"].contains(voiceState) else {
            voiceMessage = "请先结束本次语音，再编辑热词。"; updateVoice(); return
        }
        guard hasFullAccess else {
            voiceMessage = "热词管理需在键盘设置允许完全访问。"; updateVoice(); return
        }
        refreshBridgePairing()
        stopDeleting(); commitComposition(); setCandidatesExpanded(false)
        if let manager = hotManager { manager.removeFromSuperview() }
        let manager = HotwordManagerView(); manager.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(manager); hotManager = manager
        NSLayoutConstraint.activate([
            manager.topAnchor.constraint(equalTo: view.topAnchor), manager.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            manager.leadingAnchor.constraint(equalTo: view.leadingAnchor), manager.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        manager.onClose = { [weak self, weak manager] in
            self?.hotRequest = UUID(); manager?.removeFromSuperview()
        }
        manager.onSettings = { [weak self, weak manager] in
            self?.hotRequest = UUID(); manager?.removeFromSuperview(); self?.showBridge()
        }
        manager.onReload = { [weak self, weak manager] in
            guard let manager = manager else { return }; self?.loadHotwords(into: manager)
        }
        manager.onEdit = { [weak self, weak manager] file in
            manager?.removeFromSuperview(); self?.showHotwordEditor(file)
        }
        manager.onInsert = { [weak self, weak manager] file in
            manager?.removeFromSuperview(); self?.showHotwordEditor(file, appendOnly: true)
        }
        loadHotwords(into: manager)
    }
    private func loadHotwords(into manager: HotwordManagerView) {
        hotRequest = UUID(); let request = hotRequest
        manager.showLoading()
        BridgeClient.call(pairing: bridgePairing, path: "/v1/hotwords") { [weak self, weak manager] result in
            guard let self = self, self.hotRequest == request, let manager = manager else { return }
            switch result {
            case .success(let reply): manager.show(files: reply.hotword_files ?? [])
            case .failure(let error): manager.showError(error.localizedDescription)
            }
        }
    }
    // Internal presentation entry point also exercised by the UIKit regression.
    func showHotwordEditor(_ file: HotwordFile, appendOnly: Bool = false) {
        guard file.writable, hotEditor == nil else { return }
        stopDeleting(); commitComposition(); setCandidatesExpanded(false)
        hotRequest = UUID(); hotRevision = file.revision; hotFileID = file.id; hotPairing = bridgePairing
        hotAppendBase = appendOnly ? file.text : nil
        let editor = UITextView()
        editor.text = appendOnly ? "" : file.text; editor.font = .systemFont(ofSize: 15)
        editor.textColor = .white; editor.backgroundColor = Lab.surface; editor.layer.cornerRadius = 9
        editor.autocorrectionType = .no; editor.autocapitalizationType = .none
        editor.spellCheckingType = .no; editor.smartQuotesType = .no; editor.smartDashesType = .no
        // The extension's visible EN/Pinyin keys edit this text view. Do not ask
        // UIKit to place a second system keyboard inside the keyboard extension.
        editor.inputView = UIView(frame: .zero)
        editor.inputAssistantItem.leadingBarButtonGroups = []; editor.inputAssistantItem.trailingBarButtonGroups = []
        editor.textContainerInset = UIEdgeInsets(top: 7, left: 6, bottom: 7, right: 6)
        editor.heightAnchor.constraint(equalToConstant: 96).isActive = true
        editor.selectedRange = NSRange(location: editor.text.utf16.count, length: 0)
        editor.accessibilityIdentifier = "hotword-editor-text"
        hotEditor = editor
        let title = Lab.label(appendOnly ? HotwordAppend.hint(fileID: file.id) : file.name, size: 12, color: Lab.muted); title.numberOfLines = 2
        title.accessibilityIdentifier = "hotword-editor-status"; hotEditorStatus = title
        let cancel = editorAction("取消") { [weak self] in self?.closeHotwordEditor(saved: false) }
        cancel.accessibilityIdentifier = "hotword-editor-cancel"; hotCancelButton = cancel
        let add = editorAction("添加") { [weak self] in
            guard let self = self, let editor = self.hotEditor, !self.hotSaving else { return }
            self.commitComposition()
            editor.selectedRange = NSRange(location: editor.text.utf16.count, length: 0)
            if !editor.text.isEmpty && !editor.text.hasSuffix("\n") { self.insertText("\n") }
            editor.scrollRangeToVisible(editor.selectedRange)
        }
        add.accessibilityIdentifier = "hotword-add-line"; hotAddButton = add
        add.accessibilityHint = "点按添加一行，按住插入误识别分隔符或排除标记"
        add.menu = UIMenu(children: [
            UIAction(title: "插入替换符 =（替换规则用）") { [weak self] _ in self?.commitComposition(); self?.insertText(" = ") },
            UIAction(title: "插入误识别分隔符 |") { [weak self] _ in self?.commitComposition(); self?.insertText(" | ") },
            UIAction(title: "插入排除标记 ~~~") { [weak self] _ in self?.commitComposition(); self?.insertText("~~~") },
            UIAction(title: "插入注释 #") { [weak self] _ in self?.commitComposition(); self?.insertText("#") }
        ])
        let save = editorAction(appendOnly ? "插入" : "保存") { [weak self] in self?.saveHotwords() }
        save.accessibilityIdentifier = "hotword-editor-save"; hotSaveButton = save
        for button in [cancel, add, save] { button.widthAnchor.constraint(equalToConstant: 48).isActive = true }
        let bar = row([cancel, add, title, save], equal: false)
        bar.heightAnchor.constraint(equalToConstant: 32).isActive = true; hotEditorBar = bar
        content.insertArrangedSubview(bar, at: 0); content.insertArrangedSubview(editor, at: 1)
        mode = .pinyin; shiftState = .off; symbols = false
        modeSelector?.setEnabled(false, forSegmentAt: Mode.voice.rawValue)
        updatePreferredHeight(); render()
        editor.scrollRangeToVisible(editor.selectedRange)
    }
    private func editorAction(_ title: String, action: @escaping () -> Void) -> UIButton {
        let button = Lab.button(title, action: action)
        button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4)
        button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { input in
            var output = input; output.font = .systemFont(ofSize: 14); return output
        }
        return button
    }
    private func saveHotwords() {
        guard let editor = hotEditor, !hotSaving else { return }
        refreshBridgePairing()
        guard let hotPairing, hotPairing == bridgePairing else {
            hotEditorStatus?.text = "请切回打开草稿时的识别服务，再保存热词。"; return
        }
        commitComposition(); stopDeleting()
        hotRequest = UUID(); let request = hotRequest
        var text = editor.text ?? ""
        var added: [String] = []
        if let base = hotAppendBase {
            let merged = HotwordAppend.merge(base: base, draft: text, fileID: hotFileID)
            guard merged.invalid.isEmpty else {
                hotEditorStatus?.text = "格式不对：" + merged.invalid.joined(separator: "、") + "。" + HotwordAppend.hint(fileID: hotFileID); return
            }
            guard !merged.added.isEmpty else {
                hotEditorStatus?.text = merged.skipped.isEmpty ? "请先输入要插入的内容。" : "这些已经在词库里了。"; return
            }
            text = merged.text; added = merged.added
        }
        let value: [String: Any] = ["file_id": hotFileID, "revision": hotRevision, "text": text]
        setHotSaving(true); hotEditorStatus?.text = added.isEmpty ? "正在保存…" : "正在插入…"
        BridgeClient.call(pairing: hotPairing, path: "/v1/hotwords/save", value: value) { [weak self] result in
            guard let self = self, self.hotRequest == request, self.hotEditor != nil else { return }
            self.setHotSaving(false)
            switch result {
            case .success:
                self.closeHotwordEditor(saved: true)
                if !added.isEmpty { self.voiceMessage = "已插入：" + added.joined(separator: "、"); self.updateVoice() }
            case .failure(let error):
                // Retain the entire draft, cursor and original revision. A 409
                // must never silently overwrite an edit made on the computer.
                self.hotEditorStatus?.text = error.localizedDescription
            }
        }
    }
    private func setHotSaving(_ saving: Bool) {
        hotSaving = saving
        hotSaveButton?.isEnabled = !saving; hotCancelButton?.isEnabled = !saving; hotAddButton?.isEnabled = !saving
        hotEditor?.isUserInteractionEnabled = !saving
        pager.isUserInteractionEnabled = !saving; modeSelector?.isEnabled = !saving
    }
    private func closeHotwordEditor(saved: Bool) {
        guard !hotSaving else { return }
        stopDeleting(); hotRequest = UUID(); composition = ""
        hotEditor?.resignFirstResponder()
        for item in [hotEditorBar as UIView?, hotEditor as UIView?].compactMap({ $0 }) {
            content.removeArrangedSubview(item); item.removeFromSuperview()
        }
        hotEditor = nil; hotEditorBar = nil; hotEditorStatus = nil; hotAppendBase = nil
        modeSelector?.setEnabled(true, forSegmentAt: Mode.voice.rawValue)
        mode = .voice; shiftState = .off; symbols = false
        if saved { voiceMessage = "热词已保存 · 点击开始录音" }
        updatePreferredHeight(); render()
    }
    private func showBridge() {
        guard hasFullAccess else { feedback?.text = "电脑连接需在键盘设置开启“允许完全访问”"; return }
        refreshBridgePairing()
        if let panel = view.viewWithTag(700) { panel.removeFromSuperview(); return }
        previewedText = nil; bridgeRequestID = UUID()
        let panel = UIStackView(); panel.tag = 700; panel.axis = .vertical; panel.spacing = 10
        panel.backgroundColor = Lab.background; panel.isLayoutMarginsRelativeArrangement = true
        panel.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        panel.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: view.topAnchor), panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor), panel.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let shared = BridgePairingStore.hasUsedSharedProfiles
        let currentAddress = bridgePairing?.address ?? "尚未配对"
        let result = Lab.label("当前服务：\(currentAddress)\n\(shared ? "在 Lab 切换服务或更新配对。" : "旧版配对可从 Lab 复制到这里。")", size: 12, color: Lab.muted)
        let paste = Lab.button("粘贴配对配置", symbol: "doc.on.clipboard") { [weak self, weak result] in
            guard let raw = UIPasteboard.general.string, raw.hasPrefix("cwlab:v1:"),
                  let data = String(raw.dropFirst(9)).data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let address = value["address"], let token = value["token"],
                  let endpoint = BridgeEndpoint(address: address), BridgeClient.isValidToken(token) else {
                result?.text = "请先在主 App 复制配对配置。"; return
            }
            if let expiry = value["expires"], Double(expiry) == nil { result?.text = "配对有效期无效。"; return }
            guard let pairing = BridgePairing(address: endpoint.normalizedAddress, token: token,
                                              expires: value["expires"].flatMap({ Double($0) })), !pairing.isExpired() else {
                result?.text = "配对已到期或无效。"; return
            }
            guard !BridgePairingStore.hasUsedSharedProfiles else { return }
            pairing.saveLegacy()
            self?.bridgePairing = pairing
            self?.cancelIntentWarmup(); self?.stopVoiceReadiness(); self?.voiceAgentReady = nil
            self?.startVoiceReadiness(); self?.updateVoice()
            result?.text = "已保存：\(endpoint.normalizedAddress)"
        }
        let run = Lab.button("检查版本 / 纠正测试短句") { [weak self, weak result] in
            guard let self = self else { return }
            self.previewedText = nil; let requestID = UUID(); self.bridgeRequestID = requestID; result?.text = "连接中…"
            BridgeClient.request(pairing: self.bridgePairing,
                                 text: "测试热词：卡普斯赖特") { [weak self, weak result] reply in
                guard self?.bridgeRequestID == requestID else { return }
                switch reply {
                case .success(let value):
                    self?.previewedText = value.text
                    result?.text = "\(value.mode ?? "") · \(value.version ?? "")\n\(value.text ?? "")"
                case .failure(let error): result?.text = error.localizedDescription
                }
            }
        }
        let insert = Lab.button("插入已预览的结果") { [weak self, weak panel] in
            guard let self = self, let text = self.previewedText else { return }
            self.textDocumentProxy.insertText(text); panel?.removeFromSuperview()
        }
        let close = Lab.button("返回键盘") { [weak self, weak panel] in
            self?.bridgeRequestID = UUID(); self?.previewedText = nil; panel?.removeFromSuperview()
        }
        if !shared { panel.addArrangedSubview(paste) }
        panel.addArrangedSubview(run); panel.addArrangedSubview(result)
        panel.addArrangedSubview(row([insert, close])); panel.addArrangedSubview(UIView())
    }
}
