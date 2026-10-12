import SwiftUI

@main
struct NavAssistApp: App {
    @State private var app = AppServices()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
        }
    }
}

struct RootView: View {
    @Environment(AppServices.self) private var app

    var body: some View {
        if app.settings.acceptedSafetyNotice {
            MainView()
        } else {
            SafetyNoticeView()
        }
    }
}
