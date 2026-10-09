import SwiftUI
import UXReviewKit

/// The format hint for note fields: the label names the content, and the format is in the
/// tooltip (`HS2-FDG3D9`).
let markdownHelp = "Markdown: **bold**, _italic_, `code`, lists, and links are kept in the ticket."

/// The note about the capture on the canvas as a whole (`HS2-KVDDFH`, docs/06 §6.5.2), at the
/// top of the inspector's list page.
struct CaptureNoteField: View {
    @ObservedObject var model: EditorModel
    let mediaId: String

    var body: some View {
        let note = model.editor.media(mediaId)?.note ?? ""
        VStack(alignment: .leading, spacing: 4) {
            Text("Capture note").font(.caption).foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                // Reads the model on every get, like the annotation note (`HS2-XCJPTX`).
                TextEditor(text: Binding(
                    get: { [mediaId] in model.editor.media(mediaId)?.note ?? "" },
                    set: { text in model.mutate { _ = $0.setMediaNote(text, for: mediaId) } }
                ))
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(4)
                .accessibilityLabel("Capture note")
                .help(markdownHelp)
                if note.isEmpty {
                    Text("Anything about this whole capture?")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 72)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
        }
    }
}
