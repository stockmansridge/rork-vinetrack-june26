import SwiftUI

struct GrapeVineLeafShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let cx = rect.midX

        path.move(to: CGPoint(x: cx, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: cx - w * 0.18, y: h * 0.62),
            control: CGPoint(x: cx - w * 0.05, y: h * 0.85)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: h * 0.55),
            control: CGPoint(x: cx - w * 0.45, y: h * 0.78)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx - w * 0.30, y: h * 0.30),
            control: CGPoint(x: cx - w * 0.40, y: h * 0.30)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx - w * 0.10, y: h * 0.18),
            control: CGPoint(x: cx - w * 0.10, y: h * 0.30)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx, y: rect.minY),
            control: CGPoint(x: cx - w * 0.05, y: h * 0.05)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx + w * 0.10, y: h * 0.18),
            control: CGPoint(x: cx + w * 0.05, y: h * 0.05)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx + w * 0.30, y: h * 0.30),
            control: CGPoint(x: cx + w * 0.10, y: h * 0.30)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: h * 0.55),
            control: CGPoint(x: cx + w * 0.40, y: h * 0.30)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx + w * 0.18, y: h * 0.62),
            control: CGPoint(x: cx + w * 0.45, y: h * 0.78)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx, y: rect.maxY),
            control: CGPoint(x: cx + w * 0.05, y: h * 0.85)
        )
        path.closeSubpath()
        return path
    }
}
