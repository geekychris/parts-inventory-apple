import FoundationModels
import SwiftData
import SwiftUI

/// Ask about your inventory in plain words. Apple Intelligence searches it on the device with the
/// app's own parametric search; nothing leaves the device.
struct AskView: View {
    @Query private var parts: [Part]
    @State private var question = ""
    @State private var turns: [(q: String, a: String)] = []
    @State private var busy = false
    @State private var assistant: InventoryAssistant?

    var body: some View {
        NavigationStack {
            VStack {
                if !AppleIntelligence.isAvailable {
                    ContentUnavailableView("Apple Intelligence", systemImage: "apple.intelligence", description: Text(AppleIntelligence.status))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if turns.isEmpty {
                                Text("Try: “Do I have a 3.3 V regulator?”, “Which 10k resistors are 0603?”, “What’s running low?”, “Where are my ESP32 boards?”")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(Array(turns.enumerated()), id: \.offset) { _, t in
                                Text(t.q).bold().frame(maxWidth: .infinity, alignment: .trailing)
                                Text(t.a).textSelection(.enabled)
                            }
                            if busy { ProgressView() }
                        }
                        .padding()
                    }
                    HStack {
                        TextField("Ask about your parts", text: $question).textFieldStyle(.roundedBorder).onSubmit(ask)
                        Button("Ask", action: ask).disabled(question.isEmpty || busy)
                        if !turns.isEmpty { Button("New") { turns = []; assistant = nil } }
                    }
                    .padding()
                }
            }
            .navigationTitle("Ask")
        }
    }

    func ask() {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        question = ""; busy = true
        if assistant == nil { assistant = InventoryAssistant(parts: parts) }
        Task {
            let a: String
            do { a = try await assistant!.ask(q) } catch { a = "Sorry — \(error.localizedDescription)" }
            turns.append((q, a)); busy = false
        }
    }
}
