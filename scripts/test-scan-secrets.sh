#!/usr/bin/env bash
#
# Tests for scan-secrets.sh.
#
# Two halves, and the second matters as much as the first:
#
#   - things that MUST be blocked (the scanner does its job)
#   - things that MUST pass (the scanner is not noisy)
#
# The false-positive half exists because this repo's own source discusses
# passwords on almost every screen. A scanner that flags content.js gets
# switched off within a day, and then it protects nothing.
#
# Runs in a throwaway git repo under $TMPDIR - never touches the real one.

set -uo pipefail

SCANNER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scan-secrets.sh"
REAL_REPO="$(cd "$(dirname "$SCANNER")/.." && pwd)"
PASS=0; FAIL=0

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/scan-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

setup_repo() {
    rm -rf "$SANDBOX/repo"; mkdir -p "$SANDBOX/repo"
    git -C "$SANDBOX/repo" init -q
    git -C "$SANDBOX/repo" config user.email test@example.com
    git -C "$SANDBOX/repo" config user.name  Test
    mkdir -p "$SANDBOX/repo/scripts"
    cp "$SCANNER" "$SANDBOX/repo/scripts/"
    # A baseline commit, so `git diff --cached` has something to compare to.
    echo "readme" > "$SANDBOX/repo/README.md"
    git -C "$SANDBOX/repo" add README.md
    git -C "$SANDBOX/repo" commit -qm base
}

# check <expect: block|pass> <name> <path> <content>
check() {
    local expect="$1" name="$2" path="$3" content="$4"
    setup_repo
    mkdir -p "$(dirname "$SANDBOX/repo/$path")"
    printf '%s\n' "$content" > "$SANDBOX/repo/$path"
    git -C "$SANDBOX/repo" add -f "$path" >/dev/null 2>&1

    local out rc
    out="$(cd "$SANDBOX/repo" && ./scripts/scan-secrets.sh --staged 2>&1)"; rc=$?

    local got="pass"; (( rc != 0 )) && got="block"
    if [[ "$got" == "$expect" ]]; then
        PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %-46s (%s)\n' "$name" "$got"
    else
        FAIL=$((FAIL+1))
        printf '  \033[31mFAIL\033[0m %-46s expected %s, got %s\n' "$name" "$expect" "$got"
        sed 's/^/         | /' <<< "$out"
    fi
}

# Fixtures are ASSEMBLED FROM PARTS rather than written as literals, so that no
# real-looking secret ever appears verbatim in this file. That keeps this file
# committable without an exemption in the scanner - and an exemption is exactly
# the kind of bypass an attacker (or a hurried teammate) would aim for.
PEM_OPEN="-----BEGIN RSA PRIVATE"; PEM_OPEN="$PEM_OPEN KEY-----"
PEM_SHUT="-----END RSA PRIVATE";   PEM_SHUT="$PEM_SHUT KEY-----"
PK_OPEN="-----BEGIN PRIVATE";      PK_OPEN="$PK_OPEN KEY-----"
PW='Tr0ub4dor&3'
PW2='Wint3rSt0re!'
AK='sk-abc123def456'
D1='een'.'com'
D2='eagleeyenetworks'.'com'

echo
echo "=== must BLOCK ==============================================="
check block "private key file"        "dist/key.pem"    "$PEM_OPEN
MIIEowIBAAKCAQEA1234567890
$PEM_SHUT"
check block "key by extension only"   "signing.pem"     "not actually a key"
check block "PEM body in a .md file"  "notes.md"        "$PK_OPEN
MIIEvQIBADANBg"
check block "local .crx build"        "kiosk.crx"       "Cr24 binary"
check block "dist/ output"            "dist/update.xml" "<gupdate/>"
check block ".DS_Store"               ".DS_Store"       "junk"
check block ".env file"               ".env"            "FOO=bar"
check block "policy.json"             "policy.json"     "{}"
check block "json password value"     "cfg.json"        "{ \"password\": \"$PW\" }"
check block "yaml password value"     "cfg.yml"         "password: ${PW2}xyz"
check block "shell export of secret"  "run.sh"          "export API_KEY=$AK"
check block "real corporate address"  "notes.md"        "signed in as kiosk-ops@$D1 today"
check block "real kiosk address"      "notes.md"        "store-42430-view@$D2"
check block "populated policy blob"   "README.md"       "\"username\": { \"Value\": \"kiosk42@$D1\" },
\"password\": { \"Value\": \"$PW2\" }"

echo
echo "=== must PASS (no false positives) ==========================="
check pass  "docs/*.crx is published"  "docs/kiosk-signin-9.9.9.crx" "Cr24 binary"
check pass  "schema.json key, no value" "schema.json" '"password": { "title": "Password", "type": "string" }'
check pass  "README placeholder blob"   "README.md"   '"username":        { "Value": "store-42430-view@example.com" },
"password":        { "Value": "REPLACE_ME" },'
check pass  "JS variable from a call"   "content.js"  'const password = pick(cfg.passwordSelector, PASSWORD_FALLBACKS);'
check pass  "JS masking concatenation"  "diag.js"     "if (shown.password) shown.password = '(set, ' + String(shown.password).length + ' chars)';"
check pass  "empty-string default"      "content.js"  'passwordSelector: "",'
check pass  "prose about passwords"     "README.md"   'Rotate the password in the Admin console; a wrong password locks the account out fleet-wide.'
check pass  "boolean-valued key"        "cfg.json"    '{ "autoSubmit": true, "tokenRefresh": false }'
check pass  "secret read from env var"  "deploy.sh"   'password: $KIOSK_PW'
check pass  "docs address at example"   "README.md"   'Use store-42430-view@example.com as the account.'

echo
echo "=== the real repo's own source must PASS ====================="
# The strongest false-positive test there is: every file actually in the tree.
setup_repo
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    case "$f" in .git/*|dist/*|.DS_Store) continue ;; esac
    mkdir -p "$(dirname "$SANDBOX/repo/$f")"
    cp "$REAL_REPO/$f" "$SANDBOX/repo/$f" 2>/dev/null || true
done < <(cd "$REAL_REPO" && git ls-files --cached --others --exclude-standard)
git -C "$SANDBOX/repo" add -A >/dev/null 2>&1
if out="$(cd "$SANDBOX/repo" && ./scripts/scan-secrets.sh --staged 2>&1)"; then
    PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %-46s (pass)\n' "all committable files in this repo"
else
    FAIL=$((FAIL+1))
    printf '  \033[31mFAIL\033[0m %-46s expected pass, got block\n' "all committable files in this repo"
    sed 's/^/         | /' <<< "$out"
fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
