import SwiftUI

struct UCRInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Unit Canopy Row (UCR)")
                        .font(.title2.weight(.bold))

                    Text("Unit canopy row (UCR) is a method that enables chemical rate adjustments to be made for different canopies or growth stages to achieve consistent chemical doses during the season.")
                        .font(.body)

                    Text("One UCR is defined as a 1 metre wide × 1 metre high canopy of 100 metre length.")
                        .font(.body)
                        .fontWeight(.medium)

                    Color(.secondarySystemBackground)
                        .frame(height: 220)
                        .overlay {
                            AsyncImage(url: URL(string: "https://r2-pub.rork.com/projects/u8ega94cbdz6azh6dulre/assets/f94c9dd1-9704-4597-aa22-8c6607590ad7.png")) { phase in
                                if let image = phase.image {
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .padding(8)
                                } else if phase.error != nil {
                                    Image(systemName: "photo")
                                        .font(.largeTitle)
                                        .foregroundStyle(.tertiary)
                                } else {
                                    ProgressView()
                                }
                            }
                            .allowsHitTesting(false)
                        }
                        .clipShape(.rect(cornerRadius: 12))

                    Text("UCR is based on the assumption that 30 litres of spray mixture will thoroughly wet a vine canopy that is 1 metre high by 1 metre wide and 100 metres in length, though in reality this value can vary from 20 to 50L/UCR depending on canopy type and density.")
                        .font(.body)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .navigationTitle("UCR Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
