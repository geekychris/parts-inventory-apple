import PartsKit
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Batch add: keep taking photos (the iPhone's camera, the live camera, or many files at once); each is read,
/// identified and looked up at Digi-Key and Mouser while you carry on, and one key press adds it with
/// everything filled in.
struct BatchView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var ctx
    @Query(sort: \StorageLocation.name) private var locations: [StorageLocation]
    @AppStorage("batchLocation") private var locationID = ""
    @AppStorage("batchKeepIPhoneOpen") private var keepIPhoneOpen = true
    @AppStorage("lookWhen") private var lookWhen = IdentifyModel.LookWhen.auto
    @AppStorage("useAppleIntelligence") private var useAI = true
    @State private var showCamera = false
    @State private var camera = Camera()
    @State private var importing = false
    @State private var picks: [PhotosPickerItem] = []
    @State private var choosingPhotos = false
    /// Where the last photo came from, to open it again when the queue is done ("Add & next").
    @State private var lastSource = BatchSource.camera
    #if os(macOS)
    @State private var iPhone = DeviceImportHandle()
    #endif

    private var model: BatchModel { app.batch }
    private var location: StorageLocation? { locations.first { $0.uid == locationID } }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                settings
                sources
                if !SupplierKeys.shared.isConfigured { noKeys }
                if showCamera {
                    CameraView(camera: camera, shutterTitle: "Add to batch") { lastSource = .camera; add($0) }
                        .frame(minHeight: 220, idealHeight: 300, maxHeight: 340)
                }
                if model.items.isEmpty {
                    ContentUnavailableView {
                        Label("Add parts in a batch", systemImage: "square.stack.3d.down.right")
                    } description: {
                        Text(emptyText)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    strip
                    if let item = model.selected {
                        ScrollView { BatchReviewCard(item: item, model: model, location: location) { afterDecision() } }
                    } else {
                        Spacer()
                    }
                }
            }
            .padding()
            .navigationTitle("Batch add")
            .toolbar {
                ToolbarItem {
                    Button("Clear added", systemImage: "checkmark.circle") { model.clearDone() }
                        .disabled(!model.items.contains { $0.status.isDone })
                }
            }
            .dropDestination(for: Data.self) { items, _ in
                items.forEach(add)
                return !items.isEmpty
            }
            .photosPicker(isPresented: $choosingPhotos, selection: $picks, maxSelectionCount: 100, matching: .images)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image], allowsMultipleSelection: true) { r in
                guard case .success(let urls) = r else { return }
                lastSource = .files
                for url in urls {
                    let ok = url.startAccessingSecurityScopedResource()
                    defer { if ok { url.stopAccessingSecurityScopedResource() } }
                    if let d = try? Data(contentsOf: url) { add(d) }
                }
            }
            .onChange(of: picks) { _, list in
                guard !list.isEmpty else { return }
                lastSource = .photos
                Task {
                    for p in list { if let d = try? await p.loadTransferable(type: Data.self) { add(d) } }
                    picks = []
                }
            }
            .onChange(of: app.photosForBatch, initial: true) { _, list in
                guard !list.isEmpty else { return }
                app.photosForBatch = []
                lastSource = .iPhone
                list.forEach(add)
                rearmIPhone()
            }
            .onChange(of: showCamera) { _, on in
                Task { if on { await camera.start() } else { camera.stop() } }
            }
            .onDisappear { if showCamera { camera.stop() } }
            .task {
                model.onSure = { [ctx] item in
                    if let p = model.add(item, location: location, in: ctx) { app.didAdd(p) }
                    if model.isClear && !(lastSource == .iPhone && keepIPhoneOpen) { reopenSource() }
                }
            }
        }
    }

    var emptyText: String {
        #if os(macOS)
        "Take photos with your iPhone (⌘T) — its camera opens again after each one — or turn on the live camera, or drop in a pile of photos. Each one is read, identified and looked up at Digi-Key and Mouser; press Return to add it with everything filled in and go on to the next — when the queue is done, the camera opens again."
        #else
        "Turn on the camera and keep taking photos, or choose a pile of them. Each one is read, identified and looked up at Digi-Key and Mouser; tap Add to add it with everything filled in."
        #endif
    }

    var settings: some View {
        @Bindable var model = model
        return HStack(spacing: 16) {
            Picker("Location", selection: $locationID) {
                Text("None").tag("")
                ForEach(locations.sorted { $0.path < $1.path }) { l in Text(l.path).tag(l.uid) }
            }
            .fixedSize()
            Stepper("Quantity: \(model.defaultQty)", value: $model.defaultQty, in: 0...100_000).fixedSize()
            Toggle("Add sure matches without asking", isOn: $model.autoAdd).fixedSize()
                .help("When the number read on the part matches exactly one listing, add it straight away.")
            Spacer()
            let c = model.counts
            Text("\(c.queued) reading · \(c.ready) to check · \(c.added) added · \(c.skipped) skipped")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    var sources: some View {
        HStack {
            #if os(macOS)
            DeviceImportButton(title: "iPhone: Take Photo", handle: iPhone) { d in lastSource = .iPhone; add(d); rearmIPhone() }
                .fixedSize()
            Button("Take with iPhone") { lastSource = .iPhone; takeWithIPhone() }
                .keyboardShortcut("t", modifiers: .command)
                .hidden().frame(width: 0)
            Toggle("Keep the iPhone camera open", isOn: $keepIPhoneOpen).fixedSize()
                .help("After each photo arrives, Take Photo is chosen again so the iPhone's camera stays open.")
            #endif
            Toggle(isOn: $showCamera) { Label("Live camera", systemImage: "web.camera") }
                .toggleStyle(.button)
            Button { choosingPhotos = true } label: { Label("Photos", systemImage: "photo.on.rectangle") }
            Button { importing = true } label: { Label("Files", systemImage: "folder") }
            #if os(macOS)
            PasteButton(payloadType: Data.self) { items in lastSource = .paste; items.forEach(add) }
            #endif
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.bordered)
    }

    var noKeys: some View {
        HStack {
            Image(systemName: "key").foregroundStyle(.orange)
            Text("Digi-Key and Mouser keys aren’t set, so photos are matched against the built-in list only.")
            Spacer()
            #if os(macOS)
            SettingsLink { Text("Settings…") }
            #else
            Button("Settings") { app.tab = .settings }
            #endif
        }
        .font(.callout)
        .padding(10)
        .background(.orange.opacity(0.1), in: .rect(cornerRadius: 10))
    }

    var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(model.items) { item in
                        BatchThumb(item: item, selected: item.id == model.selection)
                            .id(item.id)
                            .onTapGesture { model.selection = item.id }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 112)
            .onChange(of: model.selection) { _, id in withAnimation { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    func add(_ data: Data) {
        let ctx = ctx
        model.enqueue(data, inventory: { Inventory.allParts(ctx).map(\.inventoryRef) }, lookWhen: lookWhen, useAI: useAI)
    }

    /// After Add or Skip: when nothing is left to check, open the photo source again — shoot, Return, shoot.
    func afterDecision() {
        guard model.isClear else { return }
        // With "Keep the iPhone camera open", it was opened again as soon as the photo arrived.
        if lastSource == .iPhone && keepIPhoneOpen { return }
        reopenSource()
    }

    func reopenSource() {
        switch lastSource {
        case .iPhone: takeWithIPhone()
        case .camera: if !showCamera { showCamera = true }
        case .photos: choosingPhotos = true
        case .files: importing = true
        case .paste: break
        }
    }

    func takeWithIPhone() {
        #if os(macOS)
        if !DeviceImportView.takePhoto() { iPhone.showMenu() }
        #endif
    }

    /// Choose Take Photo again so the iPhone's camera opens for the next part.
    func rearmIPhone() {
        #if os(macOS)
        guard keepIPhoneOpen, app.tab == .batch else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            DeviceImportView.takePhoto()
        }
        #endif
    }
}

/// Where batch photos come from.
enum BatchSource { case iPhone, camera, photos, files, paste }

/// A photo in the queue, with where it's got to.
struct BatchThumb: View {
    let item: BatchModel.Item
    let selected: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let t = item.thumb { Image(decorative: t, scale: 1).resizable().scaledToFill() } else { Color.gray.opacity(0.2) }
                }
                .frame(width: 96, height: 72)
                .clipShape(.rect(cornerRadius: 8))
                .opacity(item.status.isDone ? 0.45 : 1)
                badge.padding(4)
            }
            Text(item.status.isBusy ? item.status.title : item.title)
                .font(.caption2).lineLimit(1).frame(width: 96)
                .foregroundStyle(item.status.isBusy ? .secondary : .primary)
        }
        .padding(4)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.status.title)")
    }

    @ViewBuilder var badge: some View {
        switch item.status {
        case .waiting, .reading, .lookingUp: ProgressView().controlSize(.small)
        case .ready: Image(systemName: item.sure ? "checkmark.seal.fill" : "questionmark.circle.fill").foregroundStyle(item.sure ? .green : .blue)
        case .needsNumber: Image(systemName: "number.circle.fill").foregroundStyle(.orange)
        case .added: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

/// The item being checked: the photo, the best listing (or others to choose from), the number to search for,
/// the quantity — and Add (Return) or Skip (⌘⌫).
struct BatchReviewCard: View {
    @Bindable var item: BatchModel.Item
    let model: BatchModel
    let location: StorageLocation?
    /// After Add or Skip (Batch opens the camera again when the queue is done).
    var afterDecision: () -> Void = {}
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var ctx

    var existing: Part? { BatchModel.existing(item, in: ctx) }
    var canAdd: Bool {
        (item.status == .ready || item.status == .needsNumber) && (item.choice != nil || item.label?.hasPart == true || item.fallback != nil)
    }
    var addTitle: String {
        if let p = existing { return "Add \(item.qty) to stock (have \(p.qty)) & next" }
        return "Add & next"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                if let img = item.image {
                    Image(decorative: img, scale: 1).resizable().scaledToFit()
                        .frame(maxWidth: 360, maxHeight: 280).clipShape(.rect(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 8) {
                    status
                    if let p = item.choice { listing(p) } else if let l = item.label, l.hasPart { labelSummary(l) } else if let c = item.fallback { fallbackSummary(c) }
                    ForEach(item.errors.sorted { $0.key < $1.key }, id: \.key) { id, e in
                        Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                            .accessibilityLabel("\(Supplier.named(id)?.name ?? id): \(e)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if item.results.count > 1 {
                Picker("Listing", selection: Binding(get: { item.chosen ?? item.results.first?.id ?? "" }, set: { item.chosen = $0 })) {
                    ForEach(item.results) { p in
                        Text("\(p.mpn) — \(p.manufacturer) · \(p.supplierName)\(p.stock.map { " · \($0.formatted()) in stock" } ?? "")").tag(p.id)
                    }
                }
            }
            HStack {
                TextField("Part number to look up", text: $item.query)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit { model.searchAgain(item) }
                Button("Search again") { model.searchAgain(item) }
                    .disabled(item.query.trimmingCharacters(in: .whitespaces).isEmpty || item.status.isBusy || item.status.isDone)
            }
            HStack {
                Stepper("Quantity: \(item.qty)", value: $item.qty, in: 0...1_000_000)
                Spacer()
                Button { model.move(-1) } label: { Image(systemName: "chevron.up") }
                    .keyboardShortcut(.upArrow, modifiers: .command).help("Previous (⌘↑)")
                Button { model.move(1) } label: { Image(systemName: "chevron.down") }
                    .keyboardShortcut(.downArrow, modifiers: .command).help("Next (⌘↓)")
                if item.status == .added {
                    Button("Show part") { if let id = item.partID { app.partToShow = id; app.tab = .parts } }
                } else {
                    Button("Skip") { model.skip(item); afterDecision() }
                        .keyboardShortcut(.delete, modifiers: .command)
                        .disabled(item.status.isDone)
                    Button(addTitle) {
                        if let p = model.add(item, location: location, in: ctx) { app.didAdd(p) }
                        afterDecision()
                    }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canAdd)
                }
            }
            if !item.markings.isEmpty {
                DisclosureGroup("Markings read") { Text(item.markings).font(.callout.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }
        .padding()
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }

    @ViewBuilder var status: some View {
        switch item.status {
        case .waiting, .reading, .lookingUp:
            HStack { ProgressView().controlSize(.small); Text(item.status == .lookingUp ? "Looking up \(item.query) at \(suppliers)…" : "Reading the markings…").foregroundStyle(.secondary) }
        case .ready:
            if item.sure { Label("Sure match — the number on the part matches this listing", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
            else if item.choice != nil { Label("Check this is the part", systemImage: "questionmark.circle").foregroundStyle(.blue) }
            else { Label("Not found online — from the built-in list", systemImage: "questionmark.circle").foregroundStyle(.blue) }
        case .needsNumber:
            Label("No part number found — type one below and search", systemImage: "number.circle").foregroundStyle(.orange)
        case .added:
            Label(item.note.isEmpty ? "Added" : item.note, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped:
            Label("Skipped", systemImage: "xmark.circle").foregroundStyle(.secondary)
        case .failed(let e):
            Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }

    var suppliers: String {
        let k = SupplierKeys.shared
        return [k.digikeyID.isEmpty ? nil : "Digi-Key", k.mouserKey.isEmpty ? nil : "Mouser"].compactMap { $0 }.joined(separator: " and ")
    }

    func listing(_ p: SupplierProduct) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(p.mpn).font(.title3.bold())
            Text([p.manufacturer, p.normalisedPackage].filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(.secondary)
            if !p.description.isEmpty { Text(p.description).font(.callout) }
            supplierLine(p)
            if let o = item.partner { supplierLine(o) }
            if let url = URL(string: p.datasheet), !p.datasheet.isEmpty {
                Link(destination: url) { Label("Datasheet", systemImage: "doc.text") }.font(.callout)
            } else if let o = item.partner, let url = URL(string: o.datasheet), !o.datasheet.isEmpty {
                Link(destination: url) { Label("Datasheet", systemImage: "doc.text") }.font(.callout)
            }
        }
    }

    func supplierLine(_ p: SupplierProduct) -> some View {
        let prices = [1, 10, 100].compactMap { q in p.unitPrice(for: q).map { "\(q)+ \($0.unit.formatted(.currency(code: $0.currency)))" } }
        let removeDupes = prices.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return HStack(spacing: 6) {
            Text(p.supplierName).font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                .background(.tint.opacity(0.15), in: .capsule)
            Text(p.spn).font(.caption.monospaced())
            Text(p.stock.map { "\($0.formatted()) in stock" } ?? "stock unknown").font(.caption).foregroundStyle((p.stock ?? 0) > 0 ? .green : .orange)
            Text(removeDupes.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            if let url = URL(string: p.url), !p.url.isEmpty { Link(destination: url) { Image(systemName: "arrow.up.right.square") }.help("Open at \(p.supplierName)") }
        }
    }

    func labelSummary(_ l: BagLabel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(l.mpn.isEmpty ? l.spn : l.mpn).font(.title3.bold())
            Text(["Bag label", Supplier.named(l.supplier ?? "")?.name, l.qty.map { "\($0) in the bag" }].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
        }
    }

    func fallbackSummary(_ c: Candidate) -> some View {
        let d = Identify.draft(c)
        return VStack(alignment: .leading, spacing: 4) {
            Text(d.mpn.isEmpty ? "Unknown part" : d.mpn).font(.title3.bold())
            Text([d.manufacturer, d.description].filter { !$0.isEmpty }.joined(separator: " — ")).foregroundStyle(.secondary)
            Text("\(Int(c.score * 100))% · \(c.confidence)").font(.caption).foregroundStyle(.secondary)
        }
    }
}
