import SwiftUI

/// A list beside its detail. On the Mac this sits inside the window's own sidebar split, and a second
/// NavigationSplitView there gets its column frames restored wrongly (the list ends up behind the sidebar),
/// so the Mac uses a plain split view; iPhone and iPad keep NavigationSplitView's navigation.
struct MasterDetail<List: View, Detail: View>: View {
    @ViewBuilder var list: List
    @ViewBuilder var detail: Detail
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        #if os(macOS)
        HSplitView {
            list.frame(minWidth: 260, idealWidth: 320, maxWidth: 520, maxHeight: .infinity)
            NavigationStack { detail }.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        #else
        NavigationSplitView(columnVisibility: $columns) {
            list.navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            detail
        }
        #endif
    }
}
