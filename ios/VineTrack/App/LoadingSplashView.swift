import SwiftUI

struct LoadingSplashView: View {
    @State private var animate: Bool = false
    @State private var pulse: Bool = false

    var body: some View {
        ZStack {
            LoginVineyardBackground()

            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.10))
                        .frame(width: animate ? 220 : 80, height: animate ? 220 : 80)
                        .blur(radius: 20)
                        .opacity(pulse ? 0.9 : 0.4)

                    Image("vinetrack_logo")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: animate ? 140 : 60, height: animate ? 140 : 60)
                        .clipShape(.rect(cornerRadius: animate ? 32 : 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: animate ? 32 : 14)
                                .stroke(.white.opacity(0.28), lineWidth: 1.2)
                        )
                        .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 10)
                        .scaleEffect(pulse ? 1.04 : 1.0)
                }

                BrandWordmark(size: 38)
                    .opacity(animate ? 1 : 0)
                    .offset(y: animate ? 0 : 10)
                    .shadow(color: .black.opacity(0.28), radius: 2, x: 0, y: 2)

                ProgressView()
                    .tint(.white)
                    .opacity(animate ? 1 : 0)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.9, dampingFraction: 0.72)) {
                animate = true
            }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true).delay(0.4)) {
                pulse = true
            }
        }
    }
}
