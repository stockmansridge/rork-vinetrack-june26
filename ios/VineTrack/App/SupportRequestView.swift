import SwiftUI
import UIKit

/// In-app support / feedback / feature-request form. Submits to the VineTrack
/// support backend (`support_requests` + `support-request` edge function) so
/// the message is stored for the admin portal and emailed to the support inbox
/// — the user never has to open their own mail app.
struct SupportRequestView: View {
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var category: SupportRequestCategory = .general
    @State private var subject: String = ""
    @State private var message: String = ""
    @State private var name: String = ""
    @State private var email: String = ""
    @State private var attachments: [Data] = []

    @State private var isSubmitting: Bool = false
    @State private var showImagePicker: Bool = false
    @State private var result: SupportSubmissionResult?
    @State private var errorMessage: String?

    private let repository = SupabaseSupportRepository()
    private let maxAttachments = 5

    private var selectedVineyard: Vineyard? {
        store.vineyards.first { $0.id == store.selectedVineyardId }
    }

    private var canSubmit: Bool {
        !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSubmitting
    }

    var body: some View {
        Group {
            if let result {
                successView(result)
            } else {
                formView
            }
        }
        .navigationTitle("Contact Support")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showImagePicker) {
            CameraImagePicker { data in
                if let data, attachments.count < maxAttachments {
                    attachments.append(data)
                }
            }
        }
        .onAppear {
            if name.isEmpty { name = auth.userName ?? "" }
            if email.isEmpty { email = auth.userEmail ?? "" }
        }
    }

    // MARK: - Form

    private var formView: some View {
        Form {
            Section {
                Picker("Category", selection: $category) {
                    ForEach(SupportRequestCategory.allCases) { c in
                        Text(c.label).tag(c)
                    }
                }
                TextField("Subject", text: $subject)
                    .textInputAutocapitalization(.sentences)
            } header: {
                Text("What can we help with?")
            }

            Section("Details") {
                TextField(
                    "Describe your feedback, request or issue…",
                    text: $message,
                    axis: .vertical
                )
                .lineLimit(5...12)
            }

            attachmentsSection

            Section {
                TextField("Your name", text: $name)
                    .textContentType(.name)
                TextField("Your email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let vineyard = selectedVineyard {
                    LabeledContent("Vineyard", value: vineyard.name.isEmpty ? "—" : vineyard.name)
                }
            } header: {
                Text("Contact")
            } footer: {
                Text("We'll reply to this email. Your vineyard and app details are included to help us assist you faster.")
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        Spacer()
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("Send to Support")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(!canSubmit)
            } footer: {
                Text("\(AppBuildInfo.appName) \(AppBuildInfo.displayVersion) · \(AppBuildInfo.deviceModel) · iOS \(AppBuildInfo.iosVersion)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var attachmentsSection: some View {
        Section {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(attachments.enumerated()), id: \.offset) { index, data in
                            attachmentThumbnail(data: data, index: index)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            if attachments.count < maxAttachments {
                Button {
                    showImagePicker = true
                } label: {
                    Label("Add attachment", systemImage: "paperclip")
                }
            }
        } header: {
            Text("Attachments")
        } footer: {
            Text("Optional. Add up to \(maxAttachments) photos or screenshots.")
        }
    }

    private func attachmentThumbnail(data: Data, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            if let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 76, height: 76)
                    .clipShape(.rect(cornerRadius: 10))
            }
            Button {
                attachments.remove(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .padding(4)
        }
    }

    // MARK: - Success

    private func successView(_ result: SupportSubmissionResult) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Support request sent")
                .font(.title2.weight(.semibold))
            Text(successDetail(result))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button {
                dismiss()
            } label: {
                Text("Done")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func successDetail(_ result: SupportSubmissionResult) -> String {
        let base = "Your message has been saved and our team has been notified."
        switch result.emailStatus {
        case "sent":
            return base + " We'll be in touch via email soon."
        case "failed", "unconfigured", "unknown":
            return "Your message has been saved and our team will see it. We'll be in touch via email soon."
        default:
            return base
        }
    }

    // MARK: - Submit

    private func submit() async {
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let diagnostics = SupportDiagnostics(
                appPlatform: "iOS",
                appVersion: AppBuildInfo.version,
                appBuild: AppBuildInfo.buildNumber,
                deviceModel: AppBuildInfo.deviceModel,
                osVersion: AppBuildInfo.iosVersion
            )
            let outcome = try await repository.submit(
                category: category,
                subject: subject.trimmingCharacters(in: .whitespacesAndNewlines),
                message: message.trimmingCharacters(in: .whitespacesAndNewlines),
                submitterName: name,
                submitterEmail: email,
                vineyardId: selectedVineyard?.id,
                vineyardName: selectedVineyard?.name,
                attachments: attachments,
                diagnostics: diagnostics
            )
            result = outcome
        } catch {
            errorMessage = "Could not send your request: \(error.localizedDescription). Please check your connection and try again — your message has not been discarded."
        }
    }

}
