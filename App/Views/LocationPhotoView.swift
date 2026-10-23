import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// A location's photo — the cabinet, the shelf, the drawer open — so it's easy to see where to go.
/// Chosen from Photos, a file, the iPhone's camera (from the Mac), pasted, or dropped on it.
struct LocationPhotoView: View {
    @Bindable var location: StorageLocation
    @State private var item: PhotosPickerItem?
    @State private var choosingFile = false
    @State private var showingFull = false
    @State private var targeted = false
    #if os(iOS)
    @State private var takingPhoto = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let d = location.photo, let img = Image(data: d) {
                    Button { showingFull = true } label: {
                        img.resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 260).clipShape(.rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help("Show it larger")
                } else if let up = location.nearestPhoto, let img = Image(data: up.data) {
                    VStack(alignment: .leading, spacing: 4) {
                        img.resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 160).clipShape(.rect(cornerRadius: 8)).opacity(0.85)
                        Text("Photo of \(up.location.name). Add one of this \(location.resolvedKind.label.lowercased()) too.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView {
                        Label("No photo", systemImage: "photo.on.rectangle")
                    } description: {
                        Text("A photo of where this is makes it easy to find again. Drop one here, or add one below.")
                    }
                    .frame(maxWidth: .infinity, minHeight: 140)
                }
            }
            .overlay { if targeted { RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3) } }
            .dropDestination(for: URL.self) { urls, _ in
                guard let u = urls.first, let d = try? Data(contentsOf: u) else { return false }
                return set(d)
            } isTargeted: { targeted = $0 }

            HStack {
                PhotosPicker(selection: $item, matching: .images) { Label("Photos…", systemImage: "photo.badge.plus") }.help("Choose from Photos")
                #if os(macOS)
                DeviceImportButton(title: "iPhone") { set($0) }.fixedSize()
                Button("File…", systemImage: "folder") { choosingFile = true }.help("Choose an image file")
                Button("Paste", systemImage: "doc.on.clipboard") { paste() }.help("Paste an image")
                #else
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take Photo", systemImage: "camera") { takingPhoto = true }
                }
                #endif
                if location.photo != nil {
                    Button("Remove", systemImage: "trash", role: .destructive) { location.setPhoto(nil) }.help("Remove the photo")
                }
            }
            // With a photo there are five buttons: icons only, so they fit beside the iPhone one.
            .labelStyle(location.photo == nil ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
        }
        .onChange(of: item) { _, it in
            guard let it else { return }
            Task {
                if let d = try? await it.loadTransferable(type: Data.self) { set(d) }
                item = nil
            }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.image]) { result in
            guard case .success(let u) = result else { return }
            let ok = u.startAccessingSecurityScopedResource()
            defer { if ok { u.stopAccessingSecurityScopedResource() } }
            if let d = try? Data(contentsOf: u) { set(d) }
        }
        .sheet(isPresented: $showingFull) {
            NavigationStack {
                Group {
                    if let d = location.photo, let img = Image(data: d) { img.resizable().scaledToFit().padding() }
                }
                .navigationTitle(location.path)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingFull = false } } }
            }
            .frame(minWidth: 600, minHeight: 450)
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraCapture { set($0) }.ignoresSafeArea()
        }
        #endif
    }

    /// Store it as a JPEG no bigger than 1600 px; false when it isn't an image.
    @discardableResult
    func set(_ data: Data) -> Bool {
        guard let jpeg = Images.jpeg(data) else { return false }
        location.setPhoto(jpeg)
        return true
    }

    #if os(macOS)
    func paste() {
        let pb = NSPasteboard.general
        for t in [NSPasteboard.PasteboardType("public.heic"), .init("public.jpeg"), .png, .tiff] {
            if let d = pb.data(forType: t), set(d) { return }
        }
        if let u = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first, let d = try? Data(contentsOf: u) { set(d) }
    }
    #endif
}

#if os(iOS)
/// The system camera, for one photo.
struct CameraCapture: UIViewControllerRepresentable {
    let onImage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = .camera
        c.delegate = context.coordinator
        return c
    }
    func updateUIViewController(_ c: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCapture
        init(_ p: CameraCapture) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage, let d = img.jpegData(compressionQuality: 0.9) { parent.onImage(d) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
#endif

/// Where a part is, as a picture: shown on the part's page under its location.
struct WhereItIs: View {
    let location: StorageLocation

    var body: some View {
        if let near = location.nearestPhoto, let img = Image(data: near.data) {
            VStack(alignment: .leading, spacing: 4) {
                img.resizable().scaledToFit().frame(maxHeight: 180).clipShape(.rect(cornerRadius: 8))
                Text(near.location.uid == location.uid ? location.path
                     : "Photo of \(near.location.path) — then \(String(location.path.dropFirst(near.location.path.count + 3)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
