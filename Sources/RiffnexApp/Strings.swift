import Foundation

/// Localized string from this module's bundle. Under xtool, app code lives in a library target,
/// so resources are in `Bundle.module`, not `Bundle.main`.
func tr(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}

enum AppResources {
    /// The bundled original demo song. `.process` may flatten directories, so look in both places.
    static var demoSongURL: URL? {
        Bundle.module.url(forResource: "riffnex-demo", withExtension: "m4a", subdirectory: "Demo")
            ?? Bundle.module.url(forResource: "riffnex-demo", withExtension: "m4a")
    }
}
