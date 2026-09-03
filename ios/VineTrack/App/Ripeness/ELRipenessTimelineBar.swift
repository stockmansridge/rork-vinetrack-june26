import SwiftUI

/// Season scrubber for the ripeness heatmap.
///
/// The track spans every day between the first and last observation of the
/// Vintage; the ticks mark the days that actually carry an observation. Prev /
/// next jump between those ticks rather than crawling a day at a time, because
/// the days in between are interpolation, not data.
///
/// Nothing in here touches the network — scrubbing only re-runs the local
/// contract maths.
struct ELRipenessTimelineBar: View {
    @Binding var index: Int
    let dayCount: Int
    let observationIndices: [Int]
    let currentLabel: String
    let isPlaying: Bool
    let canStepBack: Bool
    let canStepForward: Bool
    let onStepBack: () -> Void
    let onStepForward: () -> Void
    let onTogglePlay: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var upperBound: Double { Double(max(dayCount - 1, 0)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(action: onStepBack) {
                    Image(systemName: "backward.end.fill")
                        .font(.subheadline)
                        .frame(width: 44, height: 44)
                }
                .disabled(!canStepBack)
                .accessibilityLabel("Previous observation date")

                Button(action: onTogglePlay) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(isPlaying ? "Pause season playback" : "Play season playback")

                Button(action: onStepForward) {
                    Image(systemName: "forward.end.fill")
                        .font(.subheadline)
                        .frame(width: 44, height: 44)
                }
                .disabled(!canStepForward)
                .accessibilityLabel("Next observation date")

                Spacer(minLength: 8)

                Text(currentLabel)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityLabel("Showing \(currentLabel)")
            }

            if dayCount > 1 {
                ZStack(alignment: .topLeading) {
                    GeometryReader { geometry in
                        markers(width: geometry.size.width)
                    }
                    .frame(height: 6)
                    .padding(.horizontal, 12)
                    .allowsHitTesting(false)

                    Slider(
                        value: Binding(
                            get: { Double(index) },
                            set: { index = Int($0.rounded()) }
                        ),
                        in: 0...upperBound,
                        step: 1
                    )
                    .padding(.top, 8)
                    .accessibilityLabel("Season timeline")
                    .accessibilityValue(currentLabel)
                }
                .frame(height: 44)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: index)
    }

    /// Ticks for the days that carry observations. Positioned against the
    /// slider's usable track, inset to match the thumb radius.
    private func markers(width: CGFloat) -> some View {
        let usable = max(width - 4, 1)
        return ZStack(alignment: .topLeading) {
            Capsule()
                .fill(.quaternary)
                .frame(height: 3)
                .padding(.top, 1.5)

            ForEach(observationIndices, id: \.self) { dayIndex in
                let fraction = upperBound > 0 ? CGFloat(dayIndex) / CGFloat(upperBound) : 0
                Capsule()
                    .fill(dayIndex == index ? Color.accentColor : Color.secondary.opacity(0.75))
                    .frame(width: 2.5, height: 6)
                    .offset(x: fraction * usable)
            }
        }
    }
}
