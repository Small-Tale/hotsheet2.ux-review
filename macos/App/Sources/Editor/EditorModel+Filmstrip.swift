import CoreGraphics
import Foundation
import UXReviewKit

/// What a filmstrip shows: one movie, its clip, and how many frames (`HS2-VMKTHQ`).
struct FilmstripKey: Equatable, Sendable {
    var url: URL
    var offsetMs: Int
    var durationMs: Int
    var count: Int
}

/// The video timeline's filmstrip frames, read off the main thread (docs/06 §6.10).
extension EditorModel {
    static let filmstripPixelHeight = 88

    /// The key for `count` frames of the current video, or nil for an image.
    func filmstripKey(count: Int) -> FilmstripKey? {
        guard let id = editor.currentMediaId, let source = session.movieSource(id) else { return nil }
        return FilmstripKey(url: source.url, offsetMs: source.offsetMs, durationMs: source.durationMs, count: count)
    }

    /// Reads the frames for `count` slots in the background unless they are already there. A
    /// newer request (another capture, a trim, a resize) replaces an older one.
    func requestFilmstrip(count: Int) {
        guard let key = filmstripKey(count: count), filmstrip?.key != key else { return }
        filmstripTask?.cancel()
        let maxHeight = Self.filmstripPixelHeight
        filmstripTask = Task { [weak self] in
            let frames = await Task.detached(priority: .utility) {
                Filmstrip.frames(
                    url: key.url, offsetMs: key.offsetMs, times: Filmstrip.times(durationMs: key.durationMs, count: key.count),
                    maxHeight: maxHeight
                )
            }.value
            guard !Task.isCancelled, let self, self.filmstripKey(count: count) == key else { return }
            self.filmstrip = (key, frames)
        }
    }

    /// Reads them now, on this thread (previews draw the timeline in one pass).
    func loadFilmstripNow(count: Int) {
        guard let key = filmstripKey(count: count) else { return }
        let times = Filmstrip.times(durationMs: key.durationMs, count: count)
        filmstrip = (key, Filmstrip.frames(url: key.url, offsetMs: key.offsetMs, times: times, maxHeight: Self.filmstripPixelHeight))
    }
}
