#!/usr/bin/env bash
#
# Secret scanner for the Kiosk Sign-In Assistant repo.
#
# One script, three callers, so the rules can never drift between them:
#
#   ./scripts/scan-secrets.sh --staged        pre-commit hook (fast, staged only)
#   ./scripts/scan-secrets.sh --range A..B    CI, on the pushed range
#   ./scripts/scan-secrets.sh --all           audit: every tracked file + history
#
# Exit 0 = clean, 1 = something must not be committed.
#
# The rules are deliberately narrow. A scanner that cries wolf gets bypassed
# with --no-verify, and a bypassed scanner protects nothing. Every rule below
# earns its place by being specific to how *this* repo could leak, and each is
# tested in scripts/test-scan-secrets.sh - including against this repo's own
# source, which talks about passwords constantly without containing one.

set -uo pipefail

MODE="${1:---staged}"
RANGE="${2:-}"
FAIL=0

# Domains this project's real accounts live at. An address at one of these is a
# real account, not documentation.
REAL_DOMAINS='een\.com|eagleeyenetworks\.com'

# Values that are self-evidently not secrets. Extend this rather than loosening
# a rule.
PLACEHOLDER='example\.(com|org|net)|EXAMPLE|REPLACE[_-]?ME|changeme|change-me|YOUR[_-]|<[^>]+>|\bredacted\b|\*\*\*|xxxx|hunter2|\bnull\b|\btrue\b|\bfalse\b'

# A credential key: not part of a longer identifier (passwordSelector), and not
# a property read off an object (cfg.password, shown.password).
CRED_KEY='(^|[^A-Za-z0-9_.])(password|passwd|pwd|secret|token|api[_-]?key)'

fail() {
    FAIL=1
    printf '\n  \033[1;31mBLOCKED\033[0m  %s\n' "$1"
    shift
    [[ $# -gt 0 ]] && printf '           %s\n' "$@"
    return 0
}

# Drops lines that are code rather than configuration. A line whose value side
# contains a call, a concatenation, or a variable reference is an expression,
# not a literal secret: `const password = pick(...)`, `x.password = '(set ' + n`,
# `password: $FROM_ENV`.
strip_code() {
    grep -vE '[:=][^"'"'"']*\(' \
        | grep -vE '[:=].*(\+|\$\{|\$\(|\$[A-Za-z_])' || true
}

# --- collect what to scan ----------------------------------------------------

case "$MODE" in
    --staged)
        PATHS="$(git diff --cached --name-only --diff-filter=ACMR)"
        CONTENT="$(git diff --cached -U0 --no-color --diff-filter=ACMR \
                   | grep '^+' | grep -v '^+++' || true)"
        ;;
    --range)
        if [[ -z "$RANGE" ]]; then
            echo "usage: $0 --range <base>..<head>" >&2; exit 2
        fi
        PATHS="$(git diff --name-only --diff-filter=ACMR "$RANGE")"
        CONTENT="$(git diff -U0 --no-color --diff-filter=ACMR "$RANGE" \
                   | grep '^+' | grep -v '^+++' || true)"
        ;;
    --all)
        PATHS="$(git ls-files)"
        # Whole history, not just the tip: a secret deleted in a later commit is
        # still public in a public repo.
        CONTENT="$(git log --all -p --no-color | grep '^+' | grep -v '^+++' || true)"
        ;;
    *)
        echo "usage: $0 [--staged | --range <base>..<head> | --all]" >&2; exit 2
        ;;
esac

if [[ -z "$PATHS" && -z "$CONTENT" ]]; then
    echo "scan-secrets: nothing to scan"
    exit 0
fi

# --- rule 1: files that must never be tracked --------------------------------
# docs/*.crx is the published artefact and is allowed. Everything else matching
# these shapes is signing material, a local build, or a real policy dump.

while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    case "$p" in
        docs/*.crx) continue ;;
    esac
    case "$p" in
        *.pem|*.key|*.p12|*.pfx)
            fail "$p" "private key / signing material" ;;
        dist/*)
            fail "$p" "dist/ is local build output - it holds key.pem" ;;
        *.crx)
            fail "$p" "local .crx build (publish via docs/ instead)" ;;
        .env|.env.*|*.local.json|policy.json|managed-config*.json|chrome-policy*.json)
            fail "$p" "likely to contain real credentials" ;;
        .DS_Store)
            fail "$p" "macOS metadata, not source" ;;
    esac
done <<< "$PATHS"

# --- rule 2: private key material in file content ----------------------------

if grep -qE -- '-----BEGIN ([A-Z]+ )*PRIVATE KEY-----' <<< "$CONTENT"; then
    fail "PEM private key block" \
         "A private key is being added. If this is the extension signing key," \
         "it must live outside the repo entirely - see dist/ in .gitignore."
fi

# --- rule 3: a credential assigned a real-looking literal --------------------
# Matches a quoted value of 4+ chars, or a bare token of 6+ chars.

CRED_HITS="$(grep -iE "$CRED_KEY"'"?'"'"'?[[:space:]]*[:=][[:space:]]*("[^"]{4,}"|'"'"'[^'"'"']{4,}'"'"'|[A-Za-z0-9._%/=-]{6,})' <<< "$CONTENT" \
             | strip_code \
             | grep -viE "$PLACEHOLDER" || true)"

if [[ -n "$CRED_HITS" ]]; then
    fail "credential with a concrete value" \
         "$(head -5 <<< "$CRED_HITS" | sed 's/^+[[:space:]]*//' | cut -c1-100)"
fi

# --- rule 4: a real account address ------------------------------------------
# Documentation uses example.com. An address at a real corporate domain is a
# real account being pasted in - usually from a policy dump or a console log.

ADDR_HITS="$(grep -iE "[A-Za-z0-9._%+-]+@($REAL_DOMAINS)" <<< "$CONTENT" \
             | grep -viE "$PLACEHOLDER" || true)"

if [[ -n "$ADDR_HITS" ]]; then
    fail "real account address (not example.com)" \
         "$(head -5 <<< "$ADDR_HITS" | sed 's/^+[[:space:]]*//' | cut -c1-100)" \
         "Use a placeholder such as store-42430-view@example.com in docs."
fi

# --- rule 5: a filled-in Managed configuration blob --------------------------
# The Admin console nests each setting as {"username": {"Value": <secret>}}.
# Committing a real one leaks both halves of the credential at once.

BLOB_HITS="$(grep -iE '"(username|password)"[[:space:]]*:[[:space:]]*\{[[:space:]]*"Value"[[:space:]]*:[[:space:]]*"[^"]{3,}"' <<< "$CONTENT" \
             | grep -viE "$PLACEHOLDER" || true)"

if [[ -n "$BLOB_HITS" ]]; then
    fail "populated Managed configuration blob" \
         "$(head -5 <<< "$BLOB_HITS" | sed 's/^+[[:space:]]*//' | cut -c1-100)" \
         "Credentials belong in the Admin console, not in the repo."
fi

# --- verdict -----------------------------------------------------------------

if (( FAIL )); then
    cat >&2 <<'EOF'

  ------------------------------------------------------------------
  This is a PUBLIC repository. Nothing above was committed.

  Fix the findings. If a match is genuinely a false positive, add the
  value to PLACEHOLDER in scripts/scan-secrets.sh rather than reaching
  for --no-verify, so the next person is protected too.
  ------------------------------------------------------------------
EOF
    exit 1
fi

echo "scan-secrets: clean ($MODE)"
exit 0
