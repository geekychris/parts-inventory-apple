import PartsKit
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct IdentifyView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var ctx
    @Query private var parts: [Part]
    @State private var model = IdentifyModel()
    @State private var photoItem: PhotosPickerItem?
    @State private var importing = false
    @State private var showCamera = false
    @State private var adding: Candidate?
    @State private var lookingUp: Candidate?
    /// A listing chosen in the lookup, to fill in the part being added.
    @State private var listing: SupplierProduct?
    @State private var addAfterLookup: Candidate?
    @State private var receiving: BagLabel?
    @State private var choosingPhoto = false
    /// Where the last photo came from, so "Add and take another" can open it again.
    @State private var lastSource = BatchSource.camera
    /// Set by "Add and take another": open the photo source once the sheet has closed.
    @State private var takeAnother = false
    #if os(macOS)
    @State private var iPhone = DeviceImportHandle()
    #endif
    @AppStorage("lookWhen") private var lookWhen = IdentifyModel.LookWhen.auto
    @AppStorage("useAppleIntelligence") private var useAI = true

    var inventory: [InventoryRef] { parts.map(\.inventoryRef) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sources
                    if let img = model.image {
                        Image(decorative: img, scale: 1).resizable().scaledToFit().frame(maxHeight: 320).clipShape(.rect(cornerRadius: 12))
                            .frame(maxWidth: .infinity)
                    } else {
                        ContentUnavailableView {
                            Label("Identify a part", systemImage: "camera.viewfinder")
                        } description: {
                            Text("Take or choose a photo of a chip, a module, a board or any component. The markings are read and matched; parts without a readable number are recognised by how they look." + Self.iPhoneHint)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    if model.busy { HStack { ProgressView(); Text(model.status).foregroundStyle(.secondary) } }
                    if let e = model.error { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    if let l = model.label { bagLabel(l) }
                    if model.image != nil && !model.busy { results }
                }
                .padding()
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Identify")
            .toolbar {
                ToolbarItem {
                    Menu {
                        Picker("Recognise by look", selection: $lookWhen) {
                            Text("When the markings aren’t enough").tag(IdentifyModel.LookWhen.auto)
                            Text("Always").tag(IdentifyModel.LookWhen.always)
                            Text("Never").tag(IdentifyModel.LookWhen.never)
                        }
                        Toggle("Use Apple Intelligence", isOn: $useAI)
                        Picker("Leaning", selection: $model.mode) {
                            Text("Anything").tag(Identify.Mode.auto)
                            Text("A chip").tag(Identify.Mode.chip)
                            Text("A board or module").tag(Identify.Mode.board)
                        }
                    } label: { Label("Options", systemImage: "slider.horizontal.3") }
                }
            }
            .dropDestination(for: Data.self) { items, _ in
                guard let d = items.first else { return false }
                start(d); return true
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { r in
                if case .success(let url) = r {
                    let ok = url.startAccessingSecurityScopedResource()
                    defer { if ok { url.stopAccessingSecurityScopedResource() } }
                    if let d = try? Data(contentsOf: url) { start(d) }
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { if let d = try? await item.loadTransferable(type: Data.self) { start(d) }; photoItem = nil }
            }
            .onChange(of: app.photoForIdentify, initial: true) { _, d in
                guard let d else { return }
                app.photoForIdentify = nil
                start(d)
            }
            .onChange(of: model.mode) { model.rerank(inventory: inventory) }
            .sheet(item: $adding, onDismiss: {
                listing = nil
                if takeAnother { takeAnother = false; reopenSource() }
            }) { c in
                AddPartSheet(candidate: c, ocrText: model.markings, photo: model.photo, listing: listing,
                             another: { takeAnother = true }) { uid in app.partToShow = uid; app.tab = .parts }
            }
            .photosPicker(isPresented: $choosingPhoto, selection: $photoItem, matching: .images)
            .sheet(item: $lookingUp, onDismiss: { if let c = addAfterLookup { addAfterLookup = nil; adding = c } }) { c in
                SupplierLookupView(query: CandidateCard.searchable(c) ?? "", applyTitle: "Add to inventory…") { p in listing = p; addAfterLookup = c }
            }
            .sheet(item: Binding(get: { receiving.map(LabelBox.init) }, set: { receiving = $0?.label })) { b in ReceiveSheet(label: b.label) }
            .sheet(isPresented: $showCamera) { CameraSheet { d in start(d) } }
        }
    }

    var sources: some View {
        HStack {
            Button { lastSource = .camera; showCamera = true } label: { Label("Take a photo", systemImage: "camera") }.buttonStyle(.borderedProminent)
            Button { lastSource = .photos; choosingPhoto = true } label: { Label("Choose a photo", systemImage: "photo") }.buttonStyle(.bordered)
            Button { lastSource = .files; importing = true } label: { Label("From a file", systemImage: "folder") }.buttonStyle(.bordered)
            #if os(macOS)
            DeviceImportButton(handle: iPhone) { lastSource = .iPhone; start($0) }
            PasteButton(payloadType: Data.self) { items in if let d = items.first { lastSource = .paste; start(d) } }
            #endif
            if model.image != nil {
                Button { Task { await model.identify(inventory: inventory, lookWhen: .always, useAI: useAI) } } label: { Label("Again", systemImage: "arrow.clockwise") }
                    .disabled(model.busy)
            }
        }
        .labelStyle(.titleAndIcon)
    }

    #if os(macOS)
    static let iPhoneHint = "\n\nFor tiny markings, use From iPhone: your iPhone’s camera opens on the phone — zoom in, tap to focus — and the photo comes straight here."
    #else
    static let iPhoneHint = ""
    #endif

    /// Open the photo source used last, for the next part.
    func reopenSource() {
        Task {
            try? await Task.sleep(for: .milliseconds(350))  // let the sheet finish closing
            switch lastSource {
            case .camera: showCamera = true
            case .photos: choosingPhoto = true
            case .files: importing = true
            case .iPhone:
                #if os(macOS)
                if !DeviceImportView.takePhoto() { iPhone.showMenu() }
                #endif
            case .paste: break
            }
        }
    }

    func start(_ data: Data) {
        model.set(data)
        Task { await model.identify(inventory: inventory, lookWhen: lookWhen, useAI: useAI) }
    }

    @ViewBuilder func bagLabel(_ l: BagLabel) -> some View {
        GroupBox {
            HStack {
                VStack(alignment: .leading) {
                    Text("\(Supplier.named(l.supplier ?? "")?.name ?? "Supplier") bag label").font(.headline)
                    Text([l.mpn, l.spn, l.qty.map { "qty \($0)" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Receive…") { receiving = l }.buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder var results: some View {
        if model.candidates.isEmpty && model.label == nil {
            Text(model.markings.isEmpty ? "No text was found, and nothing was recognised by look." : "Nothing matched what was read.").foregroundStyle(.secondary)
            if !LookModel.isAvailable {
                Text("Recognising parts by look isn't in this build (the model file is missing).").font(.caption).foregroundStyle(.secondary)
            }
        }
        ForEach(model.candidates) { c in CandidateCard(candidate: c, add: { adding = c }, show: { uid in app.partToShow = uid; app.tab = .parts }, lookUp: { lookingUp = c }) }
        DisclosureGroup("Markings read") {
            TextEditor(text: $model.markings).font(.body.monospaced()).frame(minHeight: 80)
                .scrollContentBackground(.hidden).background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
            Button("Match again") { model.rerank(inventory: inventory) }
            if !model.reading.labels.isEmpty { Text("Vision sees: " + model.reading.labels.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// The camera in a sheet, for one photo.
private struct CameraSheet: View {
    var onPhoto: (Data) -> Void
    @State private var camera = Camera()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CameraView(camera: camera) { d in onPhoto(d); dismiss() }
                .padding()
                .navigationTitle("Take a photo")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .frame(minWidth: 640, minHeight: 520)
        .task { await camera.start() }
        .onDisappear { camera.stop() }
    }
}

private struct LabelBox: Identifiable { let label: BagLabel; var id: String { label.raw } }

struct CandidateCard: View {
    let candidate: Candidate
    var add: () -> Void
    var show: (String) -> Void
    var lookUp: () -> Void = {}

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline)
                        if !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text("\(Int((candidate.score * 100).rounded()))% · \(candidate.confidence)")
                        .font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(tint.opacity(0.18), in: .capsule).foregroundStyle(tint)
                }
                ForEach(candidate.reasons, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    switch candidate.source {
                    case .inventory(let p): Button("Show in my parts") { show(p.id) }.buttonStyle(.borderedProminent)
                    default: Button("Add to inventory…", action: add).buttonStyle(.borderedProminent)
                    }
                    if case .catalog(let e) = candidate.source, let ds = e.ds, let u = URL(string: ds) { Link("Datasheet", destination: u) }
                    if let pn = searchable {
                        if !isInventory { Button("Look up", action: lookUp) }
                        Menu("Search") { ForEach(Identify.searchLinks(pn)) { l in Link(l.name, destination: l.url) } }.fixedSize()
                    }
                }
            }
        }
    }

    var title: String {
        switch candidate.source {
        case .catalog(let e): e.displayName
        case .inventory(let p): p.mpn
        case .generic(let g): g.name
        case .unknown(let t): t
        case .reading(let r): r.mpn.isEmpty ? r.description : r.mpn
        }
    }
    var subtitle: String {
        switch candidate.source {
        case .catalog(let e): [e.mfr, e.desc].joined(separator: " — ")
        case .inventory: "Already in your inventory"
        case .generic(let g): g.cat.replacingOccurrences(of: "/", with: " › ")
        case .unknown: "Not in the built-in list — look it up"
        case .reading(let r): [r.manufacturer, r.mpn.isEmpty ? "" : r.description].filter { !$0.isEmpty }.joined(separator: " — ")
        }
    }
    var isInventory: Bool { if case .inventory = candidate.source { true } else { false } }
    var searchable: String? { Self.searchable(candidate) }
    /// The part number to search the web or the suppliers for.
    static func searchable(_ candidate: Candidate) -> String? {
        switch candidate.source {
        case .catalog(let e): e.mpn
        case .unknown(let t): t
        case .reading(let r): r.mpn.isEmpty ? nil : r.mpn
        case .inventory(let p): p.mpn
        case .generic: nil
        }
    }
    var tint: Color { candidate.score >= 0.85 ? .green : candidate.score >= 0.6 ? .blue : candidate.score >= 0.4 ? .orange : .gray }
}

/// Add an identified part: the fields filled in from the candidate, editable, with a quantity and a place.
struct AddPartSheet: View {
    let candidate: Candidate
    let ocrText: String
    let photo: Data?
    /// A supplier listing chosen in a lookup, filling in what the candidate doesn't say.
    var listing: SupplierProduct? = nil
    /// "Add and take another": called after adding, instead of `done`.
    var another: (() -> Void)? = nil
    var done: (String) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \StorageLocation.name) private var locations: [StorageLocation]
    @State private var draft = PartDraft()
    @State private var location: StorageLocation?
    @State private var keepPhoto = true
    @State private var lookingUp = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Manufacturer part number", text: $draft.mpn)
                TextField("Manufacturer", text: $draft.manufacturer)
                TextField("Description", text: $draft.description, axis: .vertical)
                TextField("Category", text: $draft.category)
                TextField("Package", text: $draft.package)
                TextField("Datasheet", text: $draft.datasheet)
                Stepper("Quantity: \(draft.qty)", value: $draft.qty, in: 0...100_000)
                Picker("Location", selection: $location) {
                    Text("None").tag(StorageLocation?.none)
                    ForEach(locations.sorted { $0.path < $1.path }) { l in Text(l.path).tag(Optional(l)) }
                }
                if photo != nil { Toggle("Keep the photo with the part", isOn: $keepPhoto) }
                Section {
                    Button { lookingUp = true } label: { Label("Fill in from Digi-Key or Mouser…", systemImage: "magnifyingglass") }
                        .disabled(draft.mpn.isEmpty)
                    ForEach(draft.suppliers, id: \.self) { s in
                        LabeledContent(Supplier.named(s.supplier)?.name ?? s.supplier, value: s.pn)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add to inventory")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if let another {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Add and take another") { save(); dismiss(); another() }
                            .keyboardShortcut(.return, modifiers: .command)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { let p = save(); dismiss(); done(p.uid) }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
        .onAppear {
            draft = Identify.draft(candidate, ocrText: ocrText)
            if let listing { draft.fill(from: listing) }
        }
        .sheet(isPresented: $lookingUp) { SupplierLookupView(query: draft.mpn) { draft.fill(from: $0) } }
    }

    @discardableResult
    func save() -> Part {
        let p = Inventory.add(draft, photo: keepPhoto ? photo.flatMap { Images.jpeg($0, maxSide: 1600) } : nil, location: location, in: ctx)
        app.didAdd(p)
        return p
    }
}
