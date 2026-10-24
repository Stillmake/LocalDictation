import SwiftUI

/// Edits the hotword list: an input field on top, the list below, each row removable.
struct HotwordsSheet: View {
    private var model: AppViewModel { .shared }

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Add Hotword", text: $draft, prompt: Text("Kubernetes, SwiftUI, 张三"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()

            Divider()

            if model.hotwords.isEmpty {
                ContentUnavailableView(
                    "No Hotwords",
                    systemImage: "text.badge.plus",
                    description: Text("Names and terms added here help the model spell them correctly.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.hotwords, id: \.self) { word in
                        HStack {
                            Text(word)
                            Spacer()
                            Button("Remove \(word)", systemImage: "xmark.circle.fill") {
                                model.hotwords.removeAll { $0 == word }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Remove")
                        }
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 380, height: 420)
    }

    /// Accepts several terms at once (comma or newline separated); skips case-insensitive duplicates.
    private func add() {
        for term in draft.split(whereSeparator: { ",，、\n".contains($0) }) {
            let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, !model.hotwords.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else { continue }
            model.hotwords.append(term)
        }
        draft = ""
    }
}
