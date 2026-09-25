import SwiftUI

@main
struct ScanView3DApp: App {
    @AppStorage("appAppearance") private var appearance = "system"
    var body: some Scene {
        WindowGroup {
            rootView
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        }
    }

    @ViewBuilder private var rootView: some View {
        #if DEBUG && targetEnvironment(simulator)
        if let screen = DesignPreview.screen { DesignPreviewRoot(screen: screen) }
        else { ContentView() }
        #else
        ContentView()
        #endif
    }
}
