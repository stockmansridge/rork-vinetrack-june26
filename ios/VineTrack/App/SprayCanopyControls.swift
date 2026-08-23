import SwiftUI

/// The canopy model's operator-facing controls — VSP canopy size, density, and
/// the reference imagery that makes the choice meaningful standing in a row.
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
struct SprayCanopyControls: View {
    @Binding var size: CanopySize
    @Binding var density: CanopyDensity

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("VSP Canopy Size")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Picker("Canopy Size", selection: $size) {
                    ForEach(CanopySize.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(size.description)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let imageURL = size.referenceImageURL {
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
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Canopy Density")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Picker("Canopy Density", selection: $density) {
                    ForEach(CanopyDensity.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
    }
}
