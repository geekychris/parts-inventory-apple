import MachO
import Security
import SwiftData
import SwiftUI

@main
struct PartsInventoryApp: App {
    @State private var app = AppModel()
    let container: ModelContainer
    /// Whether the store syncs with iCloud (it falls back to this device only when it can't).
    static nonisolated(unsafe) var syncsWithICloud = false

    static let cloudContainer = "iCloud.com.hitorro.PartsInventory"

    init() {
        let schema = Schema(Schema1.models)
        defer { APIService.shared.attach(container) }
        // Under XCTest the app is only the tests' host: keep its data in memory, away from the real inventory.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            container = try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
            return
        }
        // CloudKit traps (rather than throwing) when the app isn't signed with the iCloud
        // entitlement, so only ask for it when the entitlement is there.
        if Self.hasCloudKitEntitlement,
           let c = try? ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .private(Self.cloudContainer))) {
            container = c; Self.syncsWithICloud = true
        } else {
            // No iCloud entitlement (an unsigned build) or no account: keep the data on this device.
            container = try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .none))
        }
    }

    /// Whether this build is signed with iCloud (CloudKit). Unsigned development builds aren't.
    static var hasCloudKitEntitlement: Bool {
        if ProcessInfo.processInfo.arguments.contains("-localStore") { return false }
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let v = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) else { return false }
        return (v as? [String])?.contains("CloudKit") ?? false
        #elseif targetEnvironment(simulator)
        // Simulator builds carry their entitlements in a section of the binary.
        var size: UInt = 0
        guard let header = _dyld_get_image_header(0),
              let p = getsectiondata(UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self), "__TEXT", "__entitlements", &size) else { return false }
        return String(decoding: UnsafeBufferPointer(start: p, count: Int(size)), as: UTF8.self).contains("CloudKit")
        #else
        return true   // device builds are always signed, with the entitlement from the provisioning profile
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                #if os(macOS)
                // File › Import from iPhone or iPad: a photo taken on the phone goes to Identify.
                .importsItemProviders([.image]) { providers in
                    guard let p = providers.first else { return false }
                    _ = p.loadDataRepresentation(for: .image) { data, _ in
                        guard let data else { return }
                        Task { @MainActor in
                            if app.tab == .batch { app.photosForBatch.append(data) } else { app.photoForIdentify = data; app.tab = .identify }
                        }
                    }
                    return true
                }
                #endif
        }
        .modelContainer(container)
        #if os(macOS)
        .commands { ImportFromDevicesCommands() }
        #endif
        #if os(macOS)
        Settings {
            SettingsView().environment(app).modelContainer(container).frame(width: 520, height: 560)
        }
        #endif
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var ctx

    /// The sections, in sidebar order.
    static let sections: [(tab: AppModel.Tab, title: String, icon: String)] = [
        (.parts, "Parts", "shippingbox"), (.scan, "Scan", "barcode.viewfinder"), (.identify, "Identify", "camera.viewfinder"),
        (.batch, "Batch", "square.stack.3d.down.right"), (.locations, "Locations", "archivebox"),
        (.projects, "Projects", "list.bullet.clipboard"), (.ask, "Ask", "apple.intelligence"),
    ]

    @ViewBuilder func section(_ tab: AppModel.Tab) -> some View {
        switch tab {
        case .parts: PartsView()
        case .scan: ScanView()
        case .identify: IdentifyView()
        case .batch: BatchView()
        case .locations: LocationsView()
        case .projects: ProjectsView()
        case .ask: AskView()
        case .settings: NavigationStack { SettingsView() }
        }
    }

    var body: some View {
        @Bindable var app = app
        Group {
        #if os(macOS)
        // A plain sidebar with a sensible width: the adaptable tab view let a restored layout stretch the sidebar
        // across the window and squeeze each section's own list to nothing.
        NavigationSplitView {
            List(Self.sections, id: \.tab, selection: Binding(get: { app.tab }, set: { if let t = $0 { app.tab = t } })) { s in
                Label(s.title, systemImage: s.icon).tag(s.tab)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            section(app.tab)
        }
        #else
        TabView(selection: $app.tab) {
            ForEach(Self.sections, id: \.tab) { s in
                Tab(s.title, systemImage: s.icon, value: s.tab) { section(s.tab) }
            }
            Tab("Settings", systemImage: "gearshape", value: AppModel.Tab.settings) { section(.settings) }
        }
        .tabViewStyle(.sidebarAdaptable)
        #endif
        }
        #if DEBUG
        .task { DebugLaunch.apply(app, ctx) }
        #endif
    }
}
