import PartsKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Settings › API & MCP: switch the server on, see where it listens, and copy what other tools need.
struct APISettingsSection: View {
    @State private var service = APIService.shared
    @State private var portText = ""
    @State private var showToken = false
    @State private var confirmRegenerate = false
    @State private var copied = ""

    var body: some View {
        Section {
            Toggle("Enable API and MCP server", isOn: $service.enabled)
            LabeledContent("Status") {
                Text(service.statusText).foregroundStyle(isFailed ? .orange : .secondary).multilineTextAlignment(.trailing)
            }
            HStack {
                TextField("Port", text: $portText)
                    .onSubmit(applyPort)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                if Int(portText) != service.port { Button("Use port", action: applyPort).disabled(Int(portText).map { !(1024...65535).contains($0) } ?? true) }
            }
            Toggle("Allow other devices on my network", isOn: $service.allInterfaces)
            if service.enabled {
                LabeledContent("Address") { copyable(service.baseURL, label: "address") }
                LabeledContent("Token") {
                    HStack {
                        Text(showToken ? service.token : String(repeating: "•", count: 16)).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1)
                        Button(showToken ? "Hide" : "Show") { showToken.toggle() }.buttonStyle(.borderless)
                        Button("Copy") { copy(service.token, "token") }.buttonStyle(.borderless)
                    }
                }
                Button("Make a new token…", role: .destructive) { confirmRegenerate = true }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connect Claude Code").font(.callout.weight(.semibold))
                    command(service.claudeCommand, "Claude Code command")
                    Text("Try the REST API").font(.callout.weight(.semibold)).padding(.top, 4)
                    command(service.curlExample, "curl example")
                }
                if !copied.isEmpty { Text("Copied the \(copied).").font(.caption).foregroundStyle(.secondary) }
            }
        } header: { Text("API & MCP") } footer: {
            Text(footer)
        }
        .onAppear { portText = String(service.port); if service.enabled { _ = service.ensureToken() } }
        .onChange(of: service.enabled) { _, on in if on { _ = service.ensureToken() } }
        .confirmationDialog("Make a new token?", isPresented: $confirmRegenerate) {
            Button("Make a new token", role: .destructive) { service.regenerateToken(); copied = "" }
        } message: {
            Text("Tools using the old token (Claude Code, scripts) stop working until you give them the new one.")
        }
    }

    var isFailed: Bool { if case .failed = service.state { return true }; return false }

    var footer: String {
        var s = "Other tools can read and change the inventory while the app runs: a REST API under /api (described at /api/openapi.json) and an MCP server at /mcp for Claude Code and other assistants. Every request needs the token. "
        s += service.allInterfaces ? "Devices on your network can reach it — keep the token private." : "Only programs on this device can reach it."
        #if os(iOS)
        s += " On iPhone and iPad it only answers while the app is open."
        #endif
        return s
    }

    func applyPort() {
        guard let p = Int(portText), (1024...65535).contains(p) else { portText = String(service.port); return }
        service.port = p
        service.restart()
    }

    func copyable(_ text: String, label: String) -> some View {
        HStack {
            Text(text).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1)
            Button("Copy") { copy(text, label) }.buttonStyle(.borderless)
        }
    }

    func command(_ text: String, _ label: String) -> some View {
        HStack(alignment: .top) {
            Text(showToken ? text : text.replacingOccurrences(of: service.token, with: "<token>"))
                .font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button("Copy") { copy(text, label) }.buttonStyle(.borderless)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
    }

    func copy(_ text: String, _ label: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        copied = label
    }
}
