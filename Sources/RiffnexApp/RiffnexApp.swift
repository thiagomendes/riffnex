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
                .tint(RX.Palette.magenta)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var path: [SongRecord] = []

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(path: $path)
                .navigationDestination(for: SongRecord.self) { song in
                    SongView(song: song)
                }
        }
        .task { await app.bootstrap() }
    }
}
