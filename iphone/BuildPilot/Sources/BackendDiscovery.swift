import Foundation
import Network

/// Finds Build Pilot backends on the local network via Bonjour
/// (`_buildpilot._tcp`, advertised by `python -m buildpilot` on the Mac).
/// This is what lets a painter use the app without ever typing an address.
@MainActor
final class BackendDiscovery: ObservableObject {
    struct DiscoveredMac: Identifiable, Equatable {
        let id: String
        let name: String
        let endpoint: NWEndpoint

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    }

    @Published private(set) var macs: [DiscoveredMac] = []
    @Published private(set) var isBrowsing = false

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        isBrowsing = true
        let browser = NWBrowser(
            for: .bonjour(type: "_buildpilot._tcp", domain: nil),
            using: NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        )
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                visitLog.info("Bonjour browser ready")
            case .waiting(let error):
                visitLog.error("Bonjour browser waiting: \(error.localizedDescription) — likely Local Network permission (PolicyDenied)")
            case .failed(let error):
                visitLog.error("Bonjour browser failed: \(error.localizedDescription)")
            case .cancelled:
                visitLog.info("Bonjour browser cancelled")
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.macs = results.compactMap { result in
                    guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                    return DiscoveredMac(id: name, name: Self.displayName(name), endpoint: result.endpoint)
                }
                .sorted { $0.name < $1.name }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
    }

    /// Resolves a discovered service to a usable http URL by opening a TCP
    /// connection and reading the remote host/port from the established path.
    static func resolve(_ mac: DiscoveredMac) async -> URL? {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(to: mac.endpoint, using: .tcp)
            var resumed = false
            let finish: (URL?) -> Void = { url in
                guard !resumed else { return }
                resumed = true
                connection.cancel()
                continuation.resume(returning: url)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint
                    else {
                        visitLog.error("Resolve \(mac.id): connected but no host/port on path")
                        return finish(nil)
                    }
                    let url = Self.url(host: host, port: port)
                    visitLog.info("Resolved \(mac.id) → \(url?.absoluteString ?? "nil")")
                    finish(url)
                case .waiting(let error):
                    // Fail fast: .waiting means the service resolved but the
                    // connection can't establish (e.g. stale advertisement
                    // pointing at a dead port). Don't sit out the timeout.
                    visitLog.error("Resolve \(mac.id): waiting — \(error.localizedDescription)")
                    finish(nil)
                case .failed(let error):
                    visitLog.error("Resolve \(mac.id): failed — \(error.localizedDescription)")
                    finish(nil)
                case .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { finish(nil) }
        }
    }

    /// One-shot: browse briefly and resolve the first Mac found.
    /// Used for zero-config first runs.
    static func quickFind(timeout: TimeInterval = 2.5) async -> URL? {
        let discovery = BackendDiscovery()
        discovery.start()
        defer { discovery.stop() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let first = discovery.macs.first {
                return await resolve(first)
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return nil
    }

    nonisolated private static func displayName(_ serviceName: String) -> String {
        serviceName.replacingOccurrences(of: "Build Pilot on ", with: "")
    }

    nonisolated private static func url(host: NWEndpoint.Host, port: NWEndpoint.Port) -> URL? {
        switch host {
        case .ipv4(let address):
            return URL(string: "http://\(address):\(port)")
        case .ipv6(let address):
            // Strip the zone (%en0) — not representable in a URL.
            let raw = "\(address)".components(separatedBy: "%")[0]
            return URL(string: "http://[\(raw)]:\(port)")
        case .name(let name, _):
            return URL(string: "http://\(name):\(port)")
        @unknown default:
            return nil
        }
    }
}
