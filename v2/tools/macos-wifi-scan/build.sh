#!/usr/bin/env bash
# Builds mac_wifi.app -- the RuView macOS Wi-Fi companion (ADR-025 "ORCA").
#
# Produces a minimal, ad-hoc-signed .app bundle so macOS's TCC subsystem has
# a stable bundle identity to attach a Location Services authorization grant
# to. A bare `swiftc` script has no such identity and can never be
# authorized -- see main.swift's header comment for the full rationale.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${DIR}/mac_wifi.app"
CONTENTS="${APP}/Contents"
BIN_DIR="${CONTENTS}/MacOS"
BUNDLE_ID="net.ruv.ruview.macos-wifi-scan"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "mac_wifi.app can only be built on macOS." >&2
    exit 1
fi
if ! command -v swiftc &>/dev/null; then
    echo "swiftc not found. Install Xcode Command Line Tools: xcode-select --install" >&2
    exit 1
fi

rm -rf "${APP}"
mkdir -p "${BIN_DIR}"
cp "${DIR}/Info.plist" "${CONTENTS}/Info.plist"

swiftc -O \
    -framework Cocoa \
    -framework CoreLocation \
    -framework CoreWLAN \
    -framework Foundation \
    -o "${BIN_DIR}/mac_wifi" \
    "${DIR}/main.swift"

# Ad-hoc signature: no Apple Developer certificate required for local use.
# CAUTION: an ad-hoc signature's designated requirement is anchored to this
# exact build's cdhash (verify with `codesign -d -r- mac_wifi.app`), not to
# --identifier alone. TCC's Location Services grant is tied to that
# requirement, so *every rebuild invalidates the prior grant* -- re-run
# `mac_wifi --request-access` after each `./build.sh`. A stable
# self-signed Code Signing certificate (Keychain Access > Certificate
# Assistant) avoids this, at the cost of installing persistent trust
# material in your keychain -- not done here without asking first.
codesign --force --sign - --identifier "${BUNDLE_ID}" "${APP}"

cat <<EOF
Built ${APP}
$(codesign -d -r- "${APP}" 2>&1 | tail -1)

Next steps (re-run step 1 after EVERY ./build.sh -- see the codesign
CAUTION above: an ad-hoc rebuild is a new identity to TCC):
  1. Grant Location access once, interactively (this opens a system prompt):
       "${BIN_DIR}/mac_wifi" --request-access

  2. Point the Rust adapter at the built binary. MacosCoreWlanScanner looks
     for "mac_wifi" on \$PATH by default, e.g.:
       ln -sf "${BIN_DIR}/mac_wifi" ~/.local/bin/mac_wifi   # ensure this dir is on \$PATH

  3. Verify a real (non-redacted) BSSID is now returned:
       "${BIN_DIR}/mac_wifi" --scan-once

Check the current grant at any time without prompting:
  "${BIN_DIR}/mac_wifi" --status

If step 1 reports "denied" or "restricted", grant access manually in
System Settings > Privacy & Security > Location Services, then re-run
--request-access.
EOF
