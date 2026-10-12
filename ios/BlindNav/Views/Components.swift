import BlindNavCore
import SwiftUI

/// A large, full-width button: easy to find by touch and with VoiceOver.
struct BigButton: View {
    let title: String
    var systemImage: String?
    var hint: String?
    var role: ButtonRole?
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 12) {
                if let systemImage { Image(systemName: systemImage).font(.title2) }
                Text(title).font(.title2.weight(.semibold)).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 22)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 72)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .accessibilityHint(hint ?? "")
    }
}

/// The last sentence spoken, in large text, for sighted helpers and low-vision users.
/// Hidden from VoiceOver, which would otherwise read everything twice.
struct CaptionView: View {
    @Environment(AppServices.self) private var app

    var body: some View {
        Text(app.caption.isEmpty ? " " : app.caption)
            .font(.title3.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }
}

/// Overhead drawing of the recorded paths, for the sighted helper.
struct RouteMapView: View {
    let graph: RouteGraph
    var you: Vec2?
    var heading: Vec2?
    var route: [Vec2] = []

    var body: some View {
        Canvas { ctx, size in
            var pts = graph.nodes.map(\.position)
            if let you { pts.append(you) }
            guard !pts.isEmpty else { return }
            let minX = CGFloat(pts.map(\.x).min()! - 1), maxX = CGFloat(pts.map(\.x).max()! + 1)
            let minY = CGFloat(pts.map(\.y).min()! - 1), maxY = CGFloat(pts.map(\.y).max()! + 1)
            let scale: CGFloat = min(size.width / (maxX - minX), size.height / (maxY - minY))
            let padX: CGFloat = (size.width - (maxX - minX) * scale) / 2
            let padY: CGFloat = (size.height - (maxY - minY) * scale) / 2
            func screen(_ p: Vec2) -> CGPoint {
                let x: CGFloat = (CGFloat(p.x) - minX) * scale + padX
                let y: CGFloat = size.height - ((CGFloat(p.y) - minY) * scale + padY)
                return CGPoint(x: x, y: y)
            }
            var edges = Path()
            for n in graph.nodes {
                for nb in graph.neighbours[n.id, default: []] where nb > n.id {
                    edges.move(to: screen(n.position))
                    edges.addLine(to: screen(graph.node(nb).position))
                }
            }
            ctx.stroke(edges, with: .color(.secondary), lineWidth: 3)
            if route.count > 1 {
                var r = Path()
                r.addLines(route.map(screen))
                ctx.stroke(r, with: .color(.green), lineWidth: 5)
            }
            for n in graph.landmarks {
                let c = screen(n.position)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)), with: .color(.red))
                ctx.draw(Text(n.landmark ?? "").font(.caption.bold()), at: CGPoint(x: c.x, y: c.y - 14))
            }
            if let you {
                let c = screen(you)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18)), with: .color(.blue))
                if let h = heading {
                    var arrow = Path()
                    arrow.move(to: c)
                    arrow.addLine(to: CGPoint(x: c.x + CGFloat(h.x) * 26, y: c.y - CGFloat(h.y) * 26))
                    ctx.stroke(arrow, with: .color(.blue), lineWidth: 4)
                }
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement()
        .accessibilityLabel("Map of recorded paths with \(graph.landmarks.count) landmarks")
    }
}
