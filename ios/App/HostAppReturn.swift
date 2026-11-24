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
    /// Every `_UIRemoteKeyboards` instance being observed. Kept strongly so
    /// none is deallocated while observed.
    private var observedKeyboards: [NSObject] = []
    private var started = false
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

    static func isOwn(_ bundleID: String) -> Bool {
        HostBundleID.isOwnOrSystemOverlay(bundleID)
    }

    static func sourceBundleID(fromOpenURLOptions options: [UIApplication.OpenURLOptionsKey: Any]) -> String? {
        if let app = HostBundleID.normalize(options[.sourceApplication] as? String) {
            return app
        }
        let handleKey = UIApplication.OpenURLOptionsKey(rawValue: "_UIApplicationOpenURLOptionsSourceProcessHandleKey")
        if let handle = options[handleKey] as? NSObject {
            for key in ["bundleIdentifier", "jobLabel"] {
                let sel = NSSelectorFromString(key)
                if handle.responds(to: sel),
                   let raw = handle.perform(sel)?.takeUnretainedValue() as? String,
                   let id = HostBundleID.normalize(raw) {
                    return id
                }
            }
            let nameSel = NSSelectorFromString("name")
            if handle.responds(to: nameSel),
               let name = handle.perform(nameSel)?.takeUnretainedValue() as? String,
               let id = HostBundleID.executables[name] {
                return id
            }
        }
        return nil
    }

    /// Start watching the system keyboard state. Call once at launch.
    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.backgroundedAt = Date()
        }
        for name in [UIApplication.willEnterForegroundNotification, UIApplication.didBecomeActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.attachKeyboardObservers()
            }
        }
        attachKeyboardObservers()
    }

    /// Observes every `_UIRemoteKeyboards` instance that can be found.
    ///
    /// On recent iOS the class-level `sharedRemoteKeyboards` object no longer
    /// receives the host app's keyboard state; the live instance hangs off the
    /// window scene's keyboard scene delegate and may only exist once Lab is
    /// on screen. Safe to call repeatedly: known instances are skipped, and
    /// `.initial` reports the value a new instance already holds (the state is
    /// transient, so it must be caught when it arrives, not polled later).
    func attachKeyboardObservers() {
        let currentState = NSSelectorFromString("currentState")
        for keyboards in Self.remoteKeyboardCandidates()
        where keyboards.responds(to: currentState) && !observedKeyboards.contains(where: { $0 === keyboards }) {
            observedKeyboards.append(keyboards)
            keyboards.addObserver(self, forKeyPath: "currentState", options: [.new, .initial], context: nil)
        }
    }

    private static func remoteKeyboardCandidates() -> [NSObject] {
        guard let remoteClass = NSClassFromString("_UIRemoteKeyboards") else { return [] }
        var found: [NSObject] = []
        func add(_ object: NSObject?) {
            guard let object, object.isKind(of: remoteClass),
                  !found.contains(where: { $0 === object }) else { return }
            found.append(object)
        }
        add(classObject(remoteClass, "sharedRemoteKeyboards"))
        var delegates: [NSObject] = []
        if let sceneDelegateClass = NSClassFromString("UIKeyboardSceneDelegate") {
            for name in ["automaticKeyboardArbiterClient", "keyboardArbiterClient"] {
                add(classObject(sceneDelegateClass, name))
            }
            if let active = classObject(sceneDelegateClass, "activeKeyboardSceneDelegate") {
                delegates.append(active)
            }
        }
        for scene in UIApplication.shared.connectedScenes {
            for name in ["_registeredComponents", "_sceneComponents"] {
                guard let components = object(scene, name) else { continue }
                var values: [NSObject] = []
                let lookup = NSSelectorFromString("objectForKey:")
                if components.responds(to: lookup),
                   let hit = components.perform(lookup, with: "_UIKeyboardSceneDelegateSceneComponentKey")?
                       .takeUnretainedValue() as? NSObject {
                    values.append(hit)
                }
                values += members(of: components).filter {
                    NSStringFromClass(type(of: $0)).contains("KeyboardSceneDelegate")
                }
                for value in values where !delegates.contains(where: { $0 === value }) {
                    delegates.append(value)
                }
            }
        }
        for delegate in delegates {
            for name in ["arbiterClient", "keyboardArbiterClient", "remoteKeyboards"] {
                add(object(delegate, name))
            }
            // UIKeyboardSceneDelegate → container window → editing overlay
            // controller → its parent (input window controller) → hosting →
            // hosting items → each item's controller delegate.
            guard let window = object(delegate, "containerWindow"),
                  let overlay = object(window, "editingOverlayViewController") else { continue }
            var parentCandidate: NSObject? = object(overlay, "parentViewController")
            if let controller = overlay as? UIViewController, let up = controller.parent { parentCandidate = up }
            guard let parent = parentCandidate, let hosting = object(parent, "hosting"),
                  let items = object(hosting, "hostingItems") else { continue }
            for item in members(of: items) {
                add(item)
                add(object(item, "controllerDelegate"))
            }
        }
        return found
    }

    /// Elements of an array, set, pointer array, hash table, dictionary or map table.
    private static func members(of container: NSObject) -> [NSObject] {
        if let array = container as? NSArray { return array.compactMap { $0 as? NSObject } }
        if let set = container as? NSSet { return set.allObjects.compactMap { $0 as? NSObject } }
        if let dictionary = container as? NSDictionary { return dictionary.allValues.compactMap { $0 as? NSObject } }
        for name in ["allObjects", "objectEnumerator"] {
            guard let value = getter(container, name) else { continue }
            if let array = value as? NSArray { return array.compactMap { $0 as? NSObject } }
            if let enumerator = value as? NSEnumerator { return enumerator.allObjects.compactMap { $0 as? NSObject } }
        }
        return []
    }

    /// Calls a no-argument, object-returning class method if it exists.
    private static func classObject(_ cls: AnyClass, _ name: String) -> NSObject? {
        let selector = NSSelectorFromString(name)
        guard let method = class_getClassMethod(cls, selector),
              method_getNumberOfArguments(method) == 2, returnsObject(method) else { return nil }
        let receiver = cls as AnyObject
        return receiver.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    /// Reads `name` through a getter (`name`, then `_name`), else through an
    /// object-typed ivar (`_name`, then `name`).
    private static func object(_ owner: NSObject, _ name: String) -> NSObject? {
        let bare = name.hasPrefix("_") ? String(name.dropFirst()) : name
        if let value = getter(owner, bare) ?? getter(owner, "_" + bare) { return value }
        for ivarName in ["_" + bare, bare] {
            guard let ivar = class_getInstanceVariable(type(of: owner), ivarName),
                  let encoding = ivar_getTypeEncoding(ivar), String(cString: encoding).hasPrefix("@"),
                  let value = object_getIvar(owner, ivar) as? NSObject else { continue }
            return value
        }
        return nil
    }

    private static func getter(_ owner: NSObject, _ name: String) -> NSObject? {
        let selector = NSSelectorFromString(name)
        guard owner.responds(to: selector),
              let method = class_getInstanceMethod(type(of: owner), selector),
              method_getNumberOfArguments(method) == 2, returnsObject(method) else { return nil }
        return owner.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    private static func returnsObject(_ method: Method) -> Bool {
        var type = [CChar](repeating: 0, count: 8)
        method_getReturnType(method, &type, type.count)
        return type[0] == CChar(UInt8(ascii: "@"))
    }

    /// The host named by any observed keyboard state right now.
    private func currentHost() -> String? {
        for keyboards in observedKeyboards {
            if let id = Self.source(of: Self.object(keyboards, "currentState")) { return id }
        }
        return nil
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == "currentState" else { return }
        let state = change?[.newKey] as? NSObject
        let id = Self.source(of: state)
        let note = state.map { Self.stateNote($0) }
        let at = Date()
        let dump = state.map { Self.dump($0, depth: 0) }
        DispatchQueue.main.async {
            self.events += 1
            if let dump { self.stateDumps.append(dump); if self.stateDumps.count > 4 { self.stateDumps.removeFirst() } }
            if let note { self.statesSeen += 1; self.stateNotes.formUnion(note) }
            if let id { self.lastHost = (id, at) }
        }
    }

    /// Diagnostics: keyboard state events received, how many carried a
    /// state object, and which kinds of identifier fields were non-empty.
    private var events = 0
    private var statesSeen = 0
    private var stateNotes = Set<Character>()
    private var stateDumps: [String] = []

    /// Layout of the last keyboard state objects (UIKit ivar names, types
    /// and short values), so the user can paste it back when the host is
    /// still not found on a new iOS version.
    var stateDumpText: String {
        "SayKey kb-state \(UIDevice.current.systemVersion) ev:\(events)\n" + stateDumps.joined(separator: "\n---\n")
    }

    /// nil when the class has no weak ivars; otherwise the ivars proven
    /// strong by their property attributes.
    private static func strongIvarNames(of cls: AnyClass) -> Set<String>? {
        guard class_getWeakIvarLayout(cls) != nil else { return nil }
        var count: UInt32 = 0
        guard let props = class_copyPropertyList(cls, &count) else { return [] }
        defer { free(props) }
        var names = Set<String>()
        for index in 0..<Int(count) {
            guard let raw = property_getAttributes(props[index]) else { continue }
            let attrs = String(cString: raw).split(separator: ",")
            guard !attrs.contains("W") else { continue }
            for attr in attrs where attr.hasPrefix("V") { names.insert(String(attr.dropFirst())) }
        }
        return names
    }

    private static func dump(_ object: NSObject, depth: Int) -> String {
        var parts: [String] = []
        var cls: AnyClass? = type(of: object)
        while let current = cls, current != NSObject.self, parts.count < 40 {
            var count: UInt32 = 0
            if let ivars = class_copyIvarList(current, &count) {
                defer { free(ivars) }
                for index in 0..<Int(count) where parts.count < 40 {
                    let ivar = ivars[index]
                    guard let rawName = ivar_getName(ivar), let rawType = ivar_getTypeEncoding(ivar) else { continue }
                    let name = String(cString: rawName)
                    let encoding = String(cString: rawType)
                    let base = Unmanaged.passUnretained(object).toOpaque().advanced(by: ivar_getOffset(ivar))
                    var value = "?"
                    switch encoding.first ?? " " {
                    case "@":
                        // Weak ivars are skipped: reading them raw is unsafe.
                        if let allowed = strongIvarNames(of: current), !allowed.contains(name) { value = "w"; break }
                        guard let child = object_getIvar(object, ivar) as AnyObject? else { value = "nil"; break }
                        if let text = child as? String {
                            value = "\"" + String(text.prefix(80)) + "\""
                        } else if let number = child as? NSNumber {
                            value = number.stringValue
                        } else if let child = child as? NSObject {
                            let childClass = NSStringFromClass(type(of: child))
                            if depth < 2, !(child is UIView), !(child is CALayer), !(child is NSArray),
                               !(child is NSDictionary), !(child is NSSet) {
                                value = dump(child, depth: depth + 1)
                            } else if let array = child as? NSArray {
                                value = "\(childClass)[\(array.count)]"
                            } else {
                                value = childClass
                            }
                        }
                    case "i": value = String(base.load(as: Int32.self))
                    case "I": value = String(base.load(as: UInt32.self))
                    case "q": value = String(base.load(as: Int64.self))
                    case "Q": value = String(base.load(as: UInt64.self))
                    case "B": value = String(base.load(as: Bool.self))
                    case "c", "C": value = String(base.load(as: Int8.self))
                    default: value = String(encoding.prefix(12))
                    }
                    parts.append("\(name)=\(value)")
                }
            }
            cls = class_getSuperclass(current)
        }
        return NSStringFromClass(type(of: object)) + "{" + parts.joined(separator: "; ") + "}"
    }

    /// String ivars of the state object worth reading for the host: getters
    /// can be missing on newer iOS while the backing ivar is still filled.
    private static func stringFields(of state: NSObject) -> [(name: String, value: String)] {
        var result: [(name: String, value: String)] = []
        var cls: AnyClass? = type(of: state)
        while let current = cls, current != NSObject.self {
            var count: UInt32 = 0
            if let ivars = class_copyIvarList(current, &count) {
                defer { free(ivars) }
                for index in 0..<Int(count) {
                    let ivar = ivars[index]
                    guard let rawName = ivar_getName(ivar), let rawType = ivar_getTypeEncoding(ivar),
                          String(cString: rawType) == "@\"NSString\"" else { continue }
                    let name = String(cString: rawName)
                    let lower = name.lowercased()
                    guard lower.contains("bundle") || lower.contains("scene") || lower.contains("source")
                            || lower.contains("host") || lower.contains("appid") else { continue }
                    if let value = object_getIvar(state, ivar) as? String, !value.isEmpty {
                        result.append((name: name, value: value))
                    }
                }
            }
            cls = class_getSuperclass(current)
        }
        return result
    }

    /// Privacy-free summary of a state: B = bundle-like field filled,
    /// S = scene field filled, O = a field held only our own app or a
    /// system overlay.
    private static func stateNote(_ state: NSObject) -> Set<Character> {
        var note = Set<Character>()
        for field in stringFields(of: state) {
            note.insert(field.name.lowercased().contains("scene") ? "S" : "B")
            if HostBundleID.normalize(field.value) == nil { note.insert("O") }
        }
        return note
    }

    private static func source(of state: NSObject?) -> String? {
        guard let state else { return nil }
        for key in ["sourceBundleIdentifier", "hostBundleIdentifier", "sourceSceneIdentityString"] {
            if let raw = object(state, key) as? String, let id = HostBundleID.normalize(raw) {
                return id
            }
        }
        if let identity = object(state, "sourceSceneIdentity"),
           let raw = object(identity, "identifier") as? String,
           let id = HostBundleID.normalize(raw) {
            return id
        }
        // Any other identifier-like string field, bundle fields first.
        let fields = stringFields(of: state)
        let ordered = fields.filter { $0.name.lowercased().contains("bundle") }
            + fields.filter { !$0.name.lowercased().contains("bundle") }
        for field in ordered {
            if let id = HostBundleID.normalize(field.value) { return id }
        }
        return nil
    }

    /// The host to return to for a request that reached Lab at
    /// `requestedAt`, or nil while it is not (yet) known. Lab may still hold
    /// the host of an earlier visit when it wakes up, so the choice is left
    /// to `HostReturnPolicy`; call again until it answers or time runs out.
    func host(reported: String?, requestedAt: Date) -> String? {
        let reported = HostBundleID.normalize(reported) ?? systemNavigationBundleID()
        let current = currentHost()
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
            let allCompSel = NSSelectorFromString("_allComponents")
            if scene.responds(to: allCompSel),
               let comps = scene.perform(allCompSel)?.takeUnretainedValue() as? NSArray {
                for case let comp as NSObject in comps { owners.append(comp) }
            }
            if let ivar = class_getInstanceVariable(type(of: scene), "_sceneComponents"),
               let enc = ivar_getTypeEncoding(ivar), String(cString: enc).hasPrefix("@"),
               let dict = object_getIvar(scene, ivar) as? NSDictionary {
                for case let comp as NSObject in dict.allValues { owners.append(comp) }
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
    func diagnosticSummary(reported: String?, probe: String? = nil) -> String {
        let nav = systemNavigationActions().count
        let cur = currentHost() != nil ? 1 : 0
        let obs = lastHost != nil ? 1 : 0
        let rep = reported.flatMap { Self.isOwn($0) ? nil : $0 } != nil ? 1 : 0
        return "[nav:\(nav) kb:\(cur)/\(obs)/\(observedKeyboards.count) ev:\(events)/\(statesSeen)\(String(stateNotes.sorted())) rep:\(rep) kd:\(probe ?? "-")]"
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
