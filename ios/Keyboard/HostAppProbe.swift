import Darwin
import Foundation
import ObjectiveC
import UIKit

/// Resolves which host app the keyboard extension is currently typing into, so
/// Lab can jump straight back after starting or renewing the voice session.
///
/// Starting in iOS 26.4, `_hostBundleID` on the parent controller returns nil,
/// and `_UIRemoteKeyboards` inside the extension process is empty (`rep:0`).
/// This probe checks all remaining runtime sources safely without calling
/// arbitrary UIKit view/layout getters:
/// 1. direct host keys on the controller, parent, and extension context;
/// 2. `_UIRemoteKeyboards.currentState` (`sourceBundleIdentifier`,
///    `hostBundleIdentifier`, `sourceSceneIdentityString`);
/// 3. a bounded walk over state/traits/context objects (`_UIInputViewControllerState`,
///    `RTIDocumentTraits` / `TIDocumentTraits`, `FBSSceneIdentity`,
///    `BSProcessHandle`, `NSXPCConnection`) via allowlisted state getters and
///    non-weak typed object ivars (`bundleId`, `appId`, `sceneID`, `appName`);
/// 4. host PIDs (`_hostPID`, `RTIDocumentTraits.processId`, XPC `processIdentifier`)
///    resolved via `proc_pidpath` / `proc_name` against `HostBundleID.executables`.
enum HostAppProbe {
    struct Result {
        var bundleID: String?
        var code: String
    }

    /// Crash-guard flag: if the extension ever dies mid-walk, future launches
    /// skip the walk automatically.
    private static let runningKey = "hostProbe.walkRunning"
    private static let disabledKey = "hostProbe.walkDisabled"

    static func valid(_ raw: String?) -> String? {
        HostBundleID.normalize(raw)
    }

    static func run(controller: UIInputViewController) -> Result {
        if let id = directKey(on: controller) { return Result(bundleID: id, code: "h") }
        if let id = remoteKeyboardSource() { return Result(bundleID: id, code: "r") }

        var notes: [String] = []
        var pids = directPIDs(on: controller)

        let defaults = UserDefaults.standard
        if defaults.bool(forKey: runningKey) {
            defaults.set(true, forKey: disabledKey)
            defaults.removeObject(forKey: runningKey)
        }
        if defaults.bool(forKey: disabledKey) {
            notes.append("wX")
        } else {
            defaults.set(true, forKey: runningKey)
            var walk = Walk()
            walk.run(roots: roots(of: controller))
            defaults.removeObject(forKey: runningKey)
            if let found = walk.found {
                return Result(bundleID: found.id, code: "t" + found.path)
            }
            pids += walk.pids
            var summary = "w\(walk.visited)"
            if walk.traitsSeen {
                summary += "T" + (walk.traitsFlags.isEmpty ? "0" : walk.traitsFlags)
            }
            if walk.timedOut { summary += "o" }
            notes.append(summary)
            if let guess = walk.candidates.first(where: { isLikelyApp($0.id) }) {
                return Result(bundleID: guess.id, code: notes.joined(separator: ".") + ".g" + guess.path)
            }
            if !walk.candidates.isEmpty { notes.append("g\(walk.candidates.count)") }
        }

        let own = getpid()
        var tried = Set<Int32>()
        for pid in pids where pid > 0 && pid != own && tried.insert(pid).inserted {
            guard let name = executableName(of: pid) else { notes.append("pN"); continue }
            if let id = HostBundleID.executables[name] {
                return Result(bundleID: id, code: "x" + sanitize(name))
            }
            notes.append("n" + sanitize(name))
        }
        if tried.isEmpty { notes.append("p0") }
        return Result(bundleID: nil, code: notes.joined(separator: "."))
    }

    static func sanitize(_ text: String, limit: Int = 24) -> String {
        String(text.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(limit))
    }

    static func isLikelyApp(_ id: String) -> Bool {
        if HostBundleID.knownBundleIDs.contains(id) { return true }
        let lower = id.lowercased()
        if lower.hasPrefix("com.apple.") { return false }
        return !(lower.contains("keyboard") || lower.contains("inputmode") || lower.contains("uikit")
                 || lower.contains("framework") || lower.contains("extension"))
    }

    // MARK: - Routes 1 and 2

    private static func directKey(on controller: UIInputViewController) -> String? {
        let possible: [NSObject?] = [controller.parent, controller, controller.extensionContext]
        let owners = possible.compactMap { $0 }
        for owner in owners {
            for key in ["_hostBundleID", "_hostApplicationBundleIdentifier", "hostBundleID",
                        "_hostBundleIdentifier", "_hostSceneIdentifier"] {
                if let id = valid(getString(owner, key)) { return id }
            }
        }
        return nil
    }

    private static func remoteKeyboards() -> NSObject? {
        guard let type = NSClassFromString("_UIRemoteKeyboards") else { return nil }
        let shared = NSSelectorFromString("sharedRemoteKeyboards")
        let typeObject = type as AnyObject
        guard typeObject.responds(to: shared) else { return nil }
        return typeObject.perform(shared)?.takeUnretainedValue() as? NSObject
    }

    private static func remoteKeyboardSource() -> String? {
        guard let keyboards = remoteKeyboards(),
              let state = getObject(keyboards, "currentState") else { return nil }
        for key in ["sourceBundleIdentifier", "hostBundleIdentifier", "sourceSceneIdentityString"] {
            if let id = valid(getString(state, key)) { return id }
        }
        if let sceneIdentity = getObject(state, "sourceSceneIdentity"),
           let id = valid(getString(sceneIdentity, "identifier")) {
            return id
        }
        return nil
    }

    // MARK: - Route 4 helpers (PID -> executable)

    private static func directPIDs(on controller: UIInputViewController) -> [Int32] {
        var result: [Int32] = []
        let possible: [NSObject?] = [controller.parent, controller, controller.extensionContext]
        let owners = possible.compactMap { $0 }
        for owner in owners {
            for key in ["_hostPID", "_hostProcessIdentifier", "hostPID", "_hostPid"] {
                if let pid = getInt32(owner, key), pid > 0 { result.append(pid) }
            }
        }
        return result
    }

    private typealias ProcPath = @convention(c) (Int32, UnsafeMutableRawPointer?, UInt32) -> Int32

    static func executableName(of pid: Int32) -> String? {
        let anywhere = UnsafeMutableRawPointer(bitPattern: -2)
        if let symbol = dlsym(anywhere, "proc_pidpath") {
            let call = unsafeBitCast(symbol, to: ProcPath.self)
            var buffer = [CChar](repeating: 0, count: 4096)
            let length = buffer.withUnsafeMutableBytes { call(pid, $0.baseAddress, UInt32($0.count)) }
            if length > 0 {
                let name = (String(cString: buffer) as NSString).lastPathComponent
                if !name.isEmpty { return name }
            }
        }
        if let symbol = dlsym(anywhere, "proc_name") {
            let call = unsafeBitCast(symbol, to: ProcPath.self)
            var buffer = [CChar](repeating: 0, count: 256)
            let length = buffer.withUnsafeMutableBytes { call(pid, $0.baseAddress, UInt32($0.count)) }
            if length > 0 {
                let name = String(cString: buffer)
                if !name.isEmpty { return name }
            }
        }
        return nil
    }

    // MARK: - Safe runtime accessors

    static func getObject(_ object: NSObject, _ getter: String) -> NSObject? {
        let selector = NSSelectorFromString(getter)
        guard object.responds(to: selector),
              let instanceMethod = class_getInstanceMethod(type(of: object), selector),
              method_getNumberOfArguments(instanceMethod) == 2 else { return nil }
        var ret = [CChar](repeating: 0, count: 8)
        method_getReturnType(instanceMethod, &ret, ret.count)
        guard ret[0] == CChar(UInt8(ascii: "@")),
              let imp = object.method(for: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        return unsafeBitCast(imp, to: Getter.self)(object, selector)?.takeUnretainedValue() as? NSObject
    }

    static func getString(_ object: NSObject, _ getter: String) -> String? {
        getObject(object, getter) as? String
    }

    static func getInt32(_ object: NSObject, _ getter: String) -> Int32? {
        let selector = NSSelectorFromString(getter)
        guard object.responds(to: selector),
              let instanceMethod = class_getInstanceMethod(type(of: object), selector),
              method_getNumberOfArguments(instanceMethod) == 2 else { return nil }
        var ret = [CChar](repeating: 0, count: 8)
        method_getReturnType(instanceMethod, &ret, ret.count)
        guard let imp = object.method(for: selector) else { return nil }
        switch ret[0] {
        case CChar(UInt8(ascii: "i")), CChar(UInt8(ascii: "I")):
            typealias Int32Getter = @convention(c) (AnyObject, Selector) -> Int32
            return unsafeBitCast(imp, to: Int32Getter.self)(object, selector)
        case CChar(UInt8(ascii: "q")), CChar(UInt8(ascii: "Q")):
            typealias Int64Getter = @convention(c) (AnyObject, Selector) -> Int64
            let val = unsafeBitCast(imp, to: Int64Getter.self)(object, selector)
            return Int32(truncatingIfNeeded: val)
        case CChar(UInt8(ascii: "@")):
            typealias ObjGetter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
            return (unsafeBitCast(imp, to: ObjGetter.self)(object, selector)?.takeUnretainedValue() as? NSNumber)?.int32Value
        default:
            return nil
        }
    }

    /// Returns nil when the class has no `__weak` ivars at all (so every
    /// typed object ivar is safe to read), or the set of backing ivar names
    /// proven non-weak via their `@property` attributes (`V<ivar>` without `W`).
    static func safeStrongIvars(of cls: AnyClass) -> Set<String>? {
        if class_getWeakIvarLayout(cls) == nil { return nil }
        var count: UInt32 = 0
        guard let props = class_copyPropertyList(cls, &count) else { return [] }
        defer { free(props) }
        var names = Set<String>()
        for idx in 0..<Int(count) {
            guard let rawAttr = property_getAttributes(props[idx]) else { continue }
            let parts = String(cString: rawAttr).split(separator: ",")
            guard !parts.contains("W") else { continue }
            for part in parts where part.hasPrefix("V") {
                names.insert(String(part.dropFirst()))
            }
        }
        return names
    }

    // MARK: - Route 3: bounded state & ivar walk

    private static func roots(of controller: UIInputViewController) -> [(NSObject, String)] {
        var list: [(NSObject, String)] = [(controller, "c")]
        if let parent = controller.parent { list.append((parent, "p")) }
        if let proxy = controller.textDocumentProxy as? NSObject { list.append((proxy, "d")) }
        if let context = controller.extensionContext {
            list.append((context, "e"))
            for (index, item) in context.inputItems.prefix(4).enumerated() {
                if let obj = item as? NSObject { list.append((obj, "i\(index)")) }
            }
        }
        if let impl = NSClassFromString("UIKeyboardImpl") as AnyObject?,
           impl.responds(to: NSSelectorFromString("activeInstance")),
           let active = impl.perform(NSSelectorFromString("activeInstance"))?.takeUnretainedValue() as? NSObject {
            list.append((active, "k"))
        }
        if let keyboards = remoteKeyboards() { list.append((keyboards, "r")) }
        return list
    }

    private struct Walk {
        var visited = 0
        var found: (id: String, path: String)?
        var candidates: [(id: String, path: String)] = []
        var pids: [Int32] = []
        var traitsSeen = false
        var traitsFlags = ""
        var timedOut = false
        private var seen = Set<ObjectIdentifier>()
        private let deadline = Date().addingTimeInterval(0.12)
        private static let maxObjects = 450
        private static let maxDepth = 5

        /// Explicit state/connection selectors that are pure accessors (never
        /// lazy view/window/layout builders).
        private static let safeStateGetters = [
            "_inputViewControllerState", "_controllerState", "_textDocumentInterface",
            "_forwardingInterface", "documentTraits", "rtiDocumentTraits", "documentState",
            "_auxiliaryConnection", "_inputDelegateManager", "remoteTextInputPartner",
            "currentState", "sourceSceneIdentity", "userInfo", "_internal", "_extensionContext"
        ]

        private static let skippedIvarNames: Set<String> = [
            "_view", "_inputView", "_window", "_layer", "_traitCollection", "_storyboard",
            "_navigationItem", "_tabBarItem", "_toolbarItems", "_childModalViewControllers",
            "_parentViewController", "_PresentingViewController", "_gestureRecognizers",
            "_constraintsExceptingSubviewAutoresizingConstraints", "_keyCommands"
        ]

        private static let skippedTypes: Set<String> = [
            "UIView", "UIWindow", "CALayer", "UIImage", "UIColor", "UIFont", "UIScreen",
            "UITraitCollection", "NSData", "NSDate", "NSURL", "NSNumber",
            "UIBezierPath", "NSAttributedString", "UIGestureRecognizer", "NSLayoutConstraint"
        ]

        private static let leafClasses: [AnyClass] = [
            UIView.self, CALayer.self, UIImage.self, UIColor.self, UIFont.self, UIScreen.self,
            UITraitCollection.self, NSString.self, NSNumber.self, NSData.self, NSDate.self,
            NSURL.self, NSAttributedString.self, UIGestureRecognizer.self
        ]

        mutating func run(roots: [(NSObject, String)]) {
            var queue: [(object: NSObject, path: String, depth: Int)] = roots.map {
                (object: $0.0, path: $0.1, depth: 0)
            }
            var index = 0
            while index < queue.count {
                guard visited < Self.maxObjects else { return }
                guard Date() < deadline else { timedOut = true; return }
                let item = queue[index]; index += 1
                guard seen.insert(ObjectIdentifier(item.object)).inserted else { continue }
                visited += 1
                let children = inspect(item.object, path: item.path, collectChildren: item.depth < Self.maxDepth)
                if found != nil { return }
                for child in children {
                    queue.append((object: child.0, path: item.path + "-" + child.1, depth: item.depth + 1))
                }
            }
        }

        private static func isLeaf(_ object: NSObject) -> Bool {
            leafClasses.contains { object.isKind(of: $0) }
        }

        private static func declaredTypeIsSkipped(_ encoding: String) -> Bool {
            guard encoding.hasPrefix("@\""), encoding.count > 3 else { return true }
            let inner = String(encoding.dropFirst(2).prefix { $0 != "\"" && $0 != "<" })
            if inner.isEmpty || skippedTypes.contains(inner) { return true }
            return inner.hasSuffix("View") || inner.hasSuffix("Layer") || inner.hasSuffix("Window")
                || inner.hasSuffix("Constraint") || inner.hasSuffix("Recognizer")
        }

        private static func shortName(_ name: String) -> String {
            HostAppProbe.sanitize(name, limit: 14)
        }

        private static func compact(_ path: String) -> String {
            HostAppProbe.sanitize(path.replacingOccurrences(of: "-", with: "Z"), limit: 56)
        }

        private mutating func addFlag(_ ch: String) {
            if !traitsFlags.contains(ch) { traitsFlags += ch }
        }

        private mutating func record(_ id: String, path: String) {
            found = (id, Self.compact(path))
        }

        private mutating func consider(_ id: String, path: String) {
            guard candidates.count < 8, !candidates.contains(where: { $0.id == id }) else { return }
            candidates.append((id, Self.compact(path)))
        }

        private mutating func inspectTraits(_ object: NSObject, path: String) {
            traitsSeen = true
            for key in ["bundleId", "bundleID", "bundleIdentifier", "hostBundleIdentifier",
                        "sourceBundleIdentifier", "applicationBundleIdentifier", "appBundleIdentifier"] {
                if let raw = HostAppProbe.getString(object, key), !raw.isEmpty {
                    addFlag("B")
                    if let id = HostBundleID.normalize(raw) { record(id, path: path + "-" + key); return }
                }
            }
            for key in ["appId", "appID"] {
                if let raw = HostAppProbe.getString(object, key), !raw.isEmpty {
                    addFlag("A")
                    if let id = HostBundleID.normalize(raw) { record(id, path: path + "-" + key); return }
                }
            }
            for key in ["sceneID", "sceneIdentity", "sourceSceneIdentityString"] {
                if let raw = HostAppProbe.getString(object, key), !raw.isEmpty {
                    addFlag("S")
                    if let id = HostBundleID.normalize(raw) { record(id, path: path + "-" + key); return }
                }
            }
            for key in ["appName", "localizedAppName"] {
                if let raw = HostAppProbe.getString(object, key), !raw.isEmpty {
                    addFlag("N")
                    if let id = HostBundleID.fromAppName(raw) { record(id, path: path + "-" + key); return }
                }
            }
            for key in ["processId", "processIdentifier", "pid"] {
                if let pid = HostAppProbe.getInt32(object, key), pid > 0 {
                    addFlag("P")
                    pids.append(pid)
                }
            }
        }

        private mutating func inspect(_ object: NSObject, path: String, collectChildren: Bool) -> [(NSObject, String)] {
            let className = NSStringFromClass(type(of: object))

            // 1. NSXPCConnection (looked up dynamically because NSXPCConnection is API_UNAVAILABLE on iOS).
            if className.contains("XPCConnection") {
                if let pid = HostAppProbe.getInt32(object, "processIdentifier"), pid > 0 {
                    pids.append(pid)
                }
                return []
            }

            // 2. BSProcessHandle / FBSProcessHandle.
            if className.contains("ProcessHandle") {
                for key in ["bundleIdentifier", "jobLabel"] {
                    if let id = HostBundleID.normalize(HostAppProbe.getString(object, key)) {
                        record(id, path: path + "-" + key); return []
                    }
                }
                if let name = HostAppProbe.getString(object, "name"),
                   let id = HostBundleID.executables[name] {
                    record(id, path: path + "-name"); return []
                }
                if let pid = HostAppProbe.getInt32(object, "pid"), pid > 0 { pids.append(pid) }
            }

            // 3. FBSSceneIdentity / UISceneIdentityToken.
            if className.contains("SceneIdentity") {
                for key in ["identifier", "stringRepresentation"] {
                    if let id = HostBundleID.normalize(HostAppProbe.getString(object, key)) {
                        record(id, path: path + "-" + key); return []
                    }
                }
            }

            // 4. Collection containers.
            if let array = object as? NSArray {
                return array.prefix(6).compactMap { $0 as? NSObject }.filter { !Self.isLeaf($0) }.enumerated()
                    .map { ($0.element, "i\($0.offset)") }
            }
            if let set = object as? NSSet {
                return set.allObjects.prefix(6).compactMap { $0 as? NSObject }.filter { !Self.isLeaf($0) }.enumerated()
                    .map { ($0.element, "i\($0.offset)") }
            }
            if let dictionary = object as? NSDictionary {
                for (rawKey, rawValue) in dictionary {
                    if let key = rawKey as? String {
                        let lower = key.lowercased()
                        if lower.contains("bundle") || lower.contains("appid") || lower.contains("sceneid"),
                           let id = HostBundleID.normalize(rawValue as? String) {
                            consider(id, path: path + "-" + Self.shortName(key))
                        } else if lower.contains("appname"),
                                  let id = HostBundleID.fromAppName(rawValue as? String) {
                            consider(id, path: path + "-" + Self.shortName(key))
                        }
                    }
                }
                return dictionary.allValues.prefix(6).compactMap { $0 as? NSObject }.filter { !Self.isLeaf($0) }.enumerated()
                    .map { ($0.element, "v\($0.offset)") }
            }

            // 5. RTIDocumentTraits / TIDocumentTraits.
            if className.contains("DocumentTraits") {
                inspectTraits(object, path: path)
                if found != nil { return [] }
            }

            var children: [(NSObject, String)] = []

            // 6. Explicit allowlisted state/connection getters.
            if collectChildren {
                for getter in Self.safeStateGetters {
                    if let child = HostAppProbe.getObject(object, getter),
                       child !== object, !Self.isLeaf(child) {
                        children.append((child, Self.shortName(getter)))
                    }
                }
            }

            // 7. Side-effect-free ivar traversal (all ivars on weak-free classes,
            //    plus property-verified non-weak ivars on classes that have weak refs).
            var cls: AnyClass? = type(of: object)
            while let current = cls, current != NSObject.self, current != UIResponder.self {
                let currentName = NSStringFromClass(current)
                if !currentName.contains(".") {
                    let allowedStrong = HostAppProbe.safeStrongIvars(of: current)
                    var count: UInt32 = 0
                    if let ivars = class_copyIvarList(current, &count) {
                        defer { free(ivars) }
                        for idx in 0..<Int(count) {
                            let ivar = ivars[idx]
                            guard let rawName = ivar_getName(ivar),
                                  let rawEnc = ivar_getTypeEncoding(ivar) else { continue }
                            let ivarName = String(cString: rawName)
                            let encoding = String(cString: rawEnc)
                            let lower = ivarName.lowercased()

                            if encoding == "i" || encoding == "I" {
                                if lower.contains("pid") || lower.contains("processid"),
                                   let pid = HostAppProbe.getInt32(object, String(ivarName.drop { $0 == "_" })),
                                   pid > 0 {
                                    pids.append(pid)
                                }
                                continue
                            }

                            if let allowedStrong, !allowedStrong.contains(ivarName) { continue }

                            if encoding == "@\"NSString\"" {
                                if lower.contains("bundle") || lower.contains("appid") || lower.contains("sceneid")
                                    || lower.contains("sourceapp") || lower.contains("hostapp") {
                                    if let id = HostBundleID.normalize(object_getIvar(object, ivar) as? String) {
                                        if className.contains("DocumentTraits") {
                                            record(id, path: path + "-" + Self.shortName(ivarName)); return []
                                        }
                                        consider(id, path: path + "-" + Self.shortName(ivarName))
                                    }
                                } else if lower.contains("appname"),
                                          let id = HostBundleID.fromAppName(object_getIvar(object, ivar) as? String) {
                                    if className.contains("DocumentTraits") {
                                        record(id, path: path + "-" + Self.shortName(ivarName)); return []
                                    }
                                    consider(id, path: path + "-" + Self.shortName(ivarName))
                                }
                                continue
                            }

                            guard collectChildren, !Self.skippedIvarNames.contains(ivarName),
                                  !Self.declaredTypeIsSkipped(encoding),
                                  let value = object_getIvar(object, ivar) as? NSObject,
                                  value !== object, !Self.isLeaf(value) else { continue }
                            children.append((value, Self.shortName(ivarName)))
                        }
                    }
                }
                cls = class_getSuperclass(current)
            }
            return children
        }
    }
}
