import UIKit

/// Sends the user back to the app they were typing in after the keyboard
/// opened Lab to restart the voice session.
///
/// iOS has no public API for this. Two undocumented routes are used, each
/// checked at runtime so a missing piece fails quietly:
/// - up to iOS 26.3 the keyboard reads `_hostBundleID` and passes it along;
/// - on iOS 26.4+ Lab watches the system keyboard state
///   (`_UIRemoteKeyboards.currentState.sourceBundleIdentifier`).
/// The host is then opened by its URL scheme, so only apps in the catalog
/// below can be returned to; others get the "◀" hint.
final class HostAppReturn: NSObject {
    static let shared = HostAppReturn()
    private var observed: NSObject?
    private var lastHost: (id: String, at: Date)?
    private var backgroundedAt: Date?

    /// Bundle ID → URL that opens the app's main screen.
    static let schemes: [String: String] = [
        "com.tencent.xin": "weixin://",
        "com.tencent.mqq": "mqq://",
        "com.tencent.WeWork": "wxwork://",
        "com.apple.MobileSMS": "messages://",
        "com.apple.mobilenotes": "mobilenotes://",
        "com.apple.mobilemail": "message://",
        "com.apple.reminders": "x-apple-reminderkit://",
        "com.apple.mobilesafari": "x-web-search://",
        "com.anthropic.claude": "claude://",
        "com.openai.chat": "chatgpt://",
        "com.google.Gmail": "googlegmail://",
        "com.google.chrome.ios": "googlechrome://",
        "net.whatsapp.WhatsApp": "whatsapp://",
        "ph.telegra.Telegraph": "tg://",
        "com.facebook.Messenger": "fb-messenger://",
        "com.burbn.instagram": "instagram://",
        "com.atebits.Tweetie2": "twitter://",
        "com.tinyspeck.chatlyio": "slack://",
        "notion.id": "notion://",
        "com.xingin.discover": "xhsdiscover://",
        "com.ss.iphone.ugc.Aweme": "snssdk1128://",
        "com.sina.weibo": "sinaweibo://",
        "com.alipay.iphoneclient": "alipay://",
        "com.microsoft.Office.Outlook": "ms-outlook://",
        "com.linkedin.LinkedIn": "linkedin://",
        "com.hammerandchisel.discord": "discord://",
        "com.larksuite.suite": "lark://",
        "com.ss.iphone.lark": "feishu://",
        "com.laiwang.DingTalk": "dingtalk://"
    ]

    static func isOwn(_ bundleID: String) -> Bool { bundleID.hasPrefix("org.capswriterlab") }

    /// Start watching the system keyboard state. Call once at launch.
    func start() {
        guard observed == nil, let type = NSClassFromString("_UIRemoteKeyboards") else { return }
        let shared = NSSelectorFromString("sharedRemoteKeyboards")
        let typeObject = type as AnyObject
        guard typeObject.responds(to: shared),
              let keyboards = typeObject.perform(shared)?.takeUnretainedValue() as? NSObject,
              keyboards.responds(to: NSSelectorFromString("currentState")) else { return }
        observed = keyboards
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.backgroundedAt = Date()
        }
        keyboards.addObserver(self, forKeyPath: "currentState", options: [.new, .initial], context: nil)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == "currentState", let state = change?[.newKey] as? NSObject,
              let id = Self.source(of: state) else { return }
        let at = Date()
        DispatchQueue.main.async { self.lastHost = (id, at) }
    }

    private static func source(of state: NSObject?) -> String? {
        guard let state, state.responds(to: NSSelectorFromString("sourceBundleIdentifier")),
              let id = state.value(forKey: "sourceBundleIdentifier") as? String,
              !id.isEmpty, !isOwn(id) else { return nil }
        return id
    }

    /// The host to return to for a request that reached Lab at
    /// `requestedAt`, or nil while it is not (yet) known. Lab may still hold
    /// the host of an earlier visit when it wakes up, so the choice is left
    /// to `HostReturnPolicy`; call again until it answers or time runs out.
    func host(reported: String?, requestedAt: Date) -> String? {
        let reported = reported.flatMap { Self.isOwn($0) ? nil : $0 } ?? systemNavigationBundleID()
        let current = Self.source(of: observed?.value(forKey: "currentState") as? NSObject)
        let decision = HostReturnPolicy.decide(reported: reported, current: current, observed: lastHost,
                                               requestedAt: requestedAt, backgroundedAt: backgroundedAt, now: Date())
        guard case .open(let id) = decision else { return nil }
        return id
    }

    /// Finds every active `UISystemNavigationAction` (the status bar "◀"
    /// action) together with its first destination index.
    private func systemNavigationActions() -> [(action: NSObject, destination: UInt)] {
        let getter = NSSelectorFromString("_systemNavigationAction")
        let destinationsSel = NSSelectorFromString("destinations")
        let owners: [NSObject] = [UIApplication.shared] + UIApplication.shared.connectedScenes.map { $0 as NSObject }
        var found: [(NSObject, UInt)] = []
        for owner in owners where owner.responds(to: getter) {
            guard let action = owner.perform(getter)?.takeUnretainedValue() as? NSObject else { continue }
            var destination: UInt = 0
            if action.responds(to: destinationsSel),
               let list = action.perform(destinationsSel)?.takeUnretainedValue() as? [NSNumber] {
                guard let first = list.first else { continue }
                destination = first.uintValue
            }
            found.append((action, destination))
        }
        return found
    }

    /// Bundle ID of the app behind the status bar "◀" breadcrumb for this
    /// launch, when iOS exposes it on `_systemNavigationAction`.
    private func systemNavigationBundleID() -> String? {
        let selector = NSSelectorFromString("bundleIdForDestination:")
        for (action, destination) in systemNavigationActions() {
            guard action.responds(to: selector), let method = action.method(for: selector) else { continue }
            typealias BundleID = @convention(c) (AnyObject, Selector, UInt) -> Unmanaged<NSString>?
            if let raw = unsafeBitCast(method, to: BundleID.self)(action, selector, destination)?.takeUnretainedValue() as String?,
               !raw.isEmpty, !Self.isOwn(raw) {
                return raw
            }
        }
        return nil
    }

    /// Triggers the system's own "◀ back to the previous app" action, the
    /// one behind the breadcrumb in the status bar. It needs no bundle ID
    /// and always targets the app the user really came from. Undocumented,
    /// so every step is checked at runtime; false means it was not sent
    /// and the caller should use another route.
    func goBackViaSystem() -> Bool {
        let send = NSSelectorFromString("sendResponseForDestination:")
        let canSend = NSSelectorFromString("canSendResponse")
        for (action, destination) in systemNavigationActions() {
            guard action.responds(to: send), let method = action.method(for: send) else { continue }
            if action.responds(to: canSend), (action.value(forKey: "canSendResponse") as? Bool) == false { continue }
            typealias Send = @convention(c) (AnyObject, Selector, UInt) -> ObjCBool
            if unsafeBitCast(method, to: Send.self)(action, send, destination).boolValue {
                return true
            }
        }
        return false
    }

    /// A readable name for the status line.
    static func displayName(_ bundleID: String) -> String {
        let names = ["com.tencent.xin": "微信", "com.apple.mobilenotes": "备忘录",
                     "com.apple.MobileSMS": "信息", "com.tencent.mqq": "QQ",
                     "com.apple.mobilesafari": "Safari", "com.anthropic.claude": "Claude"]
        return names[bundleID] ?? bundleID
    }

    /// Opens the host app. Returns false when it isn't in the catalog.
    @discardableResult
    func open(_ bundleID: String) -> Bool {
        guard let raw = Self.schemes[bundleID], let url = URL(string: raw) else { return false }
        UIApplication.shared.open(url)
        return true
    }
}
