import SwiftUI

struct PairingView: View {
    @EnvironmentObject var appState: AppState
    @State private var showScanner = false
    @State private var manualHost = ""
    @State private var manualPort = "47821"
    @State private var manualToken = ""
    @State private var showManual = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)

                VStack(spacing: 8) {
                    Text("Pair with cmux")
                        .font(.title.bold())
                    Text("Scan the QR code shown by\n`cmux-bridge --pair` on your Mac.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                Button {
                    showScanner = true
                } label: {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)

                Button("Enter manually") {
                    showManual = true
                }
                .foregroundStyle(.secondary)

                Spacer()
            }
            .navigationTitle("cmux companion")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showScanner) {
                QRScannerView { scannedURL in
                    showScanner = false
                    if let url = URL(string: scannedURL) {
                        appState.handlePairingURL(url)
                    }
                }
            }
            .sheet(isPresented: $showManual) {
                ManualPairingView()
            }
        }
    }
}

private struct ManualPairingView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = "47821"
    @State private var token = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Bridge address") {
                    TextField("Host or IP", text: $host)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                }
                Section("Token") {
                    TextField("Paste token from cmux-bridge --pair", text: $token)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle("Manual pairing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        guard let portInt = Int(port), !host.isEmpty, !token.isEmpty else { return }
                        let creds = PairingCredentials(host: host, port: portInt, token: token)
                        try? PairingStore().save(creds)
                        appState.connect(to: creds)
                        dismiss()
                    }
                    .disabled(host.isEmpty || token.isEmpty)
                }
            }
        }
    }
}
