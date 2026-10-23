import PartsKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Exports: the inventory (or the rows a table shows) as CSV or Excel, and the whole inventory as a folder
/// for a git repository (see docs/repository-format.md). One per window, from `.exportPresenter()`; the
/// Export menu, the File menu and Settings ask it.
@Observable
final class ExportController {
    enum Format { case csv, excel }
    enum FolderPurpose { case export, `import` }

    /// The repository options, in Settings › Export and share.
    static let nameKey = "exportName", fullKey = "exportFull", photosKey = "exportPhotos"
    /// The last folder exported to: a security-scoped bookmark, and its name for the menu.
    static let bookmarkKey = "exportFolderBookmark", folderNameKey = "exportFolderName"

    @ObservationIgnored var ctx: ModelContext?
    var file: ExportFile?
    var fileType: UTType = .commaSeparatedText
    var exportingFile = false
    var choosingFolder = false
    var folderPurpose = FolderPurpose.export
    var busy = false
    var message: String?

    static var options: Repository.Options {
        let d = UserDefaults.standard
        let name = d.string(forKey: nameKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Repository.Options(name: name.isEmpty ? "Parts inventory" : name, full: d.bool(forKey: fullKey), photos: d.bool(forKey: photosKey))
    }

    static var defaultLowStock: Int? { let n = UserDefaults.standard.integer(forKey: "defaultLowStock"); return n > 0 ? n : nil }

    static var fileName: String { "parts-inventory-\(Export.isoDate(.now))" }

    /// CSV or Excel of `rows`, or of the whole inventory.
    func export(_ format: Format, rows: [InventoryRow]? = nil) {
        guard let ctx else { return }
        let table = InventoryRow.table(rows ?? InventoryRow.catalogueOrder(Inventory.backup(in: ctx, photos: false).rows(defaultLowStock: Self.defaultLowStock)))
        switch format {
        case .csv: file = ExportFile(data: CSV.data(table)); fileType = .commaSeparatedText
        case .excel: file = ExportFile(data: XLSX.data(table)); fileType = .xlsx
        }
        exportingFile = true
    }

    func chooseFolder(_ purpose: FolderPurpose) { folderPurpose = purpose; choosingFolder = true }

    func folderChosen(_ url: URL) async {
        switch folderPurpose {
        case .export:
            remember(url)
            message = await writeRepository(to: url)
        case .import:
            message = importRepository(from: url)
        }
    }

    // ------------------------------------------------------------ the repository folder

    /// The folder last exported to, if it can still be found.
    var rememberedFolder: URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: Self.bookmarkOptions, relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale { remember(url) }
        return url
    }

    func exportAgain() async {
        guard let url = rememberedFolder else {
            message = "The folder last exported to can’t be found. Choose it again with Export to folder…"
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey); UserDefaults.standard.removeObject(forKey: Self.folderNameKey)
            return
        }
        message = await writeRepository(to: url)
    }

    #if os(macOS)
    static let bookmarkOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    static let bookmarkCreation: URL.BookmarkCreationOptions = [.withSecurityScope]
    #else
    static let bookmarkOptions: URL.BookmarkResolutionOptions = []
    static let bookmarkCreation: URL.BookmarkCreationOptions = []
    #endif

    func remember(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData(options: Self.bookmarkCreation, includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        UserDefaults.standard.set(url.lastPathComponent, forKey: Self.folderNameKey)
    }

    /// Write the whole inventory into a folder as a repository. Returns what happened, for the user.
    func writeRepository(to url: URL) async -> String {
        guard let ctx else { return "" }
        let options = Self.options, low = Self.defaultLowStock
        let backup = Inventory.backup(in: ctx, photos: options.photos)
        busy = true
        defer { busy = false }
        do {
            let (written, removed) = try await Task.detached {
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                return try Repository.write(Repository.files(backup, options: options, defaultLowStock: low), to: url)
            }.value
            let changes = written.isEmpty && removed.isEmpty ? "nothing had changed"
                : "\(written.count) file\(written.count == 1 ? "" : "s") written" + (removed.isEmpty ? "" : ", \(removed.count) removed")
            return "Exported \(backup.parts.count) parts to “\(url.lastPathComponent)”: \(changes)."
        } catch {
            return "Couldn’t export to “\(url.lastPathComponent)”: \(error.localizedDescription)"
        }
    }

    /// Merge a repository folder's inventory.json, as importing a backup does.
    func importRepository(from url: URL) -> String {
        guard let ctx else { return "" }
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        let file = url.appending(path: "inventory.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            return "There’s no inventory.json in “\(url.lastPathComponent)”. Choose a folder exported with Export to folder…"
        }
        do {
            let (b, warnings) = try Backup.read(Data(contentsOf: file))
            let r = Inventory.merge(b, warnings: warnings, in: ctx)
            return "Imported from “\(url.lastPathComponent)”: \(r.added) added, \(r.updated) updated, \(r.kept) kept (newer here)."
                + (r.warnings.isEmpty ? "" : " " + r.warnings.joined(separator: " "))
        } catch { return error.localizedDescription }
    }
}

extension UTType {
    nonisolated static let xlsx = UTType("org.openxmlformats.spreadsheetml.sheet") ?? UTType(filenameExtension: "xlsx") ?? .data
}

/// A file to save: CSV or Excel.
struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .xlsx] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

extension EnvironmentValues {
    @Entry var exportController: ExportController?
}

extension FocusedValues {
    @Entry var exportController: ExportController?
}

extension View {
    /// Give this window an export controller and the save and folder panels it shows.
    func exportPresenter() -> some View { modifier(ExportPresenter()) }
}

struct ExportPresenter: ViewModifier {
    @Environment(\.modelContext) private var ctx
    @State private var controller = ExportController()

    func body(content: Content) -> some View {
        @Bindable var c = controller
        content
            .environment(\.exportController, controller)
            .focusedSceneValue(\.exportController, controller)
            .onAppear { controller.ctx = ctx }
            .fileExporter(isPresented: $c.exportingFile, document: controller.file, contentType: controller.fileType,
                          defaultFilename: ExportController.fileName) { r in
                if case .failure(let e) = r { controller.message = e.localizedDescription }
                controller.file = nil
            }
            .fileImporter(isPresented: $c.choosingFolder, allowedContentTypes: [.folder]) { r in
                guard case .success(let url) = r else { return }
                Task { await controller.folderChosen(url) }
            }
            .alert(controller.folderPurpose == .import ? "Import" : "Export", isPresented: Binding(get: { controller.message != nil }, set: { if !$0 { controller.message = nil } })) {
                Button("OK") { controller.message = nil }
            } message: { Text(controller.message ?? "") }
    }
}

/// The Export menu: CSV and Excel of `rows` (a table's filtered rows) or of the whole inventory, and the
/// repository folder, which is always the whole inventory.
struct ExportMenu: View {
    var rows: [InventoryRow]? = nil
    @Environment(\.exportController) private var controller
    @AppStorage(ExportController.folderNameKey) private var folderName = ""

    var body: some View {
        Menu {
            ExportMenuItems(controller: controller, rows: rows, folderName: folderName)
        } label: { Label("Export", systemImage: "square.and.arrow.up") }
            .disabled(controller == nil || controller?.busy == true)
            .help(rows.map { "Export the \($0.count) parts shown, or the whole inventory to a folder" } ?? "Export the inventory as CSV, Excel or a folder for GitHub")
    }
}

struct ExportMenuItems: View {
    var controller: ExportController?
    var rows: [InventoryRow]?
    var folderName: String

    var body: some View {
        Button("Export as CSV…") { controller?.export(.csv, rows: rows) }
        Button("Export as Excel…") { controller?.export(.excel, rows: rows) }
        Divider()
        Button("Export to folder…") { controller?.chooseFolder(.export) }
        if !folderName.isEmpty {
            Button("Export to “\(folderName)” again") { Task { await controller?.exportAgain() } }
        }
    }
}

#if os(macOS)
/// File › Export…, for the window in front.
struct ExportCommands: Commands {
    @FocusedValue(\.exportController) private var controller
    @AppStorage(ExportController.folderNameKey) private var folderName = ""

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Divider()
            ExportMenuItems(controller: controller, rows: nil, folderName: folderName)
                .disabled(controller == nil)
            Button("Import from Folder…") { controller?.chooseFolder(.import) }
                .disabled(controller == nil)
        }
    }
}
#endif

/// Settings › Export and share: the repository folder's options, and reading one back.
struct ExportSettingsSection: View {
    @Environment(\.exportController) private var controller
    @AppStorage(ExportController.nameKey) private var name = ""
    @AppStorage(ExportController.fullKey) private var full = false
    @AppStorage(ExportController.photosKey) private var photos = false
    @AppStorage(ExportController.folderNameKey) private var folderName = ""

    var body: some View {
        Section {
            TextField("Inventory name", text: $name, prompt: Text("Parts inventory"))
            Toggle("Include projects and stock history", isOn: $full)
            Toggle("Include photos", isOn: $photos)
            Button { controller?.chooseFolder(.export) } label: { Label("Export to folder…", systemImage: "folder.badge.plus") }
            if !folderName.isEmpty {
                Button { Task { await controller?.exportAgain() } } label: { Label("Export to “\(folderName)” again", systemImage: "arrow.clockwise") }
            }
            Button { controller?.chooseFolder(.import) } label: { Label("Import from folder…", systemImage: "folder") }
        } header: { Text("Export and share") } footer: {
            Text("Export to folder writes the inventory as a folder for a git repository: a README, a page per category, parts.csv and inventory.json. Commit and push it to GitHub to share it. Only parts and locations are included — not the prices you paid — unless you add projects and stock history. Import from folder reads such a folder’s inventory.json and merges it, as importing a backup does.")
        }
        .disabled(controller == nil || controller?.busy == true)
    }
}
