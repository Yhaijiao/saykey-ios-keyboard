import ObjectiveC
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

    private static let ignoredHosts: Set<String> = [
        "com.apple.ScreenshotServicesService",
        "com.apple.springboard",
        "com.apple.Spotlight",
        "com.apple.InputUI"
    ]

    static func isOwn(_ bundleID: String) -> Bool {
        bundleID.hasPrefix("org.capswriterlab") || ignoredHosts.contains(bundleID)
    }

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
    ///
    /// On modern iOS, `_systemNavigationAction` is often a private ivar (not a
    /// selector) on `UIApplication` or a `UIWindowScene`, so check selectors,
    /// direct ivars, and safe object-typed ivar scans across the app and scenes.
    private func systemNavigationActions() -> [(action: NSObject, destination: UInt)] {
        let navClass: AnyClass? = NSClassFromString("UISystemNavigationAction")
        let destinationsSel = NSSelectorFromString("destinations")
        var owners: [NSObject] = [UIApplication.shared]
        let mainSceneSel = NSSelectorFromString("_mainScene")
        if UIApplication.shared.responds(to: mainSceneSel),
           let mainScene = UIApplication.shared.perform(mainSceneSel)?.takeUnretainedValue() as? NSObject {
            owners.append(mainScene)
        }
        let sceneSel = NSSelectorFromString("_scene")
        let fbsSceneSel = NSSelectorFromString("_FBSScene")
        for scene in UIApplication.shared.connectedScenes {
            owners.append(scene)
            if let windowScene = scene as? UIWindowScene, let barManager = windowScene.statusBarManager {
                owners.append(barManager)
            }
            if scene.responds(to: sceneSel),
               let inner = scene.perform(sceneSel)?.takeUnretainedValue() as? NSObject {
                owners.append(inner)
            }
            if scene.responds(to: fbsSceneSel),
               let inner = scene.perform(fbsSceneSel)?.takeUnretainedValue() as? NSObject {
                owners.append(inner)
            }
        }
        var seen = Set<ObjectIdentifier>()
        var found: [(NSObject, UInt)] = []
        for owner in owners {
            for action in Self.extractNavigationActions(from: owner, navClass: navClass) {
                let key = ObjectIdentifier(action)
                guard seen.insert(key).inserted else { continue }
                var destination: UInt = 0
                if action.responds(to: destinationsSel),
                   let list = action.perform(destinationsSel)?.takeUnretainedValue() as? [NSNumber] {
                    guard let first = list.first else { continue }
                    destination = first.uintValue
                }
                found.append((action, destination))
            }
        }
        return found
    }

    private static func isNavigationAction(_ object: NSObject, navClass: AnyClass?) -> Bool {
        if let navClass, object.isKind(of: navClass) { return true }
        return object.responds(to: NSSelectorFromString("sendResponseForDestination:"))
    }

    private static func collectActions(from value: Any, navClass: AnyClass?, into results: inout [NSObject]) {
        if let obj = value as? NSObject, isNavigationAction(obj, navClass: navClass) {
            results.append(obj)
            return
        }
        if let array = value as? NSArray {
            for item in array {
                if let obj = item as? NSObject, isNavigationAction(obj, navClass: navClass) {
                    results.append(obj)
                }
            }
        } else if let set = value as? NSSet {
            for item in set {
                if let obj = item as? NSObject, isNavigationAction(obj, navClass: navClass) {
                    results.append(obj)
                }
            }
        } else if let dict = value as? NSDictionary {
            for item in dict.allValues {
                if let obj = item as? NSObject, isNavigationAction(obj, navClass: navClass) {
                    results.append(obj)
                }
            }
        }
    }

    private static func extractNavigationActions(from owner: NSObject, navClass: AnyClass?) -> [NSObject] {
        var results: [NSObject] = []
        for name in ["_systemNavigationAction", "systemNavigationAction"] {
            let selector = NSSelectorFromString(name)
            if owner.responds(to: selector),
               let value = owner.perform(selector)?.takeUnretainedValue() as? NSObject {
                collectActions(from: value, navClass: navClass, into: &results)
            }
            if let ivar = class_getInstanceVariable(type(of: owner), name),
               let encPtr = ivar_getTypeEncoding(ivar),
               String(cString: encPtr).hasPrefix("@"),
               let value = object_getIvar(owner, ivar) {
                collectActions(from: value, navClass: navClass, into: &results)
            }
        }
        var currentClass: AnyClass? = type(of: owner)
        while let cls = currentClass, cls != NSObject.self {
            var count: UInt32 = 0
            if let ivars = class_copyIvarList(cls, &count) {
                defer { free(ivars) }
                for index in 0..<Int(count) {
                    let ivar = ivars[index]
                    guard let encPtr = ivar_getTypeEncoding(ivar) else { continue }
                    let encoding = String(cString: encPtr)
                    guard encoding.hasPrefix("@") else { continue }
                    let name = ivar_getName(ivar).map { String(cString: $0).lowercased() } ?? ""
                    let matches = encoding.contains("SystemNavigationAction")
                        || name.contains("systemnavigation")
                        || name.contains("breadcrumb")
                    guard matches, let value = object_getIvar(owner, ivar) else { continue }
                    collectActions(from: value, navClass: navClass, into: &results)
                }
            }
            currentClass = class_getSuperclass(cls)
        }
        return results
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

    /// Opens the URL exposed by `UISystemNavigationAction.URLForDestination:`
    /// when `sendResponseForDestination:` and bundle ID lookup both fail.
    @discardableResult
    func openSystemNavigationURL() -> Bool {
        let selector = NSSelectorFromString("URLForDestination:")
        for (action, destination) in systemNavigationActions() {
            guard action.responds(to: selector), let method = action.method(for: selector) else { continue }
            typealias DestURL = @convention(c) (AnyObject, Selector, UInt) -> Unmanaged<NSURL>?
            guard let url = unsafeBitCast(method, to: DestURL.self)(action, selector, destination)?.takeUnretainedValue() as URL?,
                  url.scheme != "capswriterlab" else { continue }
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return true
        }
        return false
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

    /// Compact, privacy-free diagnostic code shown only when auto-return fails.
    func diagnosticSummary(reported: String?) -> String {
        let nav = systemNavigationActions().count
        let cur = Self.source(of: observed?.value(forKey: "currentState") as? NSObject) != nil ? 1 : 0
        let obs = lastHost != nil ? 1 : 0
        let rep = reported.flatMap { Self.isOwn($0) ? nil : $0 } != nil ? 1 : 0
        return "[nav:\(nav) kb:\(cur)/\(obs) rep:\(rep)]"
    }

    /// A readable name for the status line.
    static func displayName(_ bundleID: String) -> String {
        let names = ["com.tencent.xin": "微信", "com.apple.mobilenotes": "备忘录",
                     "com.apple.MobileSMS": "信息", "com.tencent.mqq": "QQ",
                     "com.apple.mobilesafari": "Safari", "com.anthropic.claude": "Claude"]
        return names[bundleID] ?? bundleID
    }

    /// Opens the host app by URL scheme. Returns false when it isn't in the
    /// catalog; if iOS rejects the scheme asynchronously, `onFailure` runs.
    @discardableResult
    func open(_ bundleID: String, onFailure: (() -> Void)? = nil) -> Bool {
        guard let raw = Self.schemes[bundleID], let url = URL(string: raw) else { return false }
        UIApplication.shared.open(url, options: [:]) { opened in
            if !opened { onFailure?() }
        }
        return true
    }
}
