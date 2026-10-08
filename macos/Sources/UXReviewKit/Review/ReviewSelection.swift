import Foundation

/// Which captures and annotations go to an existing ticket (docs/07-review-session.md §7.2.2).
/// Everything is included by default; the selection lists what the reviewer left out, so
/// captures and annotations added to the draft later are included. A capture left out takes all
/// its annotations with it; an annotation can also be left out on its own.
public struct ReviewSelection: Codable, Equatable, Sendable {
    /// Media ids left out.
    public var excludedMedia: Set<String>
    /// Annotation ids left out (on captures that are included).
    public var excludedAnnotations: Set<String>

    public init(excludedMedia: Set<String> = [], excludedAnnotations: Set<String> = []) {
        self.excludedMedia = excludedMedia
        self.excludedAnnotations = excludedAnnotations
    }

    /// Nothing left out.
    public var isEverything: Bool { excludedMedia.isEmpty && excludedAnnotations.isEmpty }

    public func includes(media id: String) -> Bool { !excludedMedia.contains(id) }

    public func includes(_ annotation: Annotation) -> Bool {
        includes(media: annotation.mediaId) && !excludedAnnotations.contains(annotation.id)
    }

    /// Includes or leaves out a capture. Including it keeps its annotations' own choices.
    public mutating func set(media id: String, included: Bool) {
        if included { excludedMedia.remove(id) } else { excludedMedia.insert(id) }
    }

    /// Includes or leaves out an annotation. Including one on a capture that is left out includes
    /// the capture too, with only that annotation of its annotations.
    public mutating func set(_ annotation: Annotation, included: Bool, in bundle: ReviewBundle) {
        if included {
            excludedAnnotations.remove(annotation.id)
            if excludedMedia.remove(annotation.mediaId) != nil {
                for other in bundle.annotations where other.mediaId == annotation.mediaId && other.id != annotation.id {
                    excludedAnnotations.insert(other.id)
                }
            }
        } else {
            excludedAnnotations.insert(annotation.id)
        }
    }

    /// `bundle` with only what is included: its captures, and their included annotations, in
    /// review order (so the note numbers them #1… in that order).
    public func apply(to bundle: ReviewBundle) -> ReviewBundle {
        var selected = bundle
        selected.media = bundle.media.filter { includes(media: $0.id) }
        selected.annotations = bundle.annotations.filter(includes)
        return selected
    }

    /// Forgets ids no longer in `bundle` (a capture or annotation removed from the draft).
    public func pruned(to bundle: ReviewBundle) -> ReviewSelection {
        ReviewSelection(
            excludedMedia: excludedMedia.intersection(bundle.media.map(\.id)),
            excludedAnnotations: excludedAnnotations.intersection(bundle.annotations.map(\.id))
        )
    }
}
