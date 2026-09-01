import SwiftUI
import simd

/// A tiny top-down sketch of the scanned walls with the open loop-ends
/// marked in place — so "the room isn't complete" is something the painter
/// SEES, not a wall number they must decode. Pure rendering over
/// WallFootprint/OpenWallEnd; the fitting maths is separated out so it can
/// be unit-tested without drawing anything.
enum RoomSketchLayout {
    /// Maps world ground-plane metres into a canvas rect, preserving aspect,
    /// centred, with uniform padding. Returns nil when there is nothing to fit.
    struct Fit: Equatable {
        let scale: Double          // points per metre
        let offset: SIMD2<Double>  // canvas points to add after scaling

        func point(_ world: SIMD2<Double>) -> CGPoint {
            CGPoint(x: world.x * scale + offset.x, y: world.y * scale + offset.y)
        }
    }

    static func fit(
        points: [SIMD2<Double>], into size: CGSize, padding: Double = 18
    ) -> Fit? {
        guard !points.isEmpty, size.width > 2 * padding, size.height > 2 * padding else {
            return nil
        }
        // Degenerate spans are widened SYMMETRICALLY around the data's
        // midpoint so a lone point still lands centred, not at the edge.
        let midX = (points.map(\.x).min()! + points.map(\.x).max()!) / 2
        let midY = (points.map(\.y).min()! + points.map(\.y).max()!) / 2
        let spanX = max(points.map(\.x).max()! - points.map(\.x).min()!, 0.01)
        let spanY = max(points.map(\.y).max()! - points.map(\.y).min()!, 0.01)
        let scale = min(
            (size.width - 2 * padding) / spanX,
            (size.height - 2 * padding) / spanY
        )
        // Centre the drawing in the rect.
        let offset = SIMD2(
            Double(size.width) / 2 - midX * scale,
            Double(size.height) / 2 - midY * scale
        )
        return Fit(scale: scale, offset: offset)
    }
}

struct RoomSketch: View {
    let footprints: [WallFootprint]
    let openEnds: [OpenWallEnd]

    var body: some View {
        Canvas { context, size in
            let points = footprints.flatMap { [$0.start, $0.end] }
            guard let fit = RoomSketchLayout.fit(points: points, into: size) else { return }

            var wallPath = Path()
            for wall in footprints {
                wallPath.move(to: fit.point(wall.start))
                wallPath.addLine(to: fit.point(wall.end))
            }
            context.stroke(
                wallPath,
                with: .color(.primary.opacity(0.75)),
                style: StrokeStyle(lineWidth: 5, lineCap: .round)
            )

            for gap in openEnds {
                let centre = fit.point(gap.position)
                let ring = Path(ellipseIn: CGRect(
                    x: centre.x - 9, y: centre.y - 9, width: 18, height: 18))
                context.stroke(ring, with: .color(.red), lineWidth: 3)
                let dot = Path(ellipseIn: CGRect(
                    x: centre.x - 2.5, y: centre.y - 2.5, width: 5, height: 5))
                context.fill(dot, with: .color(.red))
            }
        }
        .accessibilityLabel(
            openEnds.isEmpty
                ? "Sketch of the scanned walls"
                : "Sketch of the scanned walls with \(openEnds.count) open end\(openEnds.count == 1 ? "" : "s") marked in red"
        )
    }
}
