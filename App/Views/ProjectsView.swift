import PartsKit
import SwiftData
import SwiftUI

/// Projects (bills of materials) against stock: what each line needs and what you have.
/// BOMs are imported and builds planned in the web version; they come here with the backup.
struct ProjectsView: View {
    @Query(sort: \Project.name) private var projects: [Project]
    @Query private var parts: [Part]
    @State private var selection: Project.ID?
    /// Always open with the list showing: a restored split can come back with it collapsed to nothing.
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(projects, selection: $selection) { pr in
                VStack(alignment: .leading) {
                    Text(pr.name).font(.headline)
                    Text("\(pr.lines.count) lines · \(Int(pr.boards)) board\(pr.boards == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                }
                .tag(pr.id)
            }
            .navigationTitle("Projects")
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
            .overlay {
                if projects.isEmpty {
                    ContentUnavailableView("No projects", systemImage: "list.bullet.clipboard",
                                           description: Text("Import a KiCad or supplier BOM in the web version, then import its backup in Settings."))
                }
            }
        } detail: {
            if let id = selection, let pr = projects.first(where: { $0.id == id }) {
                ProjectDetail(project: pr, parts: parts)
            } else {
                ContentUnavailableView("Choose a project", systemImage: "list.bullet.clipboard")
            }
        }
    }
}

struct ProjectDetail: View {
    @Bindable var project: Project
    let parts: [Part]

    struct Row: Identifiable {
        let id: Int; let line: Backup.Project.Line; let part: Part?; let need: Int
        var have: Int { part?.qty ?? 0 }
    }

    var rows: [Row] {
        project.lines.enumerated().map { i, ln in
            let need = ln.dnp ? 0 : Int((ln.qty * project.boards).rounded(.up))
            return Row(id: i, line: ln, part: match(ln), need: need)
        }
    }

    /// The line's part: linked, by part number, or by value and package.
    func match(_ ln: Backup.Project.Line) -> Part? { BOM.match(ln, in: parts) }

    var canBuild: Int {
        let lines = rows.filter { $0.line.qty > 0 && !$0.line.dnp }
        guard !lines.isEmpty else { return 0 }
        return lines.map { r in r.part.map { Int(Double($0.qty) / r.line.qty) } ?? 0 }.min() ?? 0
    }

    var body: some View {
        List {
            Section {
                Stepper("Boards: \(Int(project.boards))", value: $project.boards, in: 1...1000)
                LabeledContent("You have enough for", value: "\(canBuild) board\(canBuild == 1 ? "" : "s")")
            }
            Section("Lines") {
                ForEach(rows) { r in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(r.line.refs.joined(separator: " ")).font(.caption).foregroundStyle(.secondary)
                            Text([r.line.value, r.line.mpn, r.line.footprint].filter { !$0.isEmpty }.joined(separator: " · "))
                            if let p = r.part { Text("→ \(p.title)\(p.location.map { " in " + $0.path } ?? "")").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Text(r.line.dnp ? "DNP" : "\(r.have)/\(r.need)").monospacedDigit()
                            .foregroundStyle(r.line.dnp ? Color.secondary : r.have >= r.need ? Color.green : Color.red)
                    }
                }
            }
            if !project.notes.isEmpty { Section("Notes") { Text(project.notes) } }
        }
        .navigationTitle(project.name)
    }
}
