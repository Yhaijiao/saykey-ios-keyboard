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
