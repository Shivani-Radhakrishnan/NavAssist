import BlindNavCore
import SwiftUI

struct PlaceListView: View {
    enum Purpose { case navigate, record }
    let purpose: Purpose

    @Environment(AppServices.self) private var app
    @State private var places: [PlaceFile] = []
    @State private var newName = ""
    @State private var confirmDelete: PlaceFile?

    /// The typed name, or "Place 1", "Place 2"... if blank. A name that would overwrite a
    /// saved place (same folder on disk) gets a number added instead of being refused.
    private var placeName: String {
        let typed = newName.trimmingCharacters(in: .whitespaces)
        let taken = Set(places.map { PlaceFile.folderName(for: $0.name) })
        func free(_ n: String) -> Bool { !taken.contains(PlaceFile.folderName(for: n)) }
        if !typed.isEmpty, free(typed) { return typed }
        let base = typed.isEmpty ? "Place" : typed
        var i = typed.isEmpty ? 1 : 2
        while !free("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    var body: some View {
        List {
            if purpose == .record {
                Section {
                    TextField("Home", text: $newName)
                        .font(.title3)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.done)
                        .accessibilityLabel("Place name")
                    NavigationLink {
                        RecordView(name: placeName, existing: nil)
                    } label: {
                        Label("Start recording \(placeName)", systemImage: "record.circle").font(.title3)
                    }
                } header: {
                    Text("New place")
                } footer: {
                    Text("Type a name for this place, or leave it blank to use \"\(placeName)\".")
                }
            }
            Section(purpose == .record ? "Add routes to a saved place" : "Choose a place") {
                if places.isEmpty {
                    Text(purpose == .record ? "No places yet."
                         : "No places recorded yet. Ask a sighted helper to use Record a place first.")
                }
                ForEach(places, id: \.name) { place in
                    NavigationLink {
                        if purpose == .navigate {
                            NavigateView(place: place)
                        } else {
                            RecordView(name: place.name, existing: place)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(place.name).font(.title2.weight(.semibold))
                            Text("\(place.graph.landmarks.count) destinations").foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    .accessibilityElement(children: .combine)
                }
                .onDelete { idx in confirmDelete = idx.first.map { places[$0] } }
            }
        }
        .navigationTitle(purpose == .record ? "Record a place" : "Navigate")
        .onAppear { places = app.store.list() }
        .confirmationDialog("Delete \(confirmDelete?.name ?? "")? Its routes and map will be removed.",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let p = confirmDelete { try? app.store.delete(p) }
                places = app.store.list()
            }
        }
    }
}
