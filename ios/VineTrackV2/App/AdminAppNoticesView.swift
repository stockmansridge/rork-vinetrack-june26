import SwiftUI

/// Settings -> Admin -> App Notices.
/// Lets a super-admin create, edit, activate/deactivate and archive
/// (soft-delete) app-wide notices that appear as banners on Home.
struct AdminAppNoticesView: View {
    @Environment(AppNoticeService.self) private var service
    @State private var editing: BackendAppNotice?
    @State private var isCreatingNew: Bool = false
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }

            if active.isEmpty && archived.isEmpty && !isLoading {
                Section {
                    Text("No notices yet. Tap + to create the first one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if !active.isEmpty {
                Section("Active") {
                    ForEach(active) { notice in
                        row(for: notice)
                    }
                }
            }

            if !archived.isEmpty {
                Section("Archived / Inactive") {
                    ForEach(archived) { notice in
                        row(for: notice)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("App Notices")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isCreatingNew = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .overlay { if isLoading && service.allNotices.isEmpty { ProgressView() } }
        .task { await reload() }
        .refreshable { await reload() }
        .sheet(item: $editing) { notice in
            AdminAppNoticeEditSheet(initial: notice) {
                await reload()
            }
        }
        .sheet(isPresented: $isCreatingNew) {
            AdminAppNoticeEditSheet(initial: nil) {
                await reload()
            }
        }
    }

    private var active: [BackendAppNotice] {
        service.allNotices.filter { $0.isActive && $0.deletedAt == nil }
    }

    private var archived: [BackendAppNotice] {
        service.allNotices.filter { !$0.isActive || $0.deletedAt != nil }
    }

    @ViewBuilder
    private func row(for notice: BackendAppNotice) -> some View {
        Button {
            editing = notice
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    typeBadge(notice.typedNoticeType)
                    Text(notice.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if notice.deletedAt != nil {
                        Text("ARCHIVED")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    } else if !notice.isActive {
                        Text("OFF")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(notice.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Label("\(notice.priority)", systemImage: "number")
                    if let d = notice.createdAt {
                        Text(d, format: .dateTime.month(.abbreviated).day().year())
                    }
                    if let starts = notice.startsAt {
                        Label("from \(starts, format: .dateTime.month(.abbreviated).day())", systemImage: "calendar")
                    }
                    if let ends = notice.endsAt {
                        Label("to \(ends, format: .dateTime.month(.abbreviated).day())", systemImage: "calendar.badge.clock")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if notice.deletedAt == nil {
                Button(role: .destructive) {
                    Task {
                        try? await service.softDelete(id: notice.id)
                    }
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
            }
        }
    }

    private func typeBadge(_ type: AppNoticeType) -> some View {
        Text(type.displayName.uppercased())
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color(for: type).opacity(0.15), in: Capsule())
            .foregroundStyle(color(for: type))
    }

    private func color(for type: AppNoticeType) -> Color {
        switch type {
        case .info: .blue
        case .warning: .orange
        case .success: .green
        case .critical: .red
        }
    }

    @MainActor
    private func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        await service.refreshAll()
        await service.refresh()
        if case let .failure(msg) = service.status {
            errorMessage = msg
        }
    }
}

// MARK: - Edit sheet

struct AdminAppNoticeEditSheet: View {
    let initial: BackendAppNotice?
    let onSaved: @MainActor () async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppNoticeService.self) private var service

    @State private var title: String = ""
    @State private var message: String = ""
    @State private var type: AppNoticeType = .info
    @State private var priority: Int = 0
    @State private var isActive: Bool = true
    @State private var useStartsAt: Bool = false
    @State private var startsAt: Date = Date()
    @State private var useEndsAt: Bool = false
    @State private var endsAt: Date = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var saving: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Content") {
                    TextField("Title", text: $title)
                    TextField("Message", text: $message, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section("Style") {
                    Picker("Type", selection: $type) {
                        ForEach(AppNoticeType.allCases, id: \.self) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                    Stepper(value: $priority, in: 0...100) {
                        HStack {
                            Text("Priority")
                            Spacer()
                            Text("\(priority)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }

                Section {
                    Toggle("Active", isOn: $isActive)
                    Toggle("Schedule start", isOn: $useStartsAt)
                    if useStartsAt {
                        DatePicker("Starts", selection: $startsAt, displayedComponents: [.date, .hourAndMinute])
                    }
                    Toggle("Schedule end", isOn: $useEndsAt)
                    if useEndsAt {
                        DatePicker("Ends", selection: $endsAt, displayedComponents: [.date, .hourAndMinute])
                    }
                } header: {
                    Text("Visibility")
                } footer: {
                    Text("Schedules are optional. If both are empty the notice shows immediately and stays visible until you deactivate or archive it.")
                }

                if initial != nil {
                    Section {
                        Button(role: .destructive) {
                            archive()
                        } label: {
                            Label("Archive notice", systemImage: "archivebox")
                        }
                    } footer: {
                        Text("Archiving hides the notice for everyone. Once a user dismisses a notice locally it stays hidden for them even if you edit it later — create a new notice to re-show.")
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle(initial == nil ? "New Notice" : "Edit Notice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { save() }
                        .disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty || message.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: hydrate)
        }
    }

    private func hydrate() {
        guard let initial else { return }
        title = initial.title
        message = initial.message
        type = initial.typedNoticeType
        priority = initial.priority
        isActive = initial.isActive
        if let s = initial.startsAt { useStartsAt = true; startsAt = s }
        if let e = initial.endsAt { useEndsAt = true; endsAt = e }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedMessage.isEmpty else { return }
        saving = true
        errorMessage = nil
        Task {
            defer { saving = false }
            let id = initial?.id ?? UUID()
            let notice = BackendAppNotice(
                id: id,
                title: trimmedTitle,
                message: trimmedMessage,
                noticeType: type.rawValue,
                priority: priority,
                startsAt: useStartsAt ? startsAt : nil,
                endsAt: useEndsAt ? endsAt : nil,
                isActive: isActive,
                createdBy: initial?.createdBy,
                updatedBy: nil,
                createdAt: initial?.createdAt,
                updatedAt: nil,
                deletedAt: initial?.deletedAt,
                clientUpdatedAt: Date(),
                syncVersion: initial?.syncVersion
            )
            do {
                try await service.upsert(notice)
                await onSaved()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func archive() {
        guard let id = initial?.id else { return }
        saving = true
        errorMessage = nil
        Task {
            defer { saving = false }
            do {
                try await service.softDelete(id: id)
                await onSaved()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
