import BlindNavCore
import SwiftUI

struct ObstacleView: View {
    @Environment(AppServices.self) private var app
    @State private var session: ObstacleSession?

    var body: some View {
        VStack(spacing: 16) {
            if let s = session {
                if let problem = s.problem {
                    Text(problem).font(.title3)
                } else {
                    Text("Using \(s.detector ?? "camera")").foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(Zone.allCases, id: \.rawValue) { z in
                            let on = s.blocked[z.rawValue]
                            RoundedRectangle(cornerRadius: 12)
                                .fill(on ? Color.red : Color.green.opacity(0.4))
                                .overlay(Text(z.name.capitalized).font(.title3.bold()))
                                .frame(height: 140)
                                .accessibilityElement()
                                .accessibilityLabel("\(z.name): \(on ? "blocked" : "clear")")
                        }
                    }
                }
                Text(app.ar.tracking.isNormal ? "" : app.ar.tracking.spoken)
                CaptionView()
                Spacer()
            }
        }
        .padding()
        .navigationTitle("Obstacle detector")
        .onAppear {
            guard session == nil else { return }
            let s = ObstacleSession(app: app)
            session = s
            s.begin()
        }
        .onDisappear { session?.end() }
    }
}
