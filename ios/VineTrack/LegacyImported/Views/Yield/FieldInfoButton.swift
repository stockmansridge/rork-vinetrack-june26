import SwiftUI

/// Small, unobtrusive inline help affordance: an info glyph that shows a
/// short explanation in a native popover (arrow-anchored on iPhone too).
struct FieldInfoButton: View {
    let title: String
    let message: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(maxWidth: 300, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel("\(title) help")
    }
}
