import Foundation
import Network

/// A small, privacy-preserving view of the phone's current network route.
/// It never inspects traffic; it only tells the sync layer when a route exists
/// and when it changed, so the API client can re-pick the address of your Mac.
@MainActor
final class ConnectivityMonitor: ObservableObject {
    @Published private(set) var isOnline = true
    @Published private(set) var isUsingCellular = false
    @Published private(set) var isUsingWiFi = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.example.ainotetaker.connectivity")

    init() {
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            let cellular = path.usesInterfaceType(.cellular)
            let wifi = path.usesInterfaceType(.wifi)
            Task { @MainActor [weak self] in
                self?.isOnline = online
                self?.isUsingCellular = cellular
                self?.isUsingWiFi = wifi
                // Moving between Wi-Fi, another Wi-Fi, or cellular can change
                // which address reaches the Mac — never reuse the old choice.
                NotificationCenter.default.post(name: .networkPathChanged, object: nil)
            }
        }
        monitor.start(queue: queue)
    }

    var routeLabel: String {
        if !isOnline { return "Offline" }
        if isUsingCellular { return "Cellular" }
        if isUsingWiFi { return "Wi-Fi" }
        return "Online"
    }
}
