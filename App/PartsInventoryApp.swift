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
                        Task { @MainActor in app.photoForIdentify = data; app.tab = .identify }
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

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.tab) {
            Tab("Parts", systemImage: "shippingbox", value: AppModel.Tab.parts) { PartsView() }
            Tab("Scan", systemImage: "barcode.viewfinder", value: AppModel.Tab.scan) { ScanView() }
            Tab("Identify", systemImage: "camera.viewfinder", value: AppModel.Tab.identify) { IdentifyView() }
            Tab("Locations", systemImage: "archivebox", value: AppModel.Tab.locations) { LocationsView() }
            Tab("Projects", systemImage: "list.bullet.clipboard", value: AppModel.Tab.projects) { ProjectsView() }
            Tab("Ask", systemImage: "apple.intelligence", value: AppModel.Tab.ask) { AskView() }
            #if !os(macOS)
            Tab("Settings", systemImage: "gearshape", value: AppModel.Tab.settings) { NavigationStack { SettingsView() } }
            #endif
        }
        .tabViewStyle(.sidebarAdaptable)
        #if DEBUG
        .task { DebugLaunch.apply(app, ctx) }
        #endif
    }
}
