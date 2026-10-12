import BlindNavCore
import SwiftUI

struct NavigateView: View {
    let place: PlaceFile
    @Environment(AppServices.self) private var app
    @State private var session: NavigationSession?

    var body: some View {
        VStack(spacing: 16) {
            if let s = session {
                content(s)
            } else {
                ProgressView()
            }
        }
        .padding()
        .navigationTitle(place.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard session == nil else { return }
            let s = NavigationSession(place: place, app: app)
            session = s
            s.begin()
        }
        .onDisappear { session?.end() }
    }

    @ViewBuilder
    private func content(_ s: NavigationSession) -> some View {
        switch s.phase {
        case .loading, .locating:
            Spacer()
            Text("Finding where you are…").font(.largeTitle.bold()).multilineTextAlignment(.center)
            Text(app.ar.tracking.spoken).font(.title3).multilineTextAlignment(.center)
            Spacer()
            CaptionView()
            BigButton(title: "Repeat", systemImage: "speaker.wave.2") { s.repeatInstruction() }

        case .choosing, .arrived:
            if s.phase == .arrived, let d = s.destination?.landmark {
                Text("Arrived at \(d)").font(.title.bold())
            }
            Text("Choose a destination").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            List(s.landmarks) { node in
                Button {
                    s.go(to: node)
                } label: {
                    Text(node.landmark ?? "").font(.title2).padding(.vertical, 10)
                }
                .accessibilityHint("Starts directions to this place")
            }
            .listStyle(.plain)
            BigButton(title: "Where am I?", systemImage: "location") { s.repeatInstruction() }

        case .guiding:
            Text("Going to \(s.destination?.landmark ?? "")").font(.title.bold())
                .accessibilityAddTraits(.isHeader)
            RouteMapView(graph: place.graph, you: app.ar.position, heading: app.ar.heading)
                .frame(maxHeight: 220)
            CaptionView()
            Spacer()
            // The biggest target on screen: tap anywhere here to hear the next step again.
            BigButton(title: "Repeat direction", systemImage: "speaker.wave.2",
                      hint: "Says how far to go and what to do next") { s.repeatInstruction() }
            obstacleToggle(s)
            BigButton(title: "Stop route", systemImage: "xmark", role: .destructive, tint: .red) { s.cancelRoute() }

        case .failed(let message):
            Text(message).font(.title2)
        }
    }

    private func obstacleToggle(_ s: NavigationSession) -> some View {
        VStack(alignment: .leading) {
            Toggle("Obstacle warnings", isOn: Binding(get: { s.obstaclesOn }, set: { s.obstaclesOn = $0 }))
                .font(.title3)
            if let note = s.obstacleNote { Text(note).font(.footnote).foregroundStyle(.secondary) }
        }
    }
}
