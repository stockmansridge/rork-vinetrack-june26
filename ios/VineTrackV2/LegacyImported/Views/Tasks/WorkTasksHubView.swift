import SwiftUI

struct WorkTasksHubView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(WorkTaskSyncService.self) private var workTaskSync
    @Environment(WorkTaskLabourLineSyncService.self) private var workTaskLabourLineSync
    @Environment(WorkTaskPaddockSyncService.self) private var workTaskPaddockSync
    @Environment(\.accessControl) private var accessControl

    @State private var showLog: Bool = false
    @State private var showCalculator: Bool = false
    @State private var showAddTask: Bool = false

    private var fmt: RegionFormatter { store.settings.regionFormatter }

    private var visibleTasks: [WorkTask] { store.workTasks.filter { !$0.isArchived } }
    private var totalTasks: Int { visibleTasks.count }
    private var totalCost: Double { visibleTasks.reduce(0) { $0 + $1.totalCost } }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                summaryCard
                toolsSection
                recentSection
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Work Tasks")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddTask = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .navigationDestination(isPresented: $showLog) {
            WorkTaskLogView()
        }
        .navigationDestination(isPresented: $showCalculator) {
            WorkTaskCalculatorView()
        }
        .sheet(isPresented: $showAddTask) {
            AddEditWorkTaskView()
        }
        .refreshable {
            await workTaskSync.syncForSelectedVineyard()
            await workTaskLabourLineSync.syncForSelectedVineyard()
            await workTaskPaddockSync.syncForSelectedVineyard()
        }
    }

    private var summaryCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Work Task Summary")
                        .font(.title3.weight(.bold))
                    Text("\(totalTasks) task\(totalTasks == 1 ? "" : "s") logged")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if accessControl?.canViewFinancials ?? false {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Total")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(fmt.formatCurrency(totalCost))
                            .font(.title2.weight(.bold).monospacedDigit())
                            .foregroundStyle(VineyardTheme.leafGreen)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tools")
                .font(.headline)

            HStack(spacing: 12) {
                toolCard(
                    title: "Task Log",
                    subtitle: "\(totalTasks) record\(totalTasks == 1 ? "" : "s")",
                    icon: "list.bullet.rectangle.portrait.fill",
                    color: .indigo
                ) {
                    showLog = true
                }

                toolCard(
                    title: "Calculator",
                    subtitle: "Quick cost estimate",
                    icon: "plusminus.circle.fill",
                    color: .teal
                ) {
                    showCalculator = true
                }
            }

            Button {
                showAddTask = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(VineyardTheme.leafGreen.gradient, in: .rect(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Log a New Task")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Record date, type, block, duration and workers")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Tasks")
                .font(.headline)

            let recent = Array(visibleTasks.sorted { $0.date > $1.date }.prefix(5))

            if recent.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("No tasks yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Tap + to log your first task.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
            } else {
                VStack(spacing: 8) {
                    ForEach(recent) { task in
                        WorkTaskRow(task: task)
                    }
                }
            }
        }
    }

    private func toolCard(title: String, subtitle: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(color.opacity(0.8))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 140)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

struct WorkTaskRow: View {
    let task: WorkTask
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.accessControl) private var accessControl
    @Environment(WorkTaskSyncService.self) private var workTaskSync

    @State private var showEdit: Bool = false

    private var fmt: RegionFormatter { store.settings.regionFormatter }

    var body: some View {
        Button {
            showEdit = true
        } label: {
            HStack(spacing: 14) {
                VStack {
                    Image(systemName: "person.2.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
                .background(VineyardTheme.olive.gradient, in: .rect(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Text(task.taskType.isEmpty ? "Task" : task.taskType)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(task.blockDisplay(in: store))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Label(String(format: "%.1fh", task.durationHours), systemImage: "clock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Label("\(task.totalPeople)", systemImage: "person.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if task.totalCost > 0 && (accessControl?.canViewFinancials ?? false) {
                            Text("•")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(fmt.formatCurrency(task.totalCost))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(VineyardTheme.leafGreen)
                        }
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(task.date, format: .dateTime.day().month(.abbreviated))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(task.date, format: .dateTime.year())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    RecordSyncBadge(
                        state: .forWorkTask(task.id, taskSync: workTaskSync),
                        showsLabel: false
                    )
                }
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showEdit) {
            AddEditWorkTaskView(existingTask: task)
        }
    }
}
