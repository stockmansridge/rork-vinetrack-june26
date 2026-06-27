import SwiftUI

struct MaintenanceLogDetailView: View {
    let log: MaintenanceLog

    @Environment(MigratedDataStore.self) private var store
    @Environment(\.accessControl) private var accessControl
    @Environment(\.dismiss) private var dismiss
    @State private var showEdit: Bool = false
    @State private var showFullPhoto: Bool = false

    private var currentLog: MaintenanceLog {
        store.maintenanceLogs.first(where: { $0.id == log.id }) ?? log
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    headerCard
                    detailsCard
                    if accessControl?.canViewFinancials ?? false {
                        costsCard
                    }

                    if currentLog.invoicePhotoData != nil {
                        invoiceCard
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Maintenance Detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") { showEdit = true }
                }
            }
            .sheet(isPresented: $showEdit) {
                AddEditMaintenanceLogView(existingLog: currentLog)
            }
            .fullScreenCover(isPresented: $showFullPhoto) {
                invoiceFullScreen
            }
        }
    }

    private var headerCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "gearshape.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(VineyardTheme.earthBrown.gradient, in: .rect(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 4) {
                Text(store.resolvedMaintenanceItemName(currentLog))
                    .font(.title3.weight(.bold))
                Text(fmt.formatDate(currentLog.date))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let by = currentLog.createdBy, !by.isEmpty {
                    Text("by \(by)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Service Details")
                .font(.headline)

            detailRow(label: "Hours", value: String(format: "%.1f hrs", currentLog.hours), icon: "clock.fill", color: VineyardTheme.olive)

            if let mh = currentLog.machineHours {
                detailRow(label: "Machine Hours", value: String(format: "%.1f", mh), icon: "gauge.with.dots.needle.67percent", color: VineyardTheme.earthBrown)
            }

            if !currentLog.workCompleted.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Work Completed", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(currentLog.workCompleted)
                        .font(.body)
                }
            }

            if !currentLog.partsUsed.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Parts Used", systemImage: "wrench.and.screwdriver")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(currentLog.partsUsed)
                        .font(.body)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }

    private func detailRow(label: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(color)
                .frame(width: 28)

            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .font(.subheadline.weight(.semibold))
        }
    }

    private var costsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Costs")
                .font(.headline)

            costRow(label: "Parts", amount: currentLog.partsCost, color: .orange)
            costRow(label: "Labour", amount: currentLog.labourCost, color: .blue)

            Divider()

            HStack {
                Text("Total")
                    .font(.subheadline.weight(.bold))
                Spacer()
                Text(fmt.formatCurrency(currentLog.totalCost))
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(VineyardTheme.earthBrown)
            }

            if currentLog.hours > 0 {
                HStack {
                    Text("Cost per Hour")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(fmt.formatCurrency(currentLog.totalCost / currentLog.hours))
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("/hr")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }

    private func costRow(label: String, amount: Double, color: Color) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(fmt.formatCurrency(amount))
                .font(.subheadline.weight(.medium).monospacedDigit())
        }
    }

    private var invoiceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Invoice")
                .font(.headline)

            if let photoData = currentLog.invoicePhotoData, let uiImage = UIImage(data: photoData) {
                Button {
                    showFullPhoto = true
                } label: {
                    Color(.secondarySystemBackground)
                        .frame(height: 220)
                        .overlay {
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .allowsHitTesting(false)
                        }
                        .clipShape(.rect(cornerRadius: 12))
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(.ultraThinMaterial, in: .rect(cornerRadius: 8))
                                .padding(8)
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }

    private var invoiceFullScreen: some View {
        NavigationStack {
            GeometryReader { geo in
                if let photoData = currentLog.invoicePhotoData, let uiImage = UIImage(data: photoData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .background(.black)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showFullPhoto = false }
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }

    private var fmt: RegionFormatter { store.settings.regionFormatter }
}
