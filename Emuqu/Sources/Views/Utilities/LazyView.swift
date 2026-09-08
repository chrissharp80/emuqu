import SwiftUI

/// Defers body evaluation until the view actually appears.
/// Use inside TabView to avoid materializing all tabs at launch.
struct LazyView<Content: View>: View {
    let build: () -> Content

    init(_ build: @autoclosure @escaping () -> Content) {
        self.build = build
    }

    var body: some View {
        build()
    }
}
