import SwiftUI

struct WorkTaskCalculatorView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.accessControl) private var accessControl

    @State private var hoursText: String = ""
    @State private var peopleText: String = "1"
    @State private var selectedCategoryId: UUID?
    @State private var showWorkerTypes: Bool = false

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case hours, people
    }

    private var fmt: RegionFormatter { store.settings.regionFormatter }

    private var hours: Double { Double(hoursText.replacingOccurrences(of: ",", with: ".")) ?? 0 }
    private var people: Int { max(Int(peopleText) ?? 0, 0) }

    private var selectedCategory: OperatorCategory? {
        guard let id = selectedCategoryId else { return nil }
        return store.operatorCategories.first(where: { $0.id == id })
    }

    private var hourlyRate: Double { selectedCategory?.costPerHour ?? 0 }

    private var totalCost: Double {
        hours * hourlyRate * Double(people)
    }

    private var perPersonCost: Double {
        hours * hourlyRate
    }

    var body: some View {
        if !(accessControl?.canViewFinancials ?? false) {
            ContentUnavailableView(
                "Financial tools hidden",
                systemImage: "lock.fill",
                description: Text("Only Managers can use the Work Task Calculator.")
            )
            .navigationTitle("Work Task Calculator")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            calculatorForm
        }
    }

    private var calculatorForm: some View {
        Form {
            Section {
                if store.operatorCategories.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No worker types configured")
                            .font(.subheadline.weight(.semibold))
                        Text("Add worker types in Settings → Worker Types to use this calculator.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    Picker("Worker Type", selection: $selectedCategoryId) {
                        Text("Select…").tag(UUID?.none)
                        ForEach(store.operatorCategories) { cat in
                            Text(cat.name).tag(Optional(cat.id))
                        }
                    }
                    .pickerStyle(.menu)

                    if let cat = selectedCategory {
                        LabeledContent("Hourly Rate") {
                            Text(fmt.formatCurrency(cat.costPerHour))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Worker Type")
                    Spacer()
                    Button {
                        showWorkerTypes = true
                    } label: {
                        Label("Edit", systemImage: "square.and.pencil")
                            .labelStyle(.titleAndIcon)
                            .font(.caption.weight(.semibold))
                            .textCase(nil)
                    }
                    .buttonStyle(.borderless)
                }
            }

            Section("Task Details") {
                HStack {
                    Text("Hours")
                    Spacer()
                    TextField("0", text: $hoursText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .focused($focusedField, equals: .hours)
                        .frame(maxWidth: 120)
                }
                HStack {
                    Text("Number of People")
                    Spacer()
                    TextField("1", text: $peopleText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .focused($focusedField, equals: .people)
                        .frame(maxWidth: 120)
                }
            }

            Section("Estimated Cost") {
                LabeledContent("Per Person") {
                    Text(fmt.formatCurrency(perPersonCost))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("People") {
                    Text("\(people)")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Total")
                        .font(.headline)
                    Spacer()
                    Text(fmt.formatCurrency(totalCost))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(VineyardTheme.leafGreen)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Work Task Calculator")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
        .onAppear {
            if selectedCategoryId == nil {
                selectedCategoryId = store.operatorCategories.first?.id
            }
        }
        .sheet(isPresented: $showWorkerTypes) {
            NavigationStack {
                OperatorCategoriesView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showWorkerTypes = false }
                        }
                    }
            }
        }
    }
}
