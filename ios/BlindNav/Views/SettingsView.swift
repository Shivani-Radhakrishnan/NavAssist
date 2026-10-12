import BlindNavCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppServices.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var places: [PlaceFile] = []
    @State private var confirmDelete: PlaceFile?
    @State private var tripCount = 0
    @State private var exportURL: URL?
    @State private var confirmDeleteTrips = false

    var body: some View {
        @Bindable var s = app.settings
        Form {
            Section("Distances") {
                Picker("Say distances in", selection: $s.unit) {
                    Text("Meters").tag(DistanceUnit.meters)
                    Text("Feet").tag(DistanceUnit.feet)
                    Text("Steps").tag(DistanceUnit.steps)
                }
                if s.unit == .steps {
                    Stepper(String(format: "Step length: %.2f m", s.stepLength), value: $s.stepLength, in: 0.4...1.0, step: 0.05)
                }
            }
            Section("Voice") {
                VStack(alignment: .leading) {
                    Text("Speaking speed")
                    Slider(value: $s.speechRate, in: 0...1) { Text("Speaking speed") }
                }
                Button("Test voice") {
                    app.applySettings()
                    app.speaker.say("In \(s.phrasing.distance(2)), turn left.", urgent: true)
                }
                Toggle("Vibrations", isOn: $s.haptics)
            }
            Section {
                Toggle("Obstacle warnings while navigating", isOn: $s.obstacleWarnings)
                if ARController.hasLiDAR {
                    Stepper(String(format: "Warn when closer than %.1f m", s.warnDistance),
                            value: $s.warnDistance, in: 0.8...3.0, step: 0.1)
                }
            } header: {
                Text("Obstacles")
            } footer: {
                Text(ARController.hasLiDAR
                     ? "This iPhone has LiDAR, so obstacle distances are measured."
                     : "This iPhone has no LiDAR. Obstacle warnings use a depth model and are less reliable.")
            }
            Section {
                Toggle("Predictive cues", isOn: $s.adaptiveCues)
                    .disabled(s.studyMode)
                Toggle("Study mode", isOn: $s.studyMode)
                HStack {
                    Text("Participant")
                    TextField("P1", text: $s.participant)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }
                Text("\(tripCount) trips recorded")
                if let exportURL {
                    ShareLink(item: exportURL) { Label("Export trip logs (CSV)", systemImage: "square.and.arrow.up") }
                }
                if tripCount > 0 {
                    Button("Delete trip logs", role: .destructive) { confirmDeleteTrips = true }
                }
            } header: {
                Text("Research study")
            } footer: {
                Text("Predictive cues watch for hesitation and turning too early, and step in with \"Not yet, keep straight\" or \"You're on track\". "
                     + "In study mode they switch on and off for alternate trips, so you can compare navigation errors with and without them. "
                     + "Every guided trip is logged; logs are also in the Files app under On My iPhone › NavAssist › Trips.")
            }
            Section {
                if places.isEmpty { Text("No maps saved yet.") }
                ForEach(places, id: \.name) { p in
                    VStack(alignment: .leading) {
                        Text(p.name).font(.headline)
                        Text("\(p.graph.landmarks.count) saved places · \(p.graph.nodes.filter { $0.signText != nil }.count) signs")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                .onDelete { idx in confirmDelete = idx.first.map { places[$0] } }
            } header: {
                Text("Saved maps")
            } footer: {
                Text("Maps are made automatically as you walk. Swipe left on one to delete it. Changes apply the next time NavAssist opens.")
            }
            Section("About") {
                Button("Show the safety notice again") { s.acceptedSafetyNotice = false }
            }
        }
        .navigationTitle("Settings")
        .toolbar { Button("Done") { dismiss() } }
        .onAppear {
            places = app.store.list()
            tripCount = app.trips.count()
            exportURL = app.trips.combinedCSV()
        }
        .onDisappear { app.applySettings() }
        .confirmationDialog("Delete \(confirmDelete?.name ?? "")? Everything saved there will be forgotten.",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let p = confirmDelete { try? app.store.delete(p) }
                places = app.store.list()
            }
        }
        .confirmationDialog("Delete all \(tripCount) trip logs? Export them first if you need them.",
                            isPresented: $confirmDeleteTrips, titleVisibility: .visible) {
            Button("Delete trip logs", role: .destructive) {
                app.trips.deleteAll()
                tripCount = 0
                exportURL = nil
            }
        }
    }
}
