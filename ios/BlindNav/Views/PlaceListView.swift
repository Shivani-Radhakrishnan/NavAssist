import BlindNavCore
import SwiftUI

struct PlaceListView: View {
    enum Purpose { case navigate, record }
    let purpose: Purpose

    @Environment(AppServices.self) private var app
    @State private var places: [PlaceFile] = []
    @State private var newName = ""
    @State private var confirmDelete: PlaceFile?

    var body: some View {
        List {
            if purpose == .record {
                Section("New place") {
                    TextField("Name, for example Home or Office floor 2", text: $newName)
                        .font(.title3)
                        .submitLabel(.go)
                    NavigationLink {
                        RecordView(name: newName.trimmingCharacters(in: .whitespaces), existing: nil)
                    } label: {
                        Label("Start recording", systemImage: "record.circle").font(.title3)
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                              || places.contains {
                                  PlaceFile.folderName(for: $0.name)
                                      == PlaceFile.folderName(for: newName.trimmingCharacters(in: .whitespaces))
                              })
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
