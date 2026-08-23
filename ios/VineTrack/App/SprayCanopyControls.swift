import SwiftUI

/// The canopy model's operator-facing controls — VSP canopy size, density, the
/// reference imagery that makes the choice meaningful standing in a row, and
/// the confirmation that turns a default into an answer.
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
/// One component means a grower locked to L/100 m chooses their canopy on
/// exactly the control an L/ha grower uses, and a change to the reference
/// imagery or the size wording reaches both at once.
///
/// # Why it asks to be confirmed
///
/// A segmented picker cannot show "unanswered": it always has a selection, so
/// Medium / Low looked like a decision from the moment the screen opened. The
/// unconfirmed state is drawn explicitly, and confirming is one tap — either by
/// choosing a value or by accepting the ones shown.
struct SprayCanopyControls: View {
    @Binding var selection: SprayCanopySelection

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
        VStack(alignment: .leading, spacing: 12) {
            if !selection.isConfirmed {
                unconfirmedPrompt
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("VSP Canopy Size")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Picker("Canopy Size", selection: sizeBinding) {
                    ForEach(CanopySize.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(selection.size.description)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let imageURL = selection.size.referenceImageURL {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
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
                    // Dimmed while unconfirmed so the picture is never mistaken
                    // for a canopy someone looked at and agreed with.
                    .opacity(selection.isConfirmed ? 1 : 0.55)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Canopy Density")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Picker("Canopy Density", selection: densityBinding) {
                    ForEach(CanopyDensity.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Low is an open, well-exposed canopy. High is dense growth "
                     + "that needs more water to wet through.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Says what is missing AND offers the one-tap way to answer it.
    ///
    /// Without the button an operator whose canopy genuinely is Medium / Low
    /// would have to change a picker and change it back to clear the prompt,
    /// which teaches them the prompt is noise.
    private var unconfirmedPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Select canopy size and density", systemImage: "leaf.circle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.orange)
            Text("The canopy sets the dilute / runoff rate every per-100 L product "
                 + "is measured against, so VineTrack will not assume one for you.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .clipShape(.rect(cornerRadius: 10))
    }
}
