import SwiftUI

/// The selected targets, as individually removable chips.
///
/// One chip per target, each with its own ×, because the thing an operator
/// wants to do is remove ONE target — and the previous free-text box made that
/// an exercise in deleting the right words and fixing up the separators either
/// side. Wrapping is done with a flexible grid rather than a horizontal scroll
/// so a step with five targets shows all five instead of hiding two off-screen.
struct SprayTargetChipsView: View {
    let tags: [SprayTargetTag]
    let onRemove: (SprayTargetTag) -> Void

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 140), spacing: 8, alignment: .leading)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(tags) { tag in
                chip(tag)
            }
        }
    }

    private func chip(_ tag: SprayTargetTag) -> some View {
        HStack(spacing: 6) {
            Text(tag.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(VineyardTheme.olive)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Button {
                onRemove(tag)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(VineyardTheme.olive.opacity(0.8))
                    // A chip is small; the tap area must not be.
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(tag.label)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .padding(.vertical, 5)
        .background(VineyardTheme.olive.opacity(0.12), in: Capsule())
    }
}

/// Picks the targets a Program Step is for.
///
/// One list, two origins. The operator should never have to know whether
/// "Powdery Mildew" is a compiled `SprayTarget` and "Eutypa Dieback" is a row
/// their vineyard created — both are targets, both are tapped the same way, and
/// both come back as tags. The grouping is a hint about where a word came from,
/// not a decision the operator has to make.
///
/// Adding a custom target is a first-class action rather than a fallback,
/// because the alternative an operator reaches for otherwise is the generic
/// "Other", which throws away the one thing that mattered: which disease.
struct SprayTargetChooserSheet: View {
    /// Already on the step, so they read as selected and cannot be added twice.
    let selected: [SprayTargetTag]
    /// This vineyard's own targets: library rows plus anything already used on
    /// its Program Steps.
    let vineyardTargets: [SprayTargetTag]
    /// Called for every tag the operator chose. Custom wording arrives here
    /// already slugged and de-duplicated.
    let onSelect: (SprayTargetTag) -> Void
    /// Called with fresh wording that should also join the vineyard's library.
    let onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var isAddingCustom: Bool = false
    @State private var customWording: String = ""

    private var selectedIdentifiers: Set<String> {
        Set(selected.map(\.identifier))
    }

    private var commonMatches: [SprayTargetTag] {
        filtered(SprayTarget.presentationOrder.map(SprayTargetTag.init))
    }

    private var vineyardMatches: [SprayTargetTag] {
        // A vineyard entry that duplicates a built-in is never shown twice.
        let builtInIdentifiers = Set(SprayTarget.allCases.map(\.rawValue))
        return filtered(vineyardTargets.filter { !builtInIdentifiers.contains($0.identifier) })
    }

    private func filtered(_ tags: [SprayTargetTag]) -> [SprayTargetTag] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return tags }
        return tags.filter { $0.label.localizedStandardContains(trimmed) }
    }

    /// The typed search text, offered as a new target when nothing matches it.
    ///
    /// Typing the name is how an operator looks for a target, so it is also the
    /// most direct way to add one — but only when it is genuinely new, so this
    /// never sits above an exact match the operator should have tapped instead.
    private var creatableFromQuery: String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, let tag = SprayTargetVocabulary.tag(wording: trimmed) else { return nil }
        let known = Set(SprayTarget.allCases.map(\.rawValue))
            .union(vineyardTargets.map(\.identifier))
            .union(selectedIdentifiers)
        return known.contains(tag.identifier) ? nil : trimmed
    }

    var body: some View {
        NavigationStack {
            List {
                if !commonMatches.isEmpty {
                    Section("Common Targets") {
                        ForEach(commonMatches) { tag in
                            row(tag)
                        }
                    }
                }

                if !vineyardMatches.isEmpty {
                    Section {
                        ForEach(vineyardMatches) { tag in
                            row(tag)
                        }
                    } header: {
                        Text("This Vineyard")
                    } footer: {
                        Text("Targets this vineyard has used before. They stay available here even when no Program Step is using them.")
                    }
                }

                Section {
                    if let wording = creatableFromQuery {
                        Button {
                            add(custom: wording)
                        } label: {
                            Label("Add \u{201C}\(wording)\u{201D}", systemImage: "plus.circle.fill")
                        }
                    }
                    Button {
                        customWording = query.trimmingCharacters(in: .whitespacesAndNewlines)
                        isAddingCustom = true
                    } label: {
                        Label("Add Custom Target", systemImage: "text.badge.plus")
                    }
                } footer: {
                    Text("Name the actual target \u{2014} Eutypa Dieback, Phomopsis, Black Spot, Light Brown Apple Moth. It's saved for this vineyard and offered on every Program Step here.")
                }

                if commonMatches.isEmpty && vineyardMatches.isEmpty && creatableFromQuery == nil {
                    Section {
                        ContentUnavailableView(
                            "No matches",
                            systemImage: "scope",
                            description: Text("No target matches that search.")
                        )
                    }
                }
            }
            .searchable(text: $query, prompt: "Search targets")
            .navigationTitle("Add Target")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Add Custom Target", isPresented: $isAddingCustom) {
                TextField("e.g. Eutypa Dieback", text: $customWording)
                    .textInputAutocapitalization(.words)
                Button("Cancel", role: .cancel) { customWording = "" }
                Button("Add") { add(custom: customWording) }
                    .disabled(SprayTargetVocabulary.tag(wording: customWording) == nil)
            } message: {
                Text("Use the wording your vineyard uses. It's added to this Program Step and saved for the vineyard.")
            }
        }
    }

    @ViewBuilder
    private func row(_ tag: SprayTargetTag) -> some View {
        let isSelected = selectedIdentifiers.contains(tag.identifier)
        Button {
            onSelect(tag)
            dismiss()
        } label: {
            HStack {
                if let builtIn = tag.builtIn {
                    Image(systemName: builtIn.iconName)
                        .foregroundStyle(VineyardTheme.olive)
                        .frame(width: 22)
                } else {
                    Image(systemName: "scope")
                        .foregroundStyle(VineyardTheme.olive)
                        .frame(width: 22)
                }
                Text(tag.label)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(VineyardTheme.success)
                }
            }
        }
        .disabled(isSelected)
    }

    /// Trim, reject empty, de-duplicate — the rules live in
    /// `SprayTargetVocabulary` so the chooser, the draft and the library cannot
    /// disagree about what counts as the same target.
    private func add(custom wording: String) {
        guard let tag = SprayTargetVocabulary.tag(wording: wording) else { return }
        customWording = ""
        if tag.isCustom {
            onCreate(tag.label)
        } else {
            // The operator typed the name of a target VineTrack already has.
            // It becomes that built-in rather than a vineyard duplicate the
            // calculator would then fail to recognise.
            onSelect(tag)
        }
        dismiss()
    }
}
