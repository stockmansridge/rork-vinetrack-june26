import SwiftUI

/// A short explanation behind the app's info affordance.
///
/// # Why this is a sheet on iPhone
///
/// It was a popover forced into compact width with
/// `.presentationCompactAdaptation(.popover)`. On a phone that renders a small
/// fixed-width bubble, and anything longer than a line or two was clipped — the
/// spray-volume-basis explanation lost most of its text, and larger Dynamic
/// Type sizes truncated even the short ones. Help that cannot be read is worse
/// than no help: the operator has already spent the tap.
///
/// So compact width gets a native sheet — full title, wrapped body, scrollable
/// when it needs to be, dismissible like every other sheet. Regular width
/// (iPad) keeps a popover, where there is genuinely room for one.
struct SprayFieldHelp: View {
    let title: String
    let message: String
    /// An optional bundled diagram shown above the text — the UCR model, for
    /// the canopy-size control.
    var imageName: String?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isPresented: Bool = false

    init(title: String, message: String, imageName: String? = nil) {
        self.title = title
        self.message = message
        self.imageName = imageName
    }

    private var isCompact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About \(title)")
        .sheet(isPresented: $isPresented) {
            if isCompact {
                compactSheet
            } else {
                regularPopoverBody
            }
        }
    }

    /// iPhone. A real sheet, so the text has the width of the screen and can
    /// scroll rather than being cut off.
    private var compactSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    diagram
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isPresented = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        // Without this a drag inside the scroll view resizes the sheet instead
        // of scrolling the text it was trying to read.
        .presentationContentInteraction(.scrolls)
    }

    /// iPad, where a popover genuinely fits.
    private var regularPopoverBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)
                diagram
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 360, minHeight: 260)
        .presentationCompactAdaptation(.popover)
    }

    @ViewBuilder
    private var diagram: some View {
        if let imageName, UIImage(named: imageName) != nil {
            Image(imageName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 160)
                .padding(8)
                .background(Color.white)
                .clipShape(.rect(cornerRadius: 8))
        }
    }
}

/// A field label with its help affordance.
private struct SprayFieldLabel: View {
    let text: String
    let help: String

    var body: some View {
        HStack(spacing: 0) {
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            SprayFieldHelp(title: text, message: help)
            Spacer(minLength: 0)
        }
    }
}

/// The canopy model's operator-facing controls — training system, size,
/// density, and the reference imagery that makes the choice meaningful standing
/// in a row.
///
/// # Why this is one component and not two copies
///
/// Both carrier workflows are driven by the SAME canopy table. An L/ha vineyard
/// turns the canopy's litres-per-100 m into a dilute L/ha through row spacing;
/// an L/100 m vineyard uses that figure directly. When each screen carried its
/// own copy of these pickers, only one of them actually existed — the L/100 m
/// path had no canopy at all — and the two could never be compared, because
/// there was nothing on the row-length side to compare against.
///
/// # Why the training system is asked first
///
/// Every control here used to be headed "VSP Canopy Size", and the table behind
/// it is the VSP table. VSP was therefore the answer to a question nobody was
/// asked. It stops being safe to assume the moment a second system exists: at
/// the wires-up sizes a sprawl canopy needs materially more water than a VSP
/// one, so assuming VSP would under-water a sprawl block and under-dose every
/// per-100 L product measured against it.
struct SprayCanopyControls: View {
    @Binding var selection: SprayCanopySelection

    private var typeBinding: Binding<CanopyType?> {
        Binding(
            get: { selection.type },
            set: { if let value = $0 { selection.choose(type: value) } }
        )
    }

    private var sizeBinding: Binding<CanopySize> {
        Binding(
            get: { selection.size },
            set: { selection.choose(size: $0) }
        )
    }

    private var densityBinding: Binding<CanopyDensity> {
        Binding(
            get: { selection.density },
            set: { selection.choose(density: $0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            canopyTypeSection

            if let type = selection.type {
                canopySizeSection(type: type)
                canopyDensitySection
                if !selection.isSizeAndDensityConfirmed {
                    confirmPrompt
                }
            }
        }
    }

    // MARK: - 1. Canopy type

    private var canopyTypeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SprayFieldLabel(text: "Canopy Type", help: CanopyType.vsp.help)
            Picker("Canopy Type", selection: typeBinding) {
                // A `nil` tag keeps the picker genuinely unselected until the
                // operator chooses. A segmented control always highlights
                // something, which is exactly how VSP became an unasked
                // question in the first place.
                Text("Select").tag(CanopyType?.none)
                ForEach(CanopyType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(CanopyType?.some(type))
                }
            }
            .pickerStyle(.segmented)
            if selection.type == nil {
                Text("Choose the training system for this block before the canopy "
                     + "can recommend a spray volume.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 2. Canopy size

    private func canopySizeSection(type: CanopyType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Text("Canopy Size")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                // Carries the UCR diagram: the size question is really "which
                // one-metre canopy cross-section matches your block", and the
                // picture explains that far faster than the sentence does.
                SprayFieldHelp(
                    title: "Canopy size",
                    message: SprayVolumeHelp.unitCanopyRow,
                    imageName: SprayVolumeHelp.unitCanopyRowImageName
                )
                Spacer(minLength: 0)
            }
            Picker("Canopy Size", selection: sizeBinding) {
                ForEach(CanopySize.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(selection.size.description(for: type))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            referenceImage(type: type)
        }
    }

    @ViewBuilder
    private func referenceImage(type: CanopyType) -> some View {
        switch selection.size.referenceImage(for: type) {
        case let .remote(url):
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fit)
                case .failure:
                    Image(systemName: "leaf")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                case .empty:
                    ProgressView()
                @unknown default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 120)
            .padding(8)
            .background(Color.white)
            .clipShape(.rect(cornerRadius: 8))
            .opacity(selection.isSizeAndDensityConfirmed ? 1 : 0.55)

        case let .bundled(name):
            // Until the Sprawl artwork is dropped into the asset catalogue this
            // states plainly that there is no picture, rather than showing the
            // VSP one — a VSP photograph standing in for a sprawl canopy would
            // actively mislead the size choice it exists to inform.
            if UIImage(named: name) != nil {
                Image(name)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .padding(8)
                    .background(Color.white)
                    .clipShape(.rect(cornerRadius: 8))
                    .opacity(selection.isSizeAndDensityConfirmed ? 1 : 0.55)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "photo")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text("Sprawl reference image not available")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 80)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 8))
            }

        case .none:
            EmptyView()
        }
    }

    // MARK: - 3. Canopy density

    private var canopyDensitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SprayFieldLabel(text: "Canopy Density", help: CanopyDensity.help)
            Picker("Canopy Density", selection: densityBinding) {
                ForEach(CanopyDensity.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    /// The operator whose canopy really is Medium / Low needs a way to say so
    /// without changing a picker and changing it back.
    private var confirmPrompt: some View {
        Button {
            selection.confirm()
        } label: {
            Text("Confirm \(selection.size.rawValue) · \(selection.density.rawValue)")
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .background(Color.orange.opacity(0.16))
                .foregroundStyle(.orange)
                .clipShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
