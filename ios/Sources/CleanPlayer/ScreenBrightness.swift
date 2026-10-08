import UIKit

/// The screen brightness a player borrowed, and giving it back.
///
/// Every player here offers the same vertical swipe on the left-hand side, and
/// one of them used to keep what it took: a swipe down during a dark scene left
/// the phone dim for everything the user did afterwards, with no hint of why.
/// The rule lived inside one view as three `@State` variables, so the second
/// player could not have followed it even by accident.
///
/// Static, because only one player is on screen at a time — a second one
/// opening over the first inherits the first's entry value, which is the
/// brightness the user actually had before any of this started, and that is
/// the right thing to restore to.
@MainActor
public enum ScreenBrightness {
    /// The screen itself, or a pair of boxes in a test. Injected for the usual
    /// reason: the rule below has a branch in it, and `UIScreen.main` in a test
    /// process is a real device setting whose writes may or may not land.
    public static var read: () -> CGFloat = { UIScreen.main.brightness }
    public static var write: (CGFloat) -> Void = { UIScreen.main.brightness = $0 }

    /// What the screen was before a player first touched it.
    private static var entry: CGFloat?
    /// The last value set through here, so an app-made change can be told from
    /// one the user made in Control Centre.
    private static var lastSet: CGFloat?

    public static var current: CGFloat { read() }

    public static func set(_ value: CGFloat) {
        if entry == nil { entry = read() }
        let clamped = min(max(value, 0), 1)
        write(clamped)
        lastSet = clamped
    }

    /// Put it back, unless the user has moved it since — overriding a change
    /// they made in Control Centre is the same rudeness in the other direction.
    /// A no-op for a player that never touched the brightness at all. Returns
    /// whether it restored, which is the only part worth asserting.
    @discardableResult
    public static func restore() -> Bool {
        let wanted = entry
        let mine = lastSet
        entry = nil
        lastSet = nil
        guard let wanted, let mine, abs(read() - mine) < 0.01 else { return false }
        write(wanted)
        return true
    }
}
