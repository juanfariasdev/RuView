// mac_wifi — RuView macOS Wi-Fi companion (ADR-025 "ORCA").
//
// Minimal CoreWLAN bridge for the Rust `wifi-densepose-wifiscan` adapter
// (`MacosCoreWlanScanner`, see
// v2/crates/wifi-densepose-wifiscan/src/adapter/macos_scanner.rs).
//
// macOS redacts `CWInterface.bssid()` to nil / `00:00:00:00:00:00` unless the
// *calling process* holds Location Services "when in use" authorization
// (see https://developer.apple.com/documentation/corewlan and ADR-025).
// Authorization is granted per bundle identifier via TCC and requires a
// proper `.app` bundle with an `Info.plist` `NSLocationWhenInUseUsageDescription`
// — a bare `swiftc`-compiled script has no bundle identity and can never be
// authorized. This tool therefore ships as `mac_wifi.app` (see build.sh) and
// exposes two independent modes:
//
//   --request-access   Foreground, one-time. Prompts the user for Location
//                       authorization and waits (bounded) for their decision.
//                       Run this once, interactively, after every
//                       build/reinstall. Never invoked by the Rust adapter.
//
//   --scan-once         Never prompts and never blocks on user input beyond
//                       the scan itself — this is the only mode the Rust
//                       adapter calls, on a polling loop with a 12s timeout
//                       (a scan can legitimately take several seconds; see
//                       ADR-025 §9.1). It reads whatever CoreWLAN currently
//                       allows and reports it truthfully, redacted or not.
//
// `--scan-once` NEVER fabricates or "fixes" a redacted BSSID: it reports
// exactly what CoreWLAN returns (the real MAC, or the `00:00:00:00:00:00`
// sentinel when redacted/unauthorized). `MacosCoreWlanScanner::resolve_bssid`
// on the Rust side is the single place that decides whether to synthesize a
// deterministic pseudo-BSSID or abstain from emitting an observation —
// duplicating or second-guessing that policy here would silently defeat it.

import Cocoa
import CoreLocation
import CoreWLAN
import Foundation

// A bare Foundation executable never registers with the WindowServer/AppKit
// application lifecycle. Some frameworks that gate data behind user consent
// (observed: CoreWLAN's BSSID/SSID redaction persisted even with a
// confirmed, correctly-synced CLLocationManager `authorizedAlways` grant --
// see ADR-025 section 9.1) appear to check for a real, running NSApplication, not
// just TCC's per-bundle authorization record. `.accessory` keeps this
// headless (no Dock icon), matching Info.plist's LSUIElement.
NSApplication.shared.setActivationPolicy(.accessory)

// MARK: - Location authorization

final class LocationAuthorizer: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var onChange: ((CLAuthorizationStatus) -> Void)?

    /// Current status. Reading this property never prompts the user.
    ///
    /// A freshly-created `CLLocationManager`'s `authorizationStatus` can read
    /// back a stale `.notDetermined` before its XPC connection to `locationd`
    /// finishes syncing the real, persisted TCC decision (observed on this
    /// SDK: immediately after `manager.authorizationStatus` construction, a
    /// synchronous read returns `.notDetermined` even for a previously
    /// authorized bundle). Give the run loop one short chance to settle
    /// before trusting the value.
    var status: CLAuthorizationStatus {
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return manager.authorizationStatus
    }

    /// Request "when in use" authorization if undetermined, and invoke
    /// `completion` exactly once with the resulting status. Bounded by
    /// `timeout` seconds in case the user never responds to the system
    /// dialog. Requires an actively-running run loop on the calling thread.
    func requestAndWait(timeout: TimeInterval, completion: @escaping (CLAuthorizationStatus) -> Void) {
        manager.delegate = self
        let current = manager.authorizationStatus
        guard current == .notDetermined else {
            completion(current)
            return
        }
        onChange = completion
        manager.requestWhenInUseAuthorization()
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            self.finish(with: self.manager.authorizationStatus)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        finish(with: manager.authorizationStatus)
    }

    private func finish(with status: CLAuthorizationStatus) {
        guard let completion = onChange else { return }
        onChange = nil
        completion(status)
    }
}

// macOS has a single authorized tier, exposed (per the current CoreLocation
// SDK headers) as `.authorizedAlways` — `.authorizedWhenInUse` is
// `API_UNAVAILABLE(macos)` and does not exist as a case on this platform,
// unlike iOS. `requestWhenInUseAuthorization()` is still the correct,
// least-privilege call to make; its granted result just reports as
// `.authorizedAlways` here.
func describe(_ status: CLAuthorizationStatus) -> String {
    switch status {
    case .authorizedAlways: return "authorizedAlways"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .notDetermined: return "notDetermined"
    @unknown default: return "unknown"
    }
}

func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
    status == .authorizedAlways
}

// MARK: - CoreWLAN scan-once

func bandLabel(forChannel channel: Int) -> String {
    switch channel {
    case 1 ... 14: return "2.4GHz"
    case 36 ... 177: return "5GHz"
    default: return "6GHz"
    }
}

func emitLine(ssid: String, bssid: String, channel: Int, rssi: Int, noise: Int) {
    let sample: [String: Any] = [
        "ssid": ssid,
        "bssid": bssid,
        "channel": channel,
        "rssi": rssi,
        "noise": noise,
        "band": bandLabel(forChannel: channel),
        "timestamp": Date().timeIntervalSince1970,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys]) else {
        return
    }
    let stdout = FileHandle.standardOutput
    stdout.write(data)
    stdout.write(Data([0x0A]))
}

/// Scan for nearby networks and print one JSON line per network to stdout,
/// including the connected one. The Rust-side `BssidRegistry`/quality gate
/// (ADR-025 sections 2.1 and 6) needs several distinct BSSIDs for the
/// multi-AP diversity pipeline -- a single connected-interface reading is not enough
/// (`min_bssids: 3` by default), which is why this scans rather than only
/// reading `CWWiFiClient.shared().interface()`.
///
/// Never requests authorization, never blocks on user input beyond the scan
/// itself — safe to call on every tick of the Rust adapter's polling loop,
/// which allows 12s. Apple's own docs say a scan "will block for the
/// duration of the scan"; MEASURED durations here ranged from ~0.4s (cached)
/// to several seconds (cold), which is also enough time for the
/// CoreWLAN/locationd startup races described below to settle without a
/// separate artificial delay.
func emitScanOnce() {
    // A freshly-launched process's location authorization state can still be
    // mid-sync with `locationd` at this point (see `LocationAuthorizer.status`).
    // Reading `.authorizationStatus` never prompts and never touches actual
    // coordinates.
    _ = LocationAuthorizer().status

    guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else {
        fputs("mac_wifi: no powered WiFi interface found\n", stderr)
        exit(1)
    }

    // Reported exactly as CoreWLAN returns it, including the
    // `00:00:00:00:00:00`/`""` redaction sentinel when Location authorization
    // is absent. The Rust adapter — not this helper — decides how to handle a
    // redacted identifier.
    emitLine(
        ssid: interface.ssid() ?? "",
        bssid: interface.bssid() ?? "00:00:00:00:00:00",
        channel: interface.wlanChannel()?.channelNumber ?? 0,
        rssi: interface.rssiValue(),
        noise: interface.noiseMeasurement()
    )

    let networks: Set<CWNetwork>
    do {
        networks = try interface.scanForNetworks(withSSID: nil)
    } catch {
        // The connected-interface line above was already emitted; a scan
        // failure (e.g. transient driver busy) just means fewer BSSIDs this
        // tick, not a hard failure -- exit 0 either way.
        fputs("mac_wifi: scan failed: \(error.localizedDescription)\n", stderr)
        exit(0)
    }

    for network in networks {
        emitLine(
            ssid: network.ssid ?? "",
            bssid: network.bssid ?? "00:00:00:00:00:00",
            channel: network.wlanChannel?.channelNumber ?? 0,
            rssi: network.rssiValue,
            noise: network.noiseMeasurement
        )
    }
    exit(0)
}

// MARK: - Interactive one-time consent

/// Request Location authorization in the user's foreground context and
/// report the outcome. Intended to be run once, manually, after installing
/// or rebuilding `mac_wifi.app` — never from the Rust adapter's fast path.
func requestAccess() {
    let authorizer = LocationAuthorizer()
    let already = authorizer.status

    if isAuthorized(already) {
        print("{\"authorization\":\"\(describe(already))\"}")
        exit(0)
    }

    if already == .denied || already == .restricted {
        fputs(
            "mac_wifi: Location access is \(describe(already)). Enable it manually in " +
                "System Settings > Privacy & Security > Location Services, then re-run " +
                "--request-access.\n",
            stderr
        )
        exit(1)
    }

    authorizer.requestAndWait(timeout: 120) { status in
        print("{\"authorization\":\"\(describe(status))\"}")
        exit(isAuthorized(status) ? 0 : 1)
    }

    // Keep the run loop alive so the delegate callback (and the timeout
    // fallback above) can fire; the completion handler above exits the
    // process directly once a decision is reached.
    RunLoop.main.run(until: Date().addingTimeInterval(125))
    fputs("mac_wifi: timed out waiting for a Location authorization decision\n", stderr)
    exit(1)
}

// MARK: - Entry point

let args = CommandLine.arguments
if args.contains("--request-access") {
    requestAccess()
} else if args.contains("--scan-once") {
    emitScanOnce()
} else if args.contains("--status") {
    // Diagnostic only: read-only, never prompts.
    let status = LocationAuthorizer().status
    print("{\"authorization\":\"\(describe(status))\"}")
    exit(isAuthorized(status) ? 0 : 1)
} else {
    fputs("usage: mac_wifi --request-access | --scan-once | --status\n", stderr)
    exit(64)
}
