import XCTest
@testable import CleanPlayer

/// The pure parts of the playback boundary. The engines themselves need a real
/// video and a real web view; these cover the shared behaviour that a source
/// gets for free and would otherwise be reimplemented — differently — in each.
@MainActor
final class PlaybackTests: XCTestCase {

    /// Stands in for a real engine: records what the chrome asked for, and
    /// nothing else. Notably it does NOT implement `skip`, so these tests
    /// exercise the default implementation every source inherits.
    private final class RecordingSource: PlaybackSource {
        let state = PlaybackState()
        private(set) var seeks: [Double] = []
        private(set) var closed = false

        func togglePlay() { state.isPlaying.toggle() }
        func seek(to seconds: Double) {
            seeks.append(seconds)
            state.currentTime = seconds
        }
        func setRate(_ rate: Double) { state.rate = rate }
        func close() { closed = true }
    }

    private final class Queue: PlaylistSource {
        var items: [PlaylistItem] = []
        var nextItem: PlaylistItem.ID?
        var previousItem: PlaylistItem.ID?
        private(set) var loaded = false
        private(set) var went: [PlaylistItem.ID] = []

        func loadItems() { loaded = true }
        func go(to id: PlaylistItem.ID) { went.append(id) }
    }

    // MARK: Skip

    func testSkipIsSeekRelativeToWhereWeAre() {
        let source = RecordingSource()
        source.state.duration = 100
        source.state.currentTime = 30

        source.skip(by: 10)
        XCTAssertEqual(source.seeks, [40])
    }

    /// Skipping back past the start is the ordinary case at the beginning of a
    /// video, not an error — it goes to 0.
    func testSkippingBackPastTheStartClampsToZero() {
        let source = RecordingSource()
        source.state.duration = 100
        source.state.currentTime = 4

        source.skip(by: -10)
        XCTAssertEqual(source.seeks, [0])
    }

    // MARK: Optional capability defaults

    /// A source that cannot do subtitles, PiP, AirPlay or fit must still
    /// satisfy the protocol without writing five empty methods — and calling
    /// one must not trap.
    func testUnsupportedCapabilitiesAreSilentRatherThanFatal() {
        let source = RecordingSource()
        source.selectSubtitleTrack(2)
        source.selectVariant(1)
        source.setFit(.cover)
        source.togglePictureInPicture()
        source.showAirPlayPicker()
        source.beginScrub()

        // The point is that none of that changed anything or crashed.
        XCTAssertTrue(source.seeks.isEmpty)
        XCTAssertEqual(source.state.fit, .contain)
        XCTAssertFalse(source.state.canPictureInPicture)
    }

    // MARK: State

    func testQualityLabelWaitsForMetadata() {
        let state = PlaybackState()
        XCTAssertEqual(state.qualityLabel, "--")
        state.videoHeight = 1080
        XCTAssertEqual(state.qualityLabel, "1080p")
    }

    func testActiveSubtitleTrackIsTheSelectedOne() {
        let state = PlaybackState()
        state.subtitleTracks = [
            MediaTrack(id: 0, label: "English", isActive: false),
            MediaTrack(id: 1, label: "Español", isActive: true),
        ]
        XCTAssertEqual(state.activeSubtitleTrack?.label, "Español")
    }

    /// Every field, not just the obvious ones. A duration or a track list
    /// surviving into the next item renders as real in the chrome.
    func testResetLeavesNothingFromThePreviousItem() {
        let state = PlaybackState()
        state.isPlaying = true
        state.currentTime = 50
        state.duration = 100
        state.isLive = true
        state.bufferedTo = 80
        state.rate = 1.5
        state.hasEnded = true
        state.title = "Previous"
        state.subtitleTracks = [MediaTrack(id: 0, label: "en", isActive: true)]
        state.variants = [MediaTrack(id: 0, label: "720p", isActive: true)]
        state.videoHeight = 720
        state.fit = .cover
        state.canPictureInPicture = true
        state.canAirPlay = true

        state.reset()

        XCTAssertFalse(state.isPlaying)
        XCTAssertEqual(state.currentTime, 0)
        XCTAssertEqual(state.duration, 0)
        XCTAssertFalse(state.isLive)
        XCTAssertEqual(state.bufferedTo, 0)
        XCTAssertEqual(state.rate, 1)
        XCTAssertFalse(state.hasEnded)
        XCTAssertEqual(state.title, "")
        XCTAssertTrue(state.subtitleTracks.isEmpty)
        XCTAssertTrue(state.variants.isEmpty)
        XCTAssertEqual(state.videoHeight, 0)
        XCTAssertEqual(state.fit, .contain)
        XCTAssertFalse(state.canPictureInPicture)
        XCTAssertFalse(state.canAirPlay)
    }

    func testFitToggleOnlyEverHasTwoStates() {
        XCTAssertEqual(VideoFit.contain.toggled, .cover)
        XCTAssertEqual(VideoFit.cover.toggled, .contain)
        XCTAssertEqual(VideoFit.allCases.count, 2)
    }

    // MARK: Playlist

    func testNeighboursDriveTheEpisodeButtons() {
        let queue = Queue()
        XCTAssertFalse(queue.hasNext)
        XCTAssertFalse(queue.hasPrevious)

        queue.nextItem = "ep-3"
        queue.previousItem = "ep-1"
        XCTAssertTrue(queue.hasNext)
        XCTAssertTrue(queue.hasPrevious)

        queue.goToNext()
        queue.goToPrevious()
        XCTAssertEqual(queue.went, ["ep-3", "ep-1"])
    }

    /// A missing neighbour is the end of the list, not a reason to navigate
    /// somewhere arbitrary.
    func testGoingNextWithNoNextDoesNothing() {
        let queue = Queue()
        queue.goToNext()
        queue.goToPrevious()
        XCTAssertTrue(queue.went.isEmpty)
    }
}
