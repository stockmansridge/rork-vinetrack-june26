import SwiftUI

/// Help stays readable at larger text sizes; compact devices use a scrollable sheet.
struct FieldInfoButton: View {
    let title: String
    let message: String
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            Image(systemName: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $isPresented) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(message).font(.body).fixedSize(horizontal: false, vertical: true)
                    Button("Done") { isPresented = false }
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(idealWidth: 340, idealHeight: 360)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationCompactAdaptation(.sheet)
        }
        .accessibilityLabel("\(title) help")
    }
}
