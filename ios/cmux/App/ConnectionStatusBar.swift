import SwiftUI

struct ConnectionStatusBar: View {
    @EnvironmentObject var appState: AppState

    private var isVisible: Bool {
        switch appState.connectionStatus {
        case .connected(true): return false
        default: return true
        }
    }

    var body: some View {
        if isVisible {
            HStack(spacing: 6) {
                if case .reconnecting = appState.connectionStatus {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                }
                Text(appState.connectionStatus.label)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut, value: appState.connectionStatus)
        }
    }

    private var statusColor: Color {
        switch appState.connectionStatus {
        case .connected(true): return .green
        case .connected(false): return .yellow
        case .reconnecting, .connecting: return .yellow
        case .disconnected: return .red
        }
    }
}
