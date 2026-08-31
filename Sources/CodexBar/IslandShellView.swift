import SwiftUI

struct IslandShellShape: Shape {
    var shoulderRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(self.shoulderRadius, self.bottomRadius) }
        set {
            self.shoulderRadius = newValue.first
            self.bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let shoulder = max(0, min(self.shoulderRadius, rect.width / 2))
        let bottom = max(0, min(self.bottomRadius, min(rect.height, rect.width / 2)))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + shoulder, y: rect.minY + shoulder),
            control: CGPoint(x: rect.minX + shoulder, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + shoulder, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + shoulder + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + shoulder, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - shoulder - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - shoulder, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - shoulder, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - shoulder, y: rect.minY + shoulder))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - shoulder, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
