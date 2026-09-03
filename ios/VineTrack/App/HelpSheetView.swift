import SwiftUI

/// A single page of a paged help sheet.
///
/// Every field except `title` and `body` is optional so new pages can be added
/// without touching the sheet layout: image-led pages, plain text pages, or
/// text plus a smaller supporting line all render from the same model.
struct HelpPage: Identifiable {
    let id: String
    /// Asset-catalogue image name shown above the title. `nil` renders a
    /// text-only page.
    let imageName: String?
    let title: String
    let message: String
    /// Optional smaller line under the body for a secondary hint.
    let supporting: String?

    init(
        id: String,
        imageName: String? = nil,
        title: String,
        message: String,
        supporting: String? = nil
    ) {
        self.id = id
        self.imageName = imageName
        self.title = title
        self.message = message
        self.supporting = supporting
    }
}

/// Reusable swipeable help sheet.
///
/// Pages are data-driven — appending to the `pages` array is the only change
/// needed to add a fourth or fifth page. Content scrolls per page so long text
/// never clips on small phones, and the paging dots sit below the content.
struct HelpSheetView: View {
    let navigationTitle: String
    let pages: [HelpPage]

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int = 0

    var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    HelpPageView(page: page)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: pages.count > 1 ? .always : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

/// One rendered help page: optional image, heading, body and supporting line.
private struct HelpPageView: View {
    let page: HelpPage

    /// Cropped image height. The supplied art is portrait, so a full-height
    /// aspect fit would push the heading off screen — the image is filled into
    /// a fixed-height frame instead (cropped, never stretched).
    private let imageHeight: CGFloat = 210

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let imageName = page.imageName {
                    Color(.secondarySystemBackground)
                        .frame(height: imageHeight)
                        .overlay {
                            Image(imageName)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .allowsHitTesting(false)
                        }
                        .clipShape(.rect(cornerRadius: 14))
                        .frame(maxWidth: .infinity)
                }

                Text(page.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(page.message)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let supporting = page.supporting {
                    Text(supporting)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            // Clearance for the paging dots.
            .padding(.bottom, 56)
        }
    }
}

/// Copy for the Quick Actions help sheet shown from the dashboard heading.
/// Mirrored on Android in `QuickActionsHelp.kt`.
enum QuickActionsHelp {
    static let navigationTitle: String = "How to Use"

    static let pages: [HelpPage] = [
        HelpPage(
            id: "vineyard",
            imageName: "quick-actions-help",
            title: "Built to work where you work",
            message: """
            Quick Actions are designed for use while you are moving through the vineyard.

            When you see something that needs attention, use the Repairs or Growth buttons to mark it immediately — without stopping to work out the block, row or exact position yourself.
            """
        ),
        HelpPage(
            id: "drop",
            title: "See it. Mark it. Keep moving.",
            message: """
            Choose the Quick Action that best describes what you have found.

            Repairs and Growth actions can be customised for the jobs and observations that matter in your vineyard.

            Tap the relevant button and VineTrack records the issue at your current position.
            """,
            supporting: "Add a photo or notes when you need more detail."
        ),
        HelpPage(
            id: "placement",
            title: "Find it again easily",
            message: """
            VineTrack uses your location, the vineyard map and your direction of travel to work out where the pin belongs.

            It records the block, row, side and direction so the issue can be found again with much more precision than a normal map marker.
            """,
            supporting: "Later, open the pin to see the exact details and navigate back to it."
        ),
    ]
}
