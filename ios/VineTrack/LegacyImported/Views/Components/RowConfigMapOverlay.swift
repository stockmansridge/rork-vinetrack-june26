import SwiftUI

struct RowConfigMapOverlay: View {
    @Binding var rowDirection: Double
    @Binding var rowCount: Int
    @Binding var rowWidth: Double
    @Binding var rowOffset: Double
    @Binding var rowStartNumber: Int
    @Binding var rowNumberAscending: Bool
    let polygonPoints: [CoordinatePoint]
    @Environment(\.dismiss) private var dismiss

    private var computedFirstRowNumber: Int {
        rowNumberAscending ? rowStartNumber : rowStartNumber + max(rowCount - 1, 0)
    }

    private var computedLastRowNumber: Int {
        rowNumberAscending ? rowStartNumber + max(rowCount - 1, 0) : rowStartNumber
    }

    var body: some View {
        ZStack {
            RowPreviewMapView(
                polygonPoints: polygonPoints,
                rowDirection: rowDirection,
                rowCount: rowCount,
                rowWidth: rowWidth,
                rowOffset: rowOffset,
                firstRowNumber: computedFirstRowNumber,
                lastRowNumber: computedLastRowNumber,
                showRowLabels: true
            )
            .ignoresSafeArea()

            VStack {
                headerBar
                Spacer()
                controlPanel
            }
        }
    }

    private var headerBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            Spacer()
            Text("Row Configuration")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
            Spacer()
            Color.clear.frame(width: 36, height: 36)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var controlPanel: some View {
        VStack(spacing: 16) {
            directionControl
            Divider()
            rowCountControl
            Divider()
            rowWidthControl
            Divider()
            rowOffsetControl

            if rowCount > 0 {
                Divider()
                rowNumberingControl
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var directionControl: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Direction")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(String(format: "%.1f", rowDirection))\u{00B0}")
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(VineyardTheme.info)
            }
            HStack(spacing: 12) {
                Button {
                    rowDirection = max(0, rowDirection - 0.5)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 36, height: 36)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }

                Slider(value: $rowDirection, in: 0...360, step: 0.5)

                Button {
                    rowDirection = min(360, rowDirection + 0.5)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 36, height: 36)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }
            }
        }
    }

    private var rowCountControl: some View {
        HStack {
            Text("Rows")
                .font(.subheadline.weight(.medium))
            Spacer()
            HStack(spacing: 16) {
                Button {
                    if rowCount > 0 { rowCount -= 1 }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(VineyardTheme.info)
                }
                .disabled(rowCount <= 0)

                Text("\(rowCount)")
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .frame(minWidth: 40)

                Button {
                    if rowCount < 500 { rowCount += 1 }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(VineyardTheme.info)
                }
                .disabled(rowCount >= 500)
            }
        }
    }

    private var rowWidthControl: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Row Width")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(rowWidth, specifier: "%.1f") m")
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(VineyardTheme.info)
            }
            Slider(value: $rowWidth, in: 0.0...4.0, step: 0.1)
        }
    }

    private var rowOffsetControl: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Shift Rows")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(rowOffset, specifier: "%.1f") m")
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(VineyardTheme.info)
            }
            HStack(spacing: 12) {
                Button {
                    rowOffset -= 0.5
                } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 36, height: 36)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }

                Slider(value: $rowOffset, in: -50...50, step: 0.25)

                Button {
                    rowOffset += 0.5
                } label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 36, height: 36)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }
            }
            HStack {
                Button {
                    rowOffset = 0
                } label: {
                    Text("Reset")
                        .font(.caption)
                        .foregroundStyle(VineyardTheme.info)
                }
                Spacer()
            }
        }
    }

    private var rowNumberingControl: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Row Numbering")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Stepper(value: $rowStartNumber, in: 1...9999) {
                    Text("Start: \(rowStartNumber)")
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .foregroundStyle(VineyardTheme.info)
                }
                .fixedSize()
            }

            Button {
                rowNumberAscending.toggle()
            } label: {
                HStack(spacing: 0) {
                    VStack(spacing: 2) {
                        Text("Left")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Row \(computedFirstRowNumber)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(VineyardTheme.info)
                    }
                    .frame(maxWidth: .infinity)

                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(VineyardTheme.info)
                        .frame(width: 36, height: 36)
                        .background(Color(.tertiarySystemFill), in: Circle())

                    VStack(spacing: 2) {
                        Text("Right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Row \(computedLastRowNumber)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(VineyardTheme.info)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.plain)
        }
    }
}
