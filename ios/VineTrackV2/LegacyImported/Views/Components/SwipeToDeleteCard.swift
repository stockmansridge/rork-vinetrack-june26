import SwiftUI

/// A reusable swipe-to-reveal-delete container for use inside ScrollView/VStack
/// contexts where SwiftUI's built-in `.swipeActions` (List-only) does not apply.
///
/// Swipe the row left to reveal a destructive action button. Tapping the
/// revealed button triggers `onDelete`. Tapping the row content or scrolling
/// resets the offset.
struct SwipeToDeleteCard<Content: View>: View {
    let actionLabel: String
    let systemImage: String
    let isEnabled: Bool
    let onDelete: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var committed: CGFloat = 0

    private let revealWidth: CGFloat = 84
    private let actionThreshold: CGFloat = 56

    init(
        actionLabel: String = "Delete",
        systemImage: String = "trash",
        isEnabled: Bool = true,
        onDelete: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.actionLabel = actionLabel
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.onDelete = onDelete
        self.content = content
    }

    var body: some View {
        if !isEnabled {
            content()
        } else {
            ZStack(alignment: .trailing) {
                content()
                    .background(Color(.systemBackground))
                    .offset(x: min(0, offset))
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 12, coordinateSpace: .local)
                            .onChanged { value in
                                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                                let proposed = committed + value.translation.width
                                offset = max(-revealWidth - 20, min(0, proposed))
                            }
                            .onEnded { value in
                                let final = committed + value.translation.width
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    if final < -actionThreshold {
                                        offset = -revealWidth
                                        committed = -revealWidth
                                    } else {
                                        offset = 0
                                        committed = 0
                                    }
                                }
                            }
                    )
                    .overlay {
                        if committed != 0 {
                            // Tap on the non-revealed (left) area closes the swipe.
                            // We render the Delete button on top of the right side, so
                            // taps there hit the button instead of this overlay.
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                        offset = 0
                                        committed = 0
                                    }
                                }
                                .padding(.trailing, revealWidth)
                        }
                    }

                // Delete button rendered ON TOP so it actually receives taps in
                // the revealed area (the underlying content's .offset does NOT
                // move its hit-test frame, so without this the row's tap/
                // NavigationLink would intercept the tap and open the detail).
                Button {
                    onDelete()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        offset = 0
                        committed = 0
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: systemImage)
                            .font(.subheadline.weight(.semibold))
                        Text(actionLabel)
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(width: revealWidth)
                    .frame(maxHeight: .infinity)
                    .background(Color.red)
                    .clipShape(.rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .opacity(offset < -8 ? 1 : 0)
                .allowsHitTesting(committed <= -actionThreshold)
            }
        }
    }
}
