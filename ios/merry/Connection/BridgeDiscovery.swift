import Foundation

protocol BridgeDiscoveryDelegate: AnyObject {
    @MainActor func discovery(_ discovery: BridgeDiscovery, didFind candidates: [PairingCredentials])
}

final class BridgeDiscovery: NSObject {
    weak var delegate: BridgeDiscoveryDelegate?

    private let browser = NetServiceBrowser()
    private var discovered: [NetService] = []

    func start() {
        browser.delegate = self
        browser.searchForServices(ofType: "_merry-bridge._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
    }
}

extension BridgeDiscovery: NetServiceBrowserDelegate {
    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        service.delegate = self
        service.resolve(withTimeout: 5)
        discovered.append(service)
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        discovered.removeAll { $0 === service }
    }
}

extension BridgeDiscovery: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let hostName = sender.hostName else { return }
        // Strip trailing dot from mDNS hostname
        let host = hostName.hasSuffix(".") ? String(hostName.dropLast()) : hostName
        let port = sender.port

        let candidates = discovered.compactMap { svc -> PairingCredentials? in
            guard let h = svc.hostName else { return nil }
            let cleanHost = h.hasSuffix(".") ? String(h.dropLast()) : h
            return PairingCredentials(host: cleanHost, port: svc.port, token: "")
        }
        Task { @MainActor in
            self.delegate?.discovery(self, didFind: candidates)
        }
    }
}
