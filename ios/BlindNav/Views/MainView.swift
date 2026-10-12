import BlindNavCore
import SwiftUI

/// The only screen. The camera fills it; tapping anywhere starts a voice command.
/// With VoiceOver on, double-tap the screen, or use the two-finger double-tap ("magic tap").
struct MainView: View {
    @Environment(AppServices.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var nav: Navigator?
    @State private var showSettings = false

    var body: some View {
        ZStack(alignment: .top) {
            CameraPreview(session: app.ar.session, showTrackingDots: false)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            // The whole screen is the "speak" button.
            Button {
                nav?.tap()
            } label: {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .ignoresSafeArea()
            .accessibilityLabel(nav?.listening == true ? "Listening. Speak now." : "Speak a command")
            .accessibilityHint("Then say, for example, take me to kitchen")
            .accessibilityAddTraits(.startsMediaSession)

            VStack(spacing: 12) {
                topBar
                Spacer()
                if let nav, nav.listening {
                    listeningCard(nav)
                } else {
                    CaptionView()
                }
                Text("Tap anywhere and speak")
                    .font(.headline)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .accessibilityHidden(true)
            }
            .padding()
            .allowsHitTesting(false)       // taps go to the big button underneath...

            HStack {                       // ...except the settings button
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.title2)
                        .padding(14)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal)
            .padding(.top, 4)
        }
        .accessibilityAction(.magicTap) { nav?.tap() }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
        }
        .onAppear {
            guard nav == nil else { return }
            let n = Navigator(app: app)
            nav = n
            n.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { nav?.saveNow() }
        }
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(statusTitle).font(.title3.bold())
                Text(statusDetail).font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .combine)

            if let nav {
                RouteMapView(graph: nav.graph, you: app.ar.position, heading: app.ar.heading)
                    .id(nav.revision)
                    .frame(width: 110, height: 110)
                    .accessibilityHidden(true)
            }
            Color.clear.frame(width: 50, height: 50)   // room for the settings button
        }
    }

    private var statusTitle: String {
        switch nav?.mode ?? .starting {
        case .starting: return "Starting"
        case .recognizing(let name): return "Looking for \(name)"
        case .mapping: return app.ar.tracking.isNormal ? (nav?.placeName ?? "") : "Finding position"
        case .guiding(let dest): return "Going to \(dest)"
        }
    }

    private var statusDetail: String {
        guard let nav else { return "" }
        if !app.ar.tracking.isNormal { return app.ar.tracking.spoken }
        let named = nav.graph.landmarks.count
        let signs = nav.graph.nodes.filter { $0.signText != nil }.count
        return "Mapping as you walk · \(named) saved · \(signs) signs"
    }

    private func listeningCard(_ nav: Navigator) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Listening…", systemImage: "waveform").font(.headline).foregroundStyle(.red)
            Text(nav.heard.isEmpty ? "Say a command" : nav.heard).font(.title3.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
    }
}

struct SafetyNoticeView: View {
    @Environment(AppServices.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Before you start").font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("BlindNav is an experimental aid. It does not replace a white cane, a guide dog, or orientation and mobility training. Keep using them.")
                Text("It maps where you walk, and can only guide you along paths it has already mapped. It can be wrong and can miss obstacles, especially low, thin, glass or moving ones. It warns about stairs only on paths it has mapped before.")
                Text("Hold the phone upright at chest height, camera facing forward. Tap anywhere on the screen and speak, for example: save this place as kitchen, or take me to kitchen.")
                Text("Directions use clock positions: 12 o'clock is straight ahead, 3 o'clock is to your right. Two taps means turn left, three taps means turn right.")
                BigButton(title: "I understand", systemImage: "checkmark") {
                    app.settings.acceptedSafetyNotice = true
                }
            }
            .font(.title3)
            .padding()
        }
    }
}
