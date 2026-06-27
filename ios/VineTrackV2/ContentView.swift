//
//  ContentView.swift
//  VineTrackV2
//
//  Created by Rork on April 27, 2026.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var items: [Item]
    #if DEBUG
    @State private var isShowingBackendDiagnostic: Bool = false
    #endif

    var body: some View {
        NavigationSplitView {
            List {
                ForEach(items) { item in
                    NavigationLink {
                        Text("Item at \(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))")
                    } label: {
                        Text(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))
                    }
                }
                .onDelete(perform: deleteItems)
            }
            .toolbar {
                #if DEBUG
                ToolbarItem(placement: .topBarLeading) {
                    Button("Backend Diagnostic", systemImage: "stethoscope") {
                        isShowingBackendDiagnostic = true
                    }
                }
                #endif
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
                ToolbarItem {
                    Button(action: addItem) {
                        Label("Add Item", systemImage: "plus")
                    }
                }
            }
        } detail: {
            Text("Select an item")
        }
        #if DEBUG
        .sheet(isPresented: $isShowingBackendDiagnostic) {
            BackendDiagnosticHostView()
        }
        #endif
    }

    private func addItem() {
        withAnimation {
            let newItem = Item(timestamp: Date())
            modelContext.insert(newItem)
        }
    }

    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(items[index])
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
