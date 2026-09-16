# macos-wifi-scan

Minimal macOS companion app for CoreWLAN Wi-Fi sensing (ADR-025 "ORCA").
Bridges `CWWiFiClient`/`CWInterface` to the Rust
[`wifi-densepose-wifiscan`](../../crates/wifi-densepose-wifiscan) adapter
(`MacosCoreWlanScanner`).

## Why an app bundle, not a bare script

macOS redacts `CWInterface.bssid()`/`.ssid()` to `00:00:00:00:00:00`/`""` for
any process that doesn't hold Location Services "when in use" authorization.
That authorization is tracked by TCC against a *bundle identifier*, and only
a process with a real `.app` bundle identity (`Info.plist` +
`NSLocationWhenInUseUsageDescription`) can be granted it — a bare
`swiftc`-compiled script cannot. This tool is therefore built and ad-hoc
signed as `mac_wifi.app`.

That grant turned out to be **necessary but not sufficient**, MEASURED live
on macOS 26.6.2 (see [ADR-025 §9.1](../../../docs/adr/ADR-025-macos-corewlan-wifi-sensing.md#91-empirical-result-location-authorization-was-necessary-but-not-sufficient--a-real-nsapplication-is-also-required)
for the full investigation): a confirmed, correctly-synced `authorizedAlways`
grant still left `--scan-once` reporting a redacted BSSID/SSID until
`main.swift` also called `NSApplication.shared.setActivationPolicy(.accessory)`
once at startup. A bare `Foundation`-linked executable sitting inside an
`.app` bundle apparently isn't enough — CoreWLAN's redaction check also wants
a real, WindowServer-registered application, not just a process holding a
valid TCC grant. `.accessory` keeps it Dock-less, matching `LSUIElement` in
`Info.plist`.

## Two modes, one binary

| Mode | Who calls it | Behavior |
|------|--------------|----------|
| `--request-access` | You, once, interactively, in a Terminal you're watching | Prompts for Location authorization in the user's foreground context and waits (up to 120s) for a decision. Never called by the Rust adapter. |
| `--scan-once` | The Rust adapter (`MacosCoreWlanScanner::scan_sync`), on every poll | Never prompts. Reads the connected interface, then scans for nearby networks (`scanForNetworks` — can legitimately take several seconds per Apple's own docs; MEASURED 0.4-5s+ here), emitting one JSON line per network: real values once authorized (MEASURED 20-30+ BSSIDs on this machine), or the `00:00:00:00:00:00`/`""` sentinel when unauthorized. |

`--scan-once` never fabricates or "corrects" a redacted BSSID itself. The
Rust-side `resolve_bssid` in
[`macos_scanner.rs`](../../crates/wifi-densepose-wifiscan/src/adapter/macos_scanner.rs)
is the single place that decides whether to synthesize a deterministic
pseudo-BSSID from `SSID:channel` or abstain entirely (when neither a real
BSSID nor an SSID is available). That guard is what keeps two distinct
redacted networks from silently collapsing into one fake identity, and this
helper is designed to never bypass or duplicate it.

**Why a scan, not just the connected interface:** the Rust pipeline's quality
gate (`min_bssids: 3` by default) structurally rejects any reading with fewer
than 3 distinct BSSIDs — a single connected-interface reading can never clear
it. `--scan-once` therefore also calls `interface.scanForNetworks(withSSID: nil)`
and emits one line per visible network, MEASURED as 20-30+ BSSIDs on this
machine, comfortably clearing the gate. See ADR-025 §9.2.

## Build

```bash
cd v2/tools/macos-wifi-scan
./build.sh
```

Requires Xcode Command Line Tools (`xcode-select --install`). Produces
`mac_wifi.app/Contents/MacOS/mac_wifi`, ad-hoc signed with a stable bundle
identifier (`net.ruv.ruview.macos-wifi-scan`).

**Caveat, confirmed on-device:** an ad-hoc signature's actual designated
requirement is anchored to *this build's exact hash*
(`codesign -d -r- mac_wifi.app` shows `cdhash H"..."`, not the bundle
identifier), and TCC's Location Services grant is tied to that requirement —
**every `./build.sh` invalidates the prior grant**, even with the identifier
unchanged. Re-run `--request-access` after every rebuild; don't rebuild
between granting access and running `--scan-once` while diagnosing an issue.
A stable self-signed Code Signing certificate (Keychain Access > Certificate
Assistant > Create a Certificate) removes this cdhash-pinning, at the cost of
installing persistent trust material in your keychain — worth doing for a
long-lived install, but not something to set up without your say-so.

## One-time setup (per machine)

```bash
# 1. Grant Location access -- opens the system permission dialog.
./mac_wifi.app/Contents/MacOS/mac_wifi --request-access

# 2. Point the Rust adapter at the REAL bundle path -- NOT a $PATH symlink.
#    MEASURED: a symlink from a $PATH directory (e.g. ~/.local/bin/mac_wifi)
#    to this exact file reported REDACTED values, while invoking the file by
#    this real path reported real ones (ADR-025 section 9.3) -- macOS's CFBundle/TCC
#    resolution for a bundled executable keys off the literal invoked path,
#    not the symlink-resolved inode.
export RUVIEW_MACOS_WIFI_HELPER="$(pwd)/mac_wifi.app/Contents/MacOS/mac_wifi"

# 3. Confirm real BSSIDs are now returned (not 00:00:00:00:00:00) -- expect
#    one line per visible network, not just one.
"$RUVIEW_MACOS_WIFI_HELPER" --scan-once
```

If `--request-access` reports `denied` or `restricted`, grant access manually
in System Settings > Privacy & Security > Location Services, then re-run it.
Check the current grant at any time without prompting:
`"$RUVIEW_MACOS_WIFI_HELPER" --status`.

Then run the sensing server (with `RUVIEW_MACOS_WIFI_HELPER` still exported)
as documented in [docs/user-guide.md](../../../docs/user-guide.md). Two
details that are easy to get wrong (ADR-025 §9.3):

```bash
# "wifi" is the source name on every platform -- "macos" is not a recognized
# --source value and silently runs nothing. A scan can take several seconds,
# so keep --tick-ms well above 1000.
./target/release/sensing-server --source wifi --http-port 3000 --ws-port 3001 --tick-ms 3000
```

## Output contract

One JSON line per visible network per `--scan-once` invocation (the
connected network, then each scanned network):

```json
{"ssid":"MyNetwork","bssid":"aa:bb:cc:dd:ee:ff","rssi":-52,"noise":-90,"channel":36,"band":"5GHz","timestamp":1234567.89}
{"ssid":"OtherNetwork","bssid":"11:22:33:44:55:66","rssi":-71,"noise":0,"channel":6,"band":"2.4GHz","timestamp":1234567.90}
```

Only `ssid`, `bssid`, `rssi`, and `channel` are consumed by the Rust parser;
`noise`, `band`, and `timestamp` are informational. `noise` is `0` for
scanned (non-connected) networks — `CWNetwork.noiseMeasurement` only reports
a real value for the currently associated interface.
