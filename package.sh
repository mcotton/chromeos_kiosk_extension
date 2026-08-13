#!/usr/bin/env bash
#
# Packages the Kiosk Sign-In Assistant for self-hosting and generates the
# update manifest the Admin console's "custom URL" option expects.
#
# Usage:
#   ./package.sh https://your-host.example.com/kiosk-signin
#
# The argument is the base URL where you will publish update.xml and the .crx.
# Both files must sit at that location.
#
# Outputs into ./dist:
#   key.pem     private signing key  -- BACK THIS UP, see warning below
#   <id>.crx    the packaged extension
#   update.xml  the update manifest to publish alongside it
#
# Requires: openssl, python3. Chrome or Chromium is used for CRX packing if
# present; otherwise the script stops after generating the ID and update.xml
# and tells you the command to run elsewhere.

set -euo pipefail

BASE_URL="${1:-}"
if [[ -z "$BASE_URL" ]]; then
    echo "usage: $0 <base-url>" >&2
    echo "  e.g. $0 https://tools.example.com/kiosk-signin" >&2
    exit 1
fi
BASE_URL="${BASE_URL%/}"   # strip trailing slash

if [[ "$BASE_URL" != https://* ]]; then
    echo "ERROR: the base URL must be HTTPS. Chrome requires an HTTPS codebase." >&2
    exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$SRC_DIR/dist"
KEY="$DIST/key.pem"

mkdir -p "$DIST"

# --- version, read from the manifest so the two can never drift -------------

VERSION="$(python3 -c "import json,sys;print(json.load(open('$SRC_DIR/manifest.json'))['version'])")"
echo "Extension version: $VERSION"

# --- signing key -------------------------------------------------------------

if [[ -f "$KEY" ]]; then
    echo "Using existing key: $KEY"
else
    echo "Generating a new signing key..."
    openssl genrsa -out "$KEY" 2048 2>/dev/null
    chmod 600 "$KEY"
    cat <<'WARN'

  ####################################################################
  #  A new private key was generated.                                #
  #                                                                  #
  #  The extension ID is derived from this key. Lose it and you get  #
  #  a NEW ID, which means re-adding the extension in the Admin      #
  #  console and re-entering the Managed configuration for EVERY OU. #
  #                                                                  #
  #  Back up dist/key.pem somewhere your team can find it.           #
  ####################################################################

WARN
fi

# --- derive the extension ID -------------------------------------------------
# Chrome derives the ID from SHA-256 of the DER public key: take the first 16
# bytes, hex-encode, then map each hex digit 0-f onto the letters a-p.

TMP_DER="$(mktemp)"
trap 'rm -f "$TMP_DER" 2>/dev/null || true' EXIT
openssl rsa -in "$KEY" -pubout -outform DER -out "$TMP_DER" 2>/dev/null
EXT_ID="$(python3 - "$TMP_DER" <<'PY'
import hashlib, sys
der = open(sys.argv[1], 'rb').read()
digest = hashlib.sha256(der).hexdigest()[:32]
print(''.join(chr(ord('a') + int(c, 16)) for c in digest))
PY
)"
echo "Extension ID: $EXT_ID"

# --- update manifest ---------------------------------------------------------

CRX_NAME="kiosk-signin-${VERSION}.crx"
cat > "$DIST/update.xml" <<XML
<?xml version='1.0' encoding='UTF-8'?>
<gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'>
  <app appid='${EXT_ID}'>
    <updatecheck codebase='${BASE_URL}/${CRX_NAME}' version='${VERSION}' />
  </app>
</gupdate>
XML
echo "Wrote $DIST/update.xml"

# --- sanity-check the manifest's update_url ---------------------------------

DECLARED="$(python3 -c "import json;print(json.load(open('$SRC_DIR/manifest.json')).get('update_url',''))")"
EXPECTED="${BASE_URL}/update.xml"
if [[ "$DECLARED" != "$EXPECTED" ]]; then
    echo
    echo "WARNING: manifest.json update_url does not match this base URL."
    echo "  manifest.json : $DECLARED"
    echo "  expected      : $EXPECTED"
    echo "  Fix manifest.json and re-run, or auto-updates will not work."
    echo
fi

# --- pack -------------------------------------------------------------------

CHROME=""
for candidate in google-chrome chromium chromium-browser \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"; do
    if command -v "$candidate" >/dev/null 2>&1; then CHROME="$candidate"; break; fi
    if [[ -x "$candidate" ]]; then CHROME="$candidate"; break; fi
done

if [[ -z "$CHROME" ]]; then
    cat <<EOF

Chrome/Chromium not found, so the .crx was not built here.
Run this on a machine that has Chrome, then publish the result:

  chrome --pack-extension="$SRC_DIR" --pack-extension-key="$KEY"

Rename the output to $CRX_NAME and publish it next to update.xml.
EOF
    exit 0
fi

echo "Packing with: $CHROME"
PACK_SRC="$DIST/src"
rm -rf "$PACK_SRC"; mkdir -p "$PACK_SRC"
cp "$SRC_DIR/manifest.json" "$SRC_DIR/schema.json" "$SRC_DIR/content.js" "$PACK_SRC/"

"$CHROME" --pack-extension="$PACK_SRC" --pack-extension-key="$KEY" >/dev/null 2>&1 || true

if [[ -f "$DIST/src.crx" ]]; then
    mv "$DIST/src.crx" "$DIST/$CRX_NAME"
    rm -rf "$PACK_SRC"
    echo "Wrote $DIST/$CRX_NAME"
else
    echo "Packing did not produce a .crx. Pack manually with the command above." >&2
    exit 1
fi

cat <<EOF

Done. Publish BOTH of these at ${BASE_URL}/ :

  update.xml
  $CRX_NAME

Server requirements for the .crx:
  - served over HTTPS
  - must NOT send  X-Content-Type-Options: nosniff
  - content type should be application/x-chrome-extension
    (or empty/text-plain/application-octet-stream with a .crx suffix)

Then in the Admin console:
  Devices > Chrome > Apps & extensions > Kiosks > [your kiosk app]
    > Extensions > Add extension > custom URL
  Enter: ${BASE_URL}/update.xml
  Extension ID: ${EXT_ID}

EOF
