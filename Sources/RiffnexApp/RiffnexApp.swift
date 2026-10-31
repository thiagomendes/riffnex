import DesignSystem
import SwiftUI

@main
struct RiffnexApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(RX.Palette.violet)
        }
    }
}

struct RootView: View {
    var body: some View {
        NavigationStack {
            HomeView()
        }
    }
}
