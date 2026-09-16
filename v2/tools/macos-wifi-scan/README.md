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
| `--scan-once` | The Rust adapter (`MacosCoreWlanScanner::scan_sync`), on every poll | Never prompts, never blocks on user input. Reads whatever CoreWLAN currently allows and reports it as-is: real values once authorized (MEASURED), or the `00:00:00:00:00:00`/`""` sentinel when unauthorized. |

`--scan-once` never fabricates or "corrects" a redacted BSSID itself. The
Rust-side `resolve_bssid` in
[`macos_scanner.rs`](../../crates/wifi-densepose-wifiscan/src/adapter/macos_scanner.rs)
is the single place that decides whether to synthesize a deterministic
pseudo-BSSID from `SSID:channel` or abstain entirely (when neither a real
BSSID nor an SSID is available). That guard is what keeps two distinct
redacted networks from silently collapsing into one fake identity, and this
helper is designed to never bypass or duplicate it.

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

# 2. Put the built binary on $PATH (MacosCoreWlanScanner::new() looks for
#    "mac_wifi" on $PATH by default).
mkdir -p ~/.local/bin
ln -sf "$(pwd)/mac_wifi.app/Contents/MacOS/mac_wifi" ~/.local/bin/mac_wifi
# ensure ~/.local/bin is on $PATH

# 3. Confirm real BSSIDs are now returned (not 00:00:00:00:00:00).
mac_wifi --scan-once
```

If `--request-access` reports `denied` or `restricted`, grant access manually
in System Settings > Privacy & Security > Location Services, then re-run it.
Check the current grant at any time without prompting: `mac_wifi --status`.

Then run the sensing server as documented in
[docs/user-guide.md](../../../docs/user-guide.md):

```bash
./target/release/sensing-server --source macos --http-port 3000 --ws-port 3001 --tick-ms 500
```

## Output contract

```json
{"ssid":"MyNetwork","bssid":"aa:bb:cc:dd:ee:ff","rssi":-52,"noise":-90,"channel":36,"band":"5GHz","timestamp":1234567.89}
```

Only `ssid`, `bssid`, `rssi`, and `channel` are consumed by the Rust parser;
`noise`, `band`, and `timestamp` are informational.
