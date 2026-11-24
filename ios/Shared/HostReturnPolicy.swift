import Foundation

/// Decides which app Lab returns to after the keyboard sent the user there.
///
/// Lab learns the app the keyboard is used in from system keyboard state
/// events. While Lab is suspended it receives none, so right after it comes
/// to the foreground the newest value it holds can still be the app of an
/// earlier visit. Returning on that value sends the user to the wrong app,
/// so an old value is only used when it is known to be current.
enum HostReturnPolicy {
    enum Decision: Equatable {
        case open(String)
        /// The event for this visit may still be on its way.
        case wait
        /// Nothing trustworthy: leave the user in Lab with the "◀" hint.
        case unknown
    }

    /// An event this close before the request belongs to the same tap.
    static let freshMargin: TimeInterval = 3
    /// How long to wait for this visit's event before judging older values.
    static let settleTime: TimeInterval = 0.8
    /// Events this soon after Lab left the foreground are the tail of that
    /// visit (the keyboard reappearing in the app Lab returned to).
    static let backgroundTail: TimeInterval = 2

    /// - Parameters:
    ///   - reported: the host named by the keyboard itself, when iOS allows.
    ///   - current: the host in the system's keyboard state right now.
    ///   - observed: the last host event Lab received, with its time.
    ///   - requestedAt: when the keyboard's request reached Lab.
    ///   - backgroundedAt: when Lab last left the foreground.
    static func decide(reported: String?, current: String?, observed: (id: String, at: Date)?,
                       requestedAt: Date, backgroundedAt: Date?, now: Date) -> Decision {
        if let reported { return .open(reported) }
        if let observed, observed.at >= requestedAt.addingTimeInterval(-freshMargin) { return .open(observed.id) }
        // On a cold launch Lab has never been backgrounded, so there is no
        // earlier visit whose host could be stale.
        if backgroundedAt == nil, let host = current ?? observed?.id { return .open(host) }
        // The state changed without an event reaching us: that is news too.
        if let current, current != observed?.id { return .open(current) }
        guard now.timeIntervalSince(requestedAt) >= settleTime else { return .wait }
        // An old value is still right when Lab kept receiving events in the
        // background (voice session running): it then names the last app the
        // keyboard appeared in.
        if let observed, let backgroundedAt,
           observed.at > backgroundedAt.addingTimeInterval(backgroundTail) { return .open(observed.id) }
        // After waiting `settleTime` for any new host event, if the system's
        // live keyboard state still reports a host (e.g. returning to the same
        // app such as Notes/WeChat again after Lab was suspended), use it.
        if let current { return .open(current) }
        return .unknown
    }
}

/// Normalizes host app identifiers extracted from UIKit, RemoteTextInput,
/// FrontBoard scene identities, and process names across iOS versions.
enum HostBundleID {
    static let ignoredHosts: Set<String> = [
        "com.apple.ScreenshotServicesService",
        "com.apple.springboard",
        "com.apple.Spotlight",
        "com.apple.InputUI",
        "com.apple.TextInput.kbd",
        "com.apple.keyboard",
        "com.apple.UIKit.KeyboardManagement.hosted"
    ]

    /// Executable binary name → bundle ID, for process-handle / PID lookups.
    static let executables: [String: String] = [
        "MobileNotes": "com.apple.mobilenotes",
        "MobileSMS": "com.apple.MobileSMS",
        "MobileMail": "com.apple.mobilemail",
        "MobileSafari": "com.apple.mobilesafari",
        "Reminders": "com.apple.reminders",
        "WeChat": "com.tencent.xin",
        "QQ": "com.tencent.mqq",
        "wework": "com.tencent.WeWork",
        "Claude": "com.anthropic.claude",
        "ChatGPT": "com.openai.chat",
        "Gmail": "com.google.Gmail",
        "Chrome": "com.google.chrome.ios",
        "WhatsApp": "net.whatsapp.WhatsApp",
        "Telegram": "ph.telegra.Telegraph",
        "Messenger": "com.facebook.Messenger",
        "Instagram": "com.burbn.instagram",
        "Tweetie2": "com.atebits.Tweetie2",
        "Slack": "com.tinyspeck.chatlyio",
        "Notion": "notion.id",
        "discover": "com.xingin.discover",
        "Aweme": "com.ss.iphone.ugc.Aweme",
        "Weibo": "com.sina.weibo",
        "AlipayWallet": "com.alipay.iphoneclient",
        "Outlook": "com.microsoft.Office.Outlook",
        "LinkedIn": "com.linkedin.LinkedIn",
        "Discord": "com.hammerandchisel.discord",
        "Lark": "com.larksuite.suite",
        "Feishu": "com.ss.iphone.lark",
        "DingTalk": "com.laiwang.DingTalk"
    ]

    /// Localized or English app display name → bundle ID, for `RTIDocumentTraits.appName`.
    static let appNames: [String: String] = [
        "notes": "com.apple.mobilenotes",
        "备忘录": "com.apple.mobilenotes",
        "備忘錄": "com.apple.mobilenotes",
        "wechat": "com.tencent.xin",
        "weixin": "com.tencent.xin",
        "微信": "com.tencent.xin",
        "messages": "com.apple.MobileSMS",
        "信息": "com.apple.MobileSMS",
        "訊息": "com.apple.MobileSMS",
        "mail": "com.apple.mobilemail",
        "邮件": "com.apple.mobilemail",
        "reminders": "com.apple.reminders",
        "提醒事项": "com.apple.reminders",
        "safari": "com.apple.mobilesafari",
        "claude": "com.anthropic.claude",
        "chatgpt": "com.openai.chat",
        "qq": "com.tencent.mqq",
        "wecom": "com.tencent.WeWork",
        "企业微信": "com.tencent.WeWork",
        "gmail": "com.google.Gmail",
        "chrome": "com.google.chrome.ios",
        "whatsapp": "net.whatsapp.WhatsApp",
        "telegram": "ph.telegra.Telegraph",
        "messenger": "com.facebook.Messenger",
        "instagram": "com.burbn.instagram",
        "slack": "com.tinyspeck.chatlyio",
        "notion": "notion.id",
        "小红书": "com.xingin.discover",
        "rednote": "com.xingin.discover",
        "抖音": "com.ss.iphone.ugc.Aweme",
        "微博": "com.sina.weibo",
        "weibo": "com.sina.weibo",
        "支付宝": "com.alipay.iphoneclient",
        "alipay": "com.alipay.iphoneclient",
        "outlook": "com.microsoft.Office.Outlook",
        "linkedin": "com.linkedin.LinkedIn",
        "领英": "com.linkedin.LinkedIn",
        "discord": "com.hammerandchisel.discord",
        "飞书": "com.ss.iphone.lark",
        "feishu": "com.ss.iphone.lark",
        "lark": "com.larksuite.suite",
        "钉钉": "com.laiwang.DingTalk",
        "dingtalk": "com.laiwang.DingTalk"
    ]

    static let knownBundleIDs: Set<String> = Set(executables.values).union(appNames.values)

    static func isOwnOrSystemOverlay(_ bundleID: String) -> Bool {
        bundleID.hasPrefix("org.capswriterlab") || ignoredHosts.contains(bundleID)
    }

    /// Parses a plain bundle ID, an entitlement `appId` (`TEAMID1234.com.foo.bar`),
    /// or a FrontBoard `sceneID` (`sceneID:com.apple.mobilenotes-default`).
    static func normalize(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text != "<null>", text.count <= 300 else { return nil }
        if text.contains("%"), let decoded = text.removingPercentEncoding {
            text = decoded
        }
        if let sceneRange = text.range(of: "sceneID:") {
            let after = String(text[sceneRange.upperBound...])
            if let extracted = extractFromSceneSuffix(after) { return extracted }
        }
        if let stripped = stripTeamPrefix(text), let valid = validatePlain(stripped) {
            return valid
        }
        return validatePlain(text)
    }

    static func fromAppName(_ raw: String?) -> String? {
        guard let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !key.isEmpty else { return nil }
        return appNames[key]
    }

    private static func extractFromSceneSuffix(_ suffix: String) -> String? {
        let token = String(suffix.prefix { $0 != " " && $0 != ";" && $0 != ">" && $0 != "\"" })
        for known in knownBundleIDs where token == known || token.hasPrefix(known + "-") {
            return isOwnOrSystemOverlay(known) ? nil : known
        }
        guard let lastDot = token.lastIndex(of: ".") else { return nil }
        let tail = token[lastDot...]
        if let dash = tail.firstIndex(of: "-") {
            return validatePlain(String(token[..<dash]))
        }
        return validatePlain(token)
    }

    private static func stripTeamPrefix(_ text: String) -> String? {
        guard let dot = text.firstIndex(of: ".") else { return nil }
        let prefix = text[..<dot]
        let rest = String(text[text.index(after: dot)...])
        guard prefix.count == 10, rest.contains("."),
              prefix.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { return nil }
        return rest
    }

    private static func validatePlain(_ text: String) -> String? {
        guard !text.isEmpty, text.count <= 200, text.contains("."),
              !text.hasPrefix("."), !text.hasSuffix("."),
              !isOwnOrSystemOverlay(text),
              text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" })
        else { return nil }
        return text
    }
}
