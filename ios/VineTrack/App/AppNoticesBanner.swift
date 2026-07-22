import SwiftUI

/// Dismissible, swipable banner shown on the Home screen for currently
/// active, non-dismissed app-wide notices. Multiple notices are paged
/// horizontally. The banner measures its tallest notice card and sizes
/// the underlying `TabView` to fit so long, wrapped messages aren't
/// clipped (the page style of `TabView` does not self-size).
struct AppNoticesBanner: View {
    @Environment(AppNoticeService.self) private var service
    @State private var selection: UUID?
    @State private var measuredHeight: CGFloat = 0

    var body: some View {
        let visible = service.visibleNotices
        if visible.isEmpty {
            EmptyView()
        } else if visible.count == 1, let only = visible.first {
            // Single notice: skip the carousel entirely so the card can
            // grow naturally with its content.
            NoticeBannerCard(notice: only) {
                dismiss(only.id, visible: visible)
            }
            .padding(.horizontal)
            .animation(.easeInOut(duration: 0.18), value: visible.map(\.id))
        } else {
            VStack(spacing: 6) {
                TabView(selection: $selection) {
                    ForEach(visible) { notice in
                        NoticeBannerCard(notice: notice) {
                            dismiss(notice.id, visible: visible)
                        }
                        .padding(.horizontal)
                        .tag(Optional(notice.id))
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .never))
                // Add space for the page dots beneath the tallest card.
                .frame(height: max(measuredHeight, 60) + 24)
            }
            // Measure the tallest notice off-screen (outside the TabView,
            // which would otherwise clip the measurement to its own bounded
            // height — a circular dependency). Use the same horizontal
            // padding so wrapping matches the visible card.
            .background(
                VStack(spacing: 0) {
                    ForEach(visible) { notice in
                        NoticeBannerCard(notice: notice, onDismiss: {})
                            .padding(.horizontal)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: NoticeHeightKey.self,
                                        value: proxy.size.height
                                    )
                                }
                            )
                    }
                }
                .hidden()
                .accessibilityHidden(true)
            )
            .onPreferenceChange(NoticeHeightKey.self) { newValue in
                if abs(newValue - measuredHeight) > 0.5 {
                    measuredHeight = newValue
                }
            }
            .animation(.easeInOut(duration: 0.18), value: measuredHeight)
            .animation(.easeInOut(duration: 0.18), value: visible.map(\.id))
            .onAppear { ensureSelection(visible: visible) }
            .onChange(of: visible.map(\.id)) { _, _ in
                // Reset measurement so a freshly-visible (possibly taller)
                // notice can grow the container.
                measuredHeight = 0
                ensureSelection(visible: visible)
            }
        }
    }

    private func ensureSelection(visible: [BackendAppNotice]) {
        if let current = selection, visible.contains(where: { $0.id == current }) { return }
        selection = visible.first?.id
    }

    private func dismiss(_ id: UUID, visible: [BackendAppNotice]) {
        if let idx = visible.firstIndex(where: { $0.id == id }) {
            let next = visible.indices.contains(idx + 1) ? visible[idx + 1].id : visible.first(where: { $0.id != id })?.id
            selection = next
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            service.dismiss(id)
        }
    }
}

private struct NoticeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct NoticeBannerCard: View {
    let notice: BackendAppNotice
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(0.18))
                    .frame(width: 30, height: 30)
                Image(systemName: iconName)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(notice.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(Color(.tertiarySystemFill), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss notice")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.28), lineWidth: 1)
        )
    }

    private var tint: Color {
        switch notice.typedNoticeType {
        case .info: return .blue
        case .warning: return .orange
        case .success: return .green
        case .critical: return .red
        }
    }

    private var iconName: String {
        switch notice.typedNoticeType {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .success: return "checkmark.seal.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }
}
