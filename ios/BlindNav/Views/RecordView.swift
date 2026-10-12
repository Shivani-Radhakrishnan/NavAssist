import ARKit
import BlindNavCore
import SwiftUI

/// For the sighted helper. Walk every route the user will need, at a normal pace,
/// holding the phone upright. Stop at each destination and add a landmark.
struct RecordView: View {
    let name: String
    let existing: PlaceFile?

    @Environment(AppServices.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var session: RecordSession?
    @State private var askingName = false
    @State private var landmarkName = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 12) {
            if let s = session {
                status(s)
                CameraPreview(session: app.ar.session)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxHeight: .infinity)
                RouteMapView(graph: s.graph, you: app.ar.position, heading: app.ar.heading)
                    .id(s.revision)
                    .frame(height: 150)
                HStack(spacing: 12) {
                    BigButton(title: "Add landmark", systemImage: "mappin.and.ellipse") {
                        landmarkName = ""
                        askingName = true
                    }
                    .disabled(!app.ar.tracking.isNormal)
                    BigButton(title: s.paused ? "Resume" : "Pause", systemImage: s.paused ? "play" : "pause",
                              hint: "Pause while walking somewhere that shouldn't become a route",
                              tint: .gray) { s.togglePause() }
                }
                BigButton(title: s.saving ? "Saving…" : "Save place", systemImage: "square.and.arrow.down",
                          tint: s.mapQuality.good ? .green : .orange) {
                    Task {
                        do {
                            try await s.save()
                            dismiss()
                        } catch {
                            self.error = "Couldn't save yet: \(error.localizedDescription). Walk around a bit more and try again."
                        }
                    }
                }
                .disabled(s.saving || s.graph.landmarks.isEmpty)
            }
        }
        .padding()
        .navigationTitle(existing == nil ? "Recording \(name)" : "Adding to \(name)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: start)
        .onDisappear { session?.end() }
        .alert("Name this spot", isPresented: $askingName) {
            TextField("For example Kitchen, Front door, Desk", text: $landmarkName)
            Button("Save") { session?.addLandmark(landmarkName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stand exactly where the person should arrive.")
        }
        .alert("Not saved", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    private func status(_ s: RecordSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(trackingLine(s)).font(.headline)
            Text(s.mapQuality.text).foregroundStyle(s.mapQuality.good ? .green : .orange)
            Text("Walked \(Int(s.walkedMeters)) m · \(s.graph.landmarks.count) landmarks")
                .foregroundStyle(.secondary)
            if s.graph.landmarks.isEmpty {
                Text("Add at least one landmark before saving.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func trackingLine(_ s: RecordSession) -> String {
        if s.isExtending, app.ar.tracking == .relocalizing {
            return "Go to a spot you recorded before and look around until it's recognized."
        }
        if s.paused { return "Paused. Not recording." }
        return app.ar.tracking.isNormal ? "Recording. Walk the route at a normal pace." : app.ar.tracking.spoken
    }

    private func start() {
        guard session == nil else { return }
        var map: ARWorldMap?
        if let existing {
            do {
                map = try app.store.loadMap(for: existing)
            } catch {
                self.error = "Couldn't open the saved map for \(existing.name)."
                return
            }
        }
        let s = RecordSession(name: name, existing: existing, existingMap: map, app: app)
        session = s
        s.begin()
    }
}
