import SwiftUI

struct HomeView: View {
    @Environment(AppServices.self) private var app

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if !ARController.isSupported {
                        Text("This device can't run BlindNav: it needs an iPhone with ARKit world tracking. "
                             + "The iOS Simulator can show the screens but can't track movement.")
                            .font(.headline)
                            .foregroundStyle(.red)
                    }
                    NavigationLink {
                        PlaceListView(purpose: .navigate)
                    } label: {
                        BigLabel(title: "Navigate", systemImage: "figure.walk")
                    }
                    .accessibilityHint("Choose a recorded place, then a destination, and get spoken directions.")

                    NavigationLink {
                        ObstacleView()
                    } label: {
                        BigLabel(title: "Obstacle detector", systemImage: "exclamationmark.triangle")
                    }
                    .accessibilityHint("Warns about things in front of you. No map needed.")

                    NavigationLink {
                        PlaceListView(purpose: .record)
                    } label: {
                        BigLabel(title: "Record a place", systemImage: "record.circle", tint: .orange)
                    }
                    .accessibilityHint("For a sighted helper: walk the routes once and name the destinations.")

                    NavigationLink {
                        SettingsView()
                    } label: {
                        BigLabel(title: "Settings", systemImage: "gear", tint: .gray)
                    }
                }
                .padding()
            }
            .navigationTitle("BlindNav")
        }
    }
}

/// Same look as BigButton, for NavigationLinks.
struct BigLabel: View {
    let title: String
    let systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).font(.title2)
            Text(title).font(.title2.weight(.semibold))
            Spacer()
            Image(systemName: "chevron.right").accessibilityHidden(true)
        }
        .foregroundStyle(.white)
        .padding(.vertical, 22)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: 72)
        .background(tint, in: RoundedRectangle(cornerRadius: 14))
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
                Text("It only knows routes a sighted helper has recorded, and it can be wrong: things move, lighting changes, and the camera can lose track. It may miss obstacles, especially low, thin, glass or moving ones, and it does not detect stairs or drop-offs.")
                Text("Hold the phone upright at chest height with the camera facing forward. Directions use clock positions: 12 o'clock is straight ahead, 3 o'clock is to your right, 9 o'clock to your left.")
                Text("Vibrations: two taps means turn left, three taps means turn right, a heavy thud means an obstacle.")
                BigButton(title: "I understand", systemImage: "checkmark") {
                    app.settings.acceptedSafetyNotice = true
                }
            }
            .font(.title3)
            .padding()
        }
    }
}
