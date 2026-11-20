import SwiftUI

struct SendTextView: View {
    @EnvironmentObject var appState: AppState
    @State private var text = ""
    @State private var selectedSurfaceID: String?

    private var targetSurface: Surface? {
        if let id = selectedSurfaceID {
            return appState.surfaces.first(where: { $0.id == id })
        }
        return appState.surfaces.first
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Target surface") {
                    if appState.surfaces.isEmpty {
                        Text("No surfaces available")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Surface", selection: $selectedSurfaceID) {
                            ForEach(appState.surfaces) { surface in
                                Text(surface.title).tag(Optional(surface.id))
                            }
                        }
                    }
                }

                Section("Text") {
                    TextField("Type to send…", text: $text, axis: .vertical)
                        .lineLimit(4...8)
                }

                Section {
                    Button {
                        guard let surface = targetSurface, !text.isEmpty else { return }
                        appState.sendText(text, to: surface.id)
                        text = ""
                    } label: {
                        Label("Send text", systemImage: "paperplane")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(targetSurface == nil || text.isEmpty)

                    Button {
                        guard let surface = targetSurface, !text.isEmpty else { return }
                        appState.sendText(text + "\n", to: surface.id)
                        text = ""
                    } label: {
                        Label("Send + Enter", systemImage: "return")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(targetSurface == nil || text.isEmpty)
                }

                Section("Common keys") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 8) {
                        ForEach(["ctrl+c", "ctrl+d", "ctrl+z", "ctrl+l", "Up", "Down", "Tab", "Escape"], id: \.self) { key in
                            Button(key) {
                                guard let surface = targetSurface else { return }
                                appState.sendKey(key, to: surface.id)
                            }
                            .buttonStyle(.bordered)
                            .font(.caption.monospaced())
                            .disabled(targetSurface == nil)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Send")
        }
    }
}
