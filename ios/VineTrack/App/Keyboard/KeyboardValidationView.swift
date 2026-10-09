#if DEBUG
import SwiftUI
import UIKit

/// Isolated UI-test fixture; reachable only with an explicit launch argument, never account data.
struct KeyboardValidationView: View {
    @State private var showsSheet: Bool = false
    @State private var showsFullScreen: Bool = false

    var body: some View {
        NavigationStack {
            KeyboardValidationInputs(container: .scroll, prefix: "")
                .navigationTitle("Keyboard validation")
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        NavigationLink("List", value: "list")
                        Button("Sheet") { showsSheet = true }
                        Button("Full screen") { showsFullScreen = true }
                    }
                }
                .navigationDestination(for: String.self) { _ in KeyboardValidationInputs(container: .list, prefix: "list.") }
        }
        .environment(\.dynamicTypeSize, CommandLine.arguments.contains("--keyboard-large-text") ? .accessibility2 : .large)
        .sheet(isPresented: $showsSheet) {
            NavigationStack { KeyboardValidationInputs(container: .form, prefix: "sheet.") }
                .presentationDetents([.medium, .large])
                .presentationContentInteraction(.scrolls)
        }
        .fullScreenCover(isPresented: $showsFullScreen) {
            NavigationStack { KeyboardValidationInputs(container: .scroll, prefix: "full.") }
        }
    }
}

private struct KeyboardValidationInputs: View {
    enum Container { case scroll, list, form }
    let container: Container
    let prefix: String
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var number: String = ""
    @State private var decimal: String = ""
    @State private var email: String = ""
    @State private var url: String = ""
    @State private var phone: String = ""
    @State private var search: String = ""
    @State private var password: String = ""
    @State private var multiline: String = ""
    @State private var editor: String = ""
    @State private var native: String = ""
    @State private var formattedNumber: Double = 12.5
    @State private var showsAlert: Bool = false
    @State private var alertDraft: String = ""
    @State private var submits: Int = 0
    @State private var saves: Int = 0
    @State private var toggle: Bool = false

    var body: some View {
        Group {
            switch container {
            case .scroll:
                ScrollView { VStack(alignment: .leading, spacing: 18) { fields }.padding() }
            case .list:
                List { fields }.searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Native search")
            case .form:
                Form { fields }
            }
        }
        .onSubmit { submits += 1 }
        .alert("Keyboard popup", isPresented: $showsAlert) {
            TextField("Popup draft", text: $alertDraft).accessibilityIdentifier("input.alert")
            Button("Cancel", role: .cancel) {}
            Button("Confirm") { saves += 1 }
        }
        .toolbar {
            if !prefix.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }.accessibilityIdentifier("keyboard.\(prefix)close")
                }
            }
        }
    }

    private var fields: some View {
        Group {
            Text("Passive background").frame(maxWidth: .infinity, minHeight: 60).accessibilityIdentifier("keyboard.background")
            Text("Submits: \(submits); Saves: \(saves)").accessibilityIdentifier("keyboard.counters")
            Button("Alert input") { showsAlert = true }.accessibilityIdentifier("keyboard.alert")
            TextField("Text", text: $text).accessibilityIdentifier("input.\(prefix)text")
            TextField("Number", text: $number).keyboardType(.numberPad).accessibilityIdentifier("input.\(prefix)number")
            TextField("Decimal", text: $decimal).keyboardType(.decimalPad).accessibilityIdentifier("input.\(prefix)decimal")
            TextField("Email", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never).accessibilityIdentifier("input.\(prefix)email")
            TextField("URL", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).accessibilityIdentifier("input.\(prefix)url")
            TextField("Phone", text: $phone).keyboardType(.phonePad).accessibilityIdentifier("input.\(prefix)phone")
            TextField("Search", text: $search).submitLabel(.search).accessibilityIdentifier("input.\(prefix)search")
            SecureField("Password", text: $password).accessibilityIdentifier("input.\(prefix)password")
            TextField("Multiline", text: $multiline, axis: .vertical).lineLimit(2...4).accessibilityIdentifier("input.\(prefix)multiline")
            TextEditor(text: $editor).frame(height: 120).accessibilityIdentifier("input.\(prefix)editor")
            KeyboardValidationNativeInput(text: $native, identifier: "input.\(prefix)native").frame(height: 44)
            TextField("Formatted number", value: $formattedNumber, format: .number).keyboardType(.decimalPad).accessibilityIdentifier("input.\(prefix)formatted")
            Toggle("Keep control interactions", isOn: $toggle).accessibilityIdentifier("keyboard.toggle")
            Button("Save counter") { saves += 1 }.accessibilityIdentifier("keyboard.save")
            Text("Bottom of form").frame(height: 100)
            TextField("Bottom field", text: $text).accessibilityIdentifier("input.\(prefix)bottom")
        }
    }
}

private struct KeyboardValidationNativeInput: UIViewRepresentable {
    @Binding var text: String
    let identifier: String
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = "Native field"
        field.accessibilityIdentifier = identifier
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed), for: .editingChanged)
        return field
    }
    func updateUIView(_ uiView: UITextField, context: Context) { uiView.text = text; context.coordinator.parent = self }
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    final class Coordinator: NSObject {
        var parent: KeyboardValidationNativeInput
        init(parent: KeyboardValidationNativeInput) { self.parent = parent }
        @objc func changed(_ sender: UITextField) { parent.text = sender.text ?? "" }
    }
}
#endif
