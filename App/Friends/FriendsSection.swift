import PartsKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Friends' inventories: the friends whose published inventories show in the table, how each
/// fetch went, and adding one.
struct FriendsSection: View {
    /// Off in the sheet, whose title says it already.
    var showsHeader = true
    private let store = FriendsStore.shared
    @State private var adding = false

    var body: some View {
        Section {
            ForEach(store.friends) { f in FriendRow(friend: f, status: store.status[f.id]) }
            HStack {
                Button { adding = true } label: { Label("Add a friend…", systemImage: "person.badge.plus") }
                Spacer()
                if store.hasFriends {
                    Button("Refresh all") { Task { await store.refreshAll() } }
                        .disabled(store.status.values.contains { $0.loading })
                }
            }
        } header: { if showsHeader { Text("Friends’ inventories") } } footer: {
            Text("A friend’s published inventory — a GitHub repository or web address with inventory.json, or a folder on this device — shows in the Table beside yours, read-only. A copy is kept so it works offline; it’s fetched again when the Table opens and the copy is over an hour old.")
        }
        .sheet(isPresented: $adding) { AddFriendSheet() }
    }
}

private struct FriendRow: View {
    let friend: Friend
    let status: FriendsStore.Status?
    @State private var confirmingRemove = false
    @State private var renaming = false
    @State private var newName = ""
    private let store = FriendsStore.shared

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(friend.name).font(.headline)
                Text(friend.whereLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                statusText.font(.caption)
            }
            Spacer()
            if status?.loading == true {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await store.refresh(friend) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Fetch \(friend.name)’s inventory again").accessibilityLabel("Refresh \(friend.name)")
            }
            Menu {
                Button("Rename…") { newName = friend.name; renaming = true }
                Button("Remove…", role: .destructive) { confirmingRemove = true }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuIndicator(.hidden).fixedSize().buttonStyle(.borderless).accessibilityLabel("More for \(friend.name)")
        }
        .confirmationDialog("Remove \(friend.name)’s inventory?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) { store.remove(friend) }
        } message: { Text("Their parts leave the Table. Nothing of theirs is changed.") }
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let n = try? store.uniqueName(newName, except: friend.id) { var f = friend; f.name = n; store.update(f) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder var statusText: some View {
        if let e = status?.error {
            VStack(alignment: .leading, spacing: 1) {
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                if let t = status?.fetched { Text("Showing the copy from \(t, format: .relative(presentation: .named)).").foregroundStyle(.secondary) }
            }
        } else if let s = status, let t = s.fetched {
            Text("\(s.parts) parts · updated \(t, format: .relative(presentation: .named))").foregroundStyle(.secondary)
        } else if status?.loading == true {
            Text("Fetching…").foregroundStyle(.secondary)
        }
    }
}

/// Add a friend: a name, and a web address or a folder.
struct AddFriendSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var useFolder = false
    @State private var address = ""
    @State private var folder: URL?
    @State private var choosingFolder = false
    @State private var error: String?
    private let store = FriendsStore.shared

    var resolved: Result<URL, Error> { Result { try RemoteInventory.resolve(address) } }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name, prompt: Text("Sam"))
                Picker("Inventory", selection: $useFolder) {
                    Text("On the web").tag(false)
                    Text("A folder").tag(true)
                }
                .pickerStyle(.segmented)
                if useFolder {
                    LabeledContent("Folder") {
                        HStack {
                            Text(folder?.lastPathComponent ?? "None").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Button("Choose…") { choosingFolder = true }
                        }
                    }
                    Text("A folder with inventory.json in it — say a clone of their repository, or a shared folder.").font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("Address", text: $address, prompt: Text("https://github.com/sam/parts"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                        #endif
                    Group {
                        switch resolved {
                        case .success(let u) where !address.isEmpty: Text("Reads \(u.absoluteString)")
                        case .failure(let e) where !address.trimmingCharacters(in: .whitespaces).isEmpty: Text(e.localizedDescription).foregroundStyle(.orange)
                        default: Text("A GitHub repository (or a folder in one), or any web address of an inventory.json.")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            .formStyle(.grouped)
            .navigationTitle("Add a friend’s inventory")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (useFolder ? folder == nil : address.isEmpty))
                }
            }
        }
        .frame(minWidth: 460, minHeight: 300)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { r in
            if case .success(let u) = r { folder = u; error = nil }
        }
    }

    func add() {
        do {
            if useFolder, let folder { try store.add(name: name, folder: folder) } else { try store.add(name: name, address: address) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// The friends list on its own, from the table.
struct FriendsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form { FriendsSection(showsHeader: false) }
                .formStyle(.grouped)
                .navigationTitle("Friends’ inventories")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 500, minHeight: 380)
    }
}
