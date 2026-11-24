import Foundation
import ObjectiveC
import UIKit

/// Learns the host app inside the keyboard extension on iOS 26.4+, where
/// `_hostBundleID` is gone.
///
/// With `KeyboardArbiterActivation.m` the extension becomes a keyboard
/// arbiter client and receives the system keyboard state events. Each names
/// an app and its process; the events can be stale, so they only fill a
/// process → bundle ID table, and the host is looked up by the keyboard's
/// own host process ID at the moment of the tap. Undocumented throughout:
/// every step is checked at runtime and fails quietly.
final class HostArbiterWatch: NSObject {
    static let shared = HostArbiterWatch()
    private var observed: NSObject?
    private let lock = NSLock()
    private var table: [Int32: String] = [:]
    private var latest: (id: String, at: Date)?
    private var events = 0

    /// Start listening. Call once, early (viewDidLoad).
    func start() {
        guard observed == nil, let cls = NSClassFromString("_UIRemoteKeyboards") else { return }
        let selector = NSSelectorFromString("sharedRemoteKeyboards")
        let type = cls as AnyObject
        guard type.responds(to: selector),
              let keyboards = type.perform(selector)?.takeUnretainedValue() as? NSObject,
              keyboards.responds(to: NSSelectorFromString("currentState")) else { return }
        observed = keyboards
        keyboards.addObserver(self, forKeyPath: "currentState", options: [.new, .initial], context: nil)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == "currentState" else { return }
        let state = change?[.newKey] as? NSObject
        let id = state.flatMap { Self.bundleID(of: $0) }
        let pid = state.flatMap { Self.processID(of: $0) }
        lock.lock()
        events += 1
        if let id {
            latest = (id, Date())
            if let pid, pid > 0, table.count < 128 { table[pid] = id }
        }
        lock.unlock()
    }

    private var harvests = 0
    private var harvestedStates = 0

    /// The arbiter client the swizzle turns on. Its `currentClientState`
    /// names the app the keyboard is shown in together with that app's
    /// process; it fills about 200 ms after the keyboard appears and is
    /// polled (there is no event for it).
    private static func arbiterClient() -> NSObject? {
        for name in ["_UIKeyboardArbiterClient", "UIKeyboardArbiterClient"] {
            guard let cls = NSClassFromString(name) else { continue }
            let selector = NSSelectorFromString("automaticSharedArbiterClient")
            guard let method = class_getClassMethod(cls, selector), method_getNumberOfArguments(method) == 2 else { continue }
            let type = cls as AnyObject
            if let client = type.perform(selector)?.takeUnretainedValue() as? NSObject { return client }
        }
        return nil
    }

    /// Reads the arbiter client's state once and records its app and process.
    func harvest() {
        guard let client = Self.arbiterClient() else { return }
        let state = HostAppProbe.getObject(client, "currentClientState") ?? Self.objectIvar(client, "_currentClientState")
        let id = state.flatMap { Self.bundleID(of: $0) }
        let pid = state.flatMap { Self.processID(of: $0) }
        lock.lock()
        harvests += 1
        if state != nil { harvestedStates += 1 }
        if let id {
            latest = (id, Date())
            if let pid, pid > 0, table.count < 128 { table[pid] = id }
        }
        lock.unlock()
    }

    /// The host for this tap: by host process ID when the table knows it,
    /// else the newest event if it arrived during this keyboard appearance.
    func host(for controller: UIInputViewController, appearedAt: Date?) -> (id: String, code: String)? {
        harvest()
        let pids = Self.hostPIDs(of: controller)
        lock.lock(); defer { lock.unlock() }
        for pid in pids { if let id = table[pid] { return (id, "a") } }
        if let latest, let appearedAt, latest.at >= appearedAt.addingTimeInterval(-2) {
            return (latest.id, "l")
        }
        return nil
    }

    /// Privacy-free counters for the diagnostic line.
    var summary: String {
        lock.lock(); defer { lock.unlock() }
        return "A\(events)n\(table.count)h\(harvests)s\(harvestedStates)"
    }

    // MARK: - Field readers

    private static func bundleID(of state: NSObject) -> String? {
        for key in ["sourceBundleIdentifier", "hostBundleIdentifier"] {
            if let id = HostBundleID.normalize(HostAppProbe.getString(state, key) ?? stringIvar(state, "_" + key)) {
                return id
            }
        }
        var cls: AnyClass? = type(of: state)
        while let current = cls, current != NSObject.self {
            var count: UInt32 = 0
            if let ivars = class_copyIvarList(current, &count) {
                defer { free(ivars) }
                for index in 0..<Int(count) {
                    let ivar = ivars[index]
                    guard let rawName = ivar_getName(ivar), let rawType = ivar_getTypeEncoding(ivar),
                          String(cString: rawType) == "@\"NSString\"",
                          String(cString: rawName).lowercased().contains("bundle"),
                          let id = HostBundleID.normalize(object_getIvar(state, ivar) as? String) else { continue }
                    return id
                }
            }
            cls = class_getSuperclass(current)
        }
        return nil
    }

    private static func processID(of state: NSObject) -> Int32? {
        for key in ["sourceProcessIdentifier", "processIdentifier", "sourcePid", "pid"] {
            if let pid = HostAppProbe.getInt32(state, key), pid > 0 { return pid }
        }
        return intIvar(state) { $0.contains("pid") || $0.contains("processid") }
    }

    private static func hostPIDs(of controller: UIInputViewController) -> [Int32] {
        var result: [Int32] = []
        let owners: [NSObject] = [controller.parent, controller].compactMap { $0 }
        for owner in owners {
            for key in ["_hostPID", "_hostProcessIdentifier", "hostPID", "_hostPid"] {
                if let pid = HostAppProbe.getInt32(owner, key), pid > 0 { result.append(pid) }
            }
            if let pid = intIvar(owner, where: { $0 == "_hostprocessidentifier" || $0 == "_hostpid" }), pid > 0 {
                result.append(pid)
            }
        }
        return result
    }

    private static func objectIvar(_ object: NSObject, _ name: String) -> NSObject? {
        guard let ivar = class_getInstanceVariable(type(of: object), name),
              let rawType = ivar_getTypeEncoding(ivar), String(cString: rawType).hasPrefix("@") else { return nil }
        return object_getIvar(object, ivar) as? NSObject
    }

    private static func stringIvar(_ object: NSObject, _ name: String) -> String? {
        guard let ivar = class_getInstanceVariable(type(of: object), name),
              let rawType = ivar_getTypeEncoding(ivar), String(cString: rawType).hasPrefix("@") else { return nil }
        return object_getIvar(object, ivar) as? String
    }

    /// First 32-bit integer ivar whose lowercased name matches.
    private static func intIvar(_ object: NSObject, where matches: (String) -> Bool) -> Int32? {
        var cls: AnyClass? = type(of: object)
        while let current = cls, current != NSObject.self {
            var count: UInt32 = 0
            if let ivars = class_copyIvarList(current, &count) {
                defer { free(ivars) }
                for index in 0..<Int(count) {
                    let ivar = ivars[index]
                    guard let rawName = ivar_getName(ivar), let rawType = ivar_getTypeEncoding(ivar) else { continue }
                    let encoding = String(cString: rawType)
                    guard encoding == "i" || encoding == "I", matches(String(cString: rawName).lowercased()) else { continue }
                    let base = Unmanaged.passUnretained(object).toOpaque()
                    return base.advanced(by: ivar_getOffset(ivar)).load(as: Int32.self)
                }
            }
            cls = class_getSuperclass(current)
        }
        return nil
    }
}
