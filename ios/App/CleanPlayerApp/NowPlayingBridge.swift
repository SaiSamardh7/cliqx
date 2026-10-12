import CleanPlayer
import Foundation

/// Binds a player to the system's Now Playing card.
///
/// Two of the three players drive a `PageState`, so they share the whole
/// binding; the local file player has its own fields and supplies a snapshot
/// itself. This file is the untestable half on purpose — the app target has
/// no unit tests, so everything with a decision in it lives in `NowPlaying`
/// in the package, and what is left here is assignment.
@MainActor
extension NowPlayingController {

    /// Remote buttons wired to the chrome's own actions, so a lock-screen
    /// press goes down exactly the path an on-screen press does.
    ///
    /// `play` and `pause` are separate commands but the players expose one
    /// toggle, so each checks the state first. Sending a bare toggle for
    /// `play` would pause a video that a car stereo had just been asked to
    /// resume, which is how a head unit and an app end up disagreeing about
    /// what is happening.
    func begin(driving page: PageState) {
        begin(Commands(
            play: { if !page.isPlaying { page.actions.togglePlay() } },
            pause: { if page.isPlaying { page.actions.togglePlay() } },
            toggle: { page.actions.togglePlay() },
            seek: { page.actions.seek($0) },
            skip: { page.actions.skip($0) }))
    }

    /// The card, from whatever the chrome is already showing.
    ///
    /// `page.title` is what the player itself decided to display, which for a
    /// server episode is "Series — Episode" rather than the bare item name.
    /// Reading it here rather than taking a title parameter means the lock
    /// screen cannot say something different from the player.
    func update(from page: PageState) {
        update(NowPlayingSnapshot(
            title: page.title,
            isPlaying: page.isPlaying,
            currentTime: page.currentTime,
            duration: page.duration,
            rate: page.playbackRate,
            isLive: page.isLive))
    }
}
