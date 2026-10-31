import DesignSystem
import Persistence
import SwiftUI

@main
struct RiffnexApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .preferredColorScheme(.dark)
                .tint(RX.Palette.violet)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("rx.onboardingCompleted") private var onboardingCompleted = false
    @State private var path: [SongRecord] = []

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(path: $path)
                .navigationDestination(for: SongRecord.self) { song in
                    PlayerView(song: song)
                }
        }
        .task { await app.bootstrap() }
        .fullScreenCover(isPresented: Binding(get: { !onboardingCompleted }, set: { onboardingCompleted = !$0 })) {
            OnboardingView { onboardingCompleted = true }
        }
    }
}
