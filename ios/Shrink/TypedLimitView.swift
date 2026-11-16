import SwiftUI

/// "Type the size limit": for a form or site that states its own (Google Forms lets each form owner pick).
struct TypedLimitView: View {
    let onContinue: (TypedLimit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var unit: TypedLimit.Unit = .mb
    @FocusState private var focused: Bool

    private var limit: TypedLimit? { TypedLimit(text: text, unit: unit) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("The form or site says how big a file can be, like \u{201C}Max file size: 10 MB\u{201D}. Type that limit.")
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    TextField("10", text: $text)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .focused($focused)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("Size limit")
                    Picker("Unit", selection: $unit) {
                        ForEach(TypedLimit.Unit.allCases) { unit in
                            Text(unit.rawValue).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }

                if !text.isEmpty, limit == nil {
                    Text("Type a limit between 10 KB and 4 GB.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Spacer()

                Button {
                    guard let limit else { return }
                    dismiss()
                    onContinue(limit)
                } label: {
                    Text("Choose the video or photo")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(limit == nil)
            }
            .padding(20)
            .navigationTitle("Type the size limit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }
}
