# Kiosk Sign-In Assistant

A Chrome extension that signs the kiosk into its web app, using credentials held in **Admin console policy** rather than baked into the package.

This exists because Chrome's password manager does not work in a ChromeOS kiosk session — a kiosk has no Google account, so there is no profile to save passwords into and no policy that enables one.

---

## Why this design

Nothing is hardcoded. Username, password, and the CSS selectors for the form all come from `chrome.storage.managed`, which the Admin console populates per organizational unit.

That buys three things:

- **Per-store credentials** — one OU per store (or per region), different accounts, same extension package.
- **Rotation without republishing** — change the password in the Admin console, devices pick it up on next policy fetch.
- **Login page changes don't need a code change** — if the site redesigns its form and auto-detection breaks, set `usernameSelector` / `passwordSelector` in policy instead of rebuilding and re-reviewing the extension.

Two implementation details that matter more than they look:

**Framework-safe filling.** Setting `input.value` directly does not register with React, Vue or Angular — their internal state stays empty and the form submits blank. The script calls the native value setter and dispatches `input`/`change` events. This is the usual reason a hand-rolled autofill script appears to work and then fails on submit.

**Lockout guard.** A wrong password retried on every page load, across a fleet sharing one account, will lock that account out everywhere. Attempts are capped per boot (`maxAttempts`, default 3) and abandoned immediately if `errorSelector` matches.

---

## Before you build anything — check MFA

**If the account requires multi-factor authentication, this approach cannot work.** No amount of form filling completes an MFA challenge. If MFA is enforced and cannot be exempted for a dedicated kiosk account, stop here and solve it at the identity layer instead.

Check this first. It is the one thing that invalidates the whole plan.

---

## Confirmed: the Managed configuration field is the right hook

The **Managed configuration** section on the kiosk app's extension page — "Enter a JSON value", with a file upload option — is exactly the mechanism this extension is built around. It populates `chrome.storage.managed`.

Two useful facts about it:

**It only appears for extensions that declare a managed storage schema.** Chromium: *"this option only appears for extensions that support policy configuration."* This package declares `"storage": { "managed_schema": "schema.json" }`, which is what makes the field light up.

**The JSON is wrapped.** Each key maps to an object containing `Value`, not to a bare value. From Chromium's administrator documentation:

```json
{
  "Server":    { "Value": "http://my.server/api" },
  "CloudSync": { "Value": true },
  "Allowlist": { "Value": ["foo", "bar", "baz"] }
}
```

Chrome unwraps this before the extension sees it — `chrome.storage.managed.get()` returns plain values, so `content.js` reads `cfg.username`, not `cfg.username.Value`. It also unwraps defensively in case a wrapper ever survives, because the failure mode otherwise looks identical to "no credentials configured."

## Self-hosting — no Chrome Web Store needed

The Add extension dialog's **custom URL** option takes an update manifest URL, so this can be served from your own infrastructure. No Web Store account, no review queue, no public listing.

Three things this requires:

**1. `update_url` in the manifest.** Chrome's documentation is explicit: *"Extensions hosted on servers outside of the Chrome Webstore must include the `update_url` field in their manifest.json file."* It must point at your `update.xml`. Edit the placeholder in `manifest.json` before packaging — `package.sh` warns if it doesn't match the base URL you pass it.

**2. An update manifest.** `package.sh` generates it:

```xml
<?xml version='1.0' encoding='UTF-8'?>
<gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'>
  <app appid='EXTENSION_ID'>
    <updatecheck codebase='https://your-host/kiosk-signin-1.0.0.crx' version='1.0.0' />
  </app>
</gupdate>
```

**3. A web server that serves the `.crx` correctly.** Chrome is fussy here and the failure is silent:

- HTTPS — Chrome requires an HTTPS `codebase`
- Must **not** send `X-Content-Type-Options: nosniff` (the most common cause of a .crx that won't install)
- Content type `application/x-chrome-extension`, or a `.crx` suffix with an empty / `text/plain` / `application/octet-stream` type

### Your proxy has to allow it

This is the environment-specific trap. These kiosks reach the internet through `sproxy.7-11.com:3128`. **The host serving `update.xml` and the `.crx` must be reachable through that proxy** — whether you put it on internal infrastructure or a public host.

Extension update fetches are made by the browser's updater, not by page navigation, so the `URLBlocklist` of `*` should not block them. The proxy will. Verify the fetch works from a kiosk device before you assume the extension will ever install, because a device that can't reach its update URL simply never gets the extension and reports nothing useful about why.

### Build it

```bash
./package.sh https://your-host.example.com/kiosk-signin
```

That derives the extension ID from the signing key, writes `dist/update.xml` with the ID, version and codebase filled in, and packs the `.crx` if Chrome is on the machine. Run it twice and you get the same ID — the ID is a hash of the key, not something assigned.

> **Back up `dist/key.pem`.** The extension ID is derived from it. Lose the key and you get a new ID, which means re-adding the extension in the Admin console and re-entering the Managed configuration for **every OU**. Put it wherever your team keeps deployment secrets, not just on one laptop.

### Publishing an update

1. Bump `version` in `manifest.json`
2. Re-run `package.sh` with the same base URL — it reuses the existing key, so the ID is stable
3. Publish the new `.crx` and the regenerated `update.xml` together

Devices poll every few hours. `codebase` is versioned in the filename so an update is an atomic swap of `update.xml` rather than overwriting a file devices may be mid-download on.

---

## Files

| File | Purpose |
| --- | --- |
| `manifest.json` | MV3 manifest. Declares the managed storage schema, host permissions, content script and `update_url` |
| `schema.json` | JSON Schema for the policy. Admin console validates against this |
| `content.js` | The autofill logic |
| `package.sh` | Derives the extension ID, generates `update.xml`, packs the `.crx` |
| `scripts/scan-secrets.sh` | Blocks credentials and signing material from reaching this public repo |
| `scripts/test-scan-secrets.sh` | Tests for the scanner, including that it does *not* flag this repo's own source |
| `.githooks/pre-commit` | Runs the scanner over staged changes |
| `dist/` | Local build output — **git-ignored**, contains the private signing key |

Before packaging, edit `manifest.json`:

- `update_url` — your HTTPS host (see Self-hosting below)
- `host_permissions` and `content_scripts.matches` — only if the landing URL is not `auth.eagleeyenetworks.com`

---

## Deploy

### 1. Package and publish

```bash
./package.sh https://your-host.example.com/kiosk-signin
```

Publish `dist/update.xml` and `dist/kiosk-signin-<version>.crx` at that URL. See Self-hosting below for the server requirements — they are easy to get subtly wrong.

### 2. Attach it to the kiosk app

`Devices > Chrome > Apps & extensions > Kiosks` → select the OU → click the kiosk app row → **Extensions** → **Add extension** → **custom URL** → enter your `update.xml` URL and the extension ID that `package.sh` printed → **Save**.

### 3. Set the Managed configuration

Same side panel, **Managed configuration** section. Paste this (or upload it as a `.txt` file), adjusted per OU:

```json
{
  "username":        { "Value": "store-42430-view@example.com" },
  "password":        { "Value": "REPLACE_ME" },
  "autoSubmit":      { "Value": true },
  "maxAttempts":     { "Value": 3 },
  "errorSelector":   { "Value": ".login-error" },
  "successSelector": { "Value": "[data-testid=\"camera-grid\"]" }
}
```

Leave the selector fields out entirely to rely on auto-detection. Add them only when auto-detection fails — that is the whole point of having them in policy rather than in code.

This is the per-store part. One OU per store (or per region), same extension, different `username` and `password`.

### 4. Verify

On the device, with kiosk troubleshooting tools enabled in a **child OU containing only that device**:

1. `chrome://policy` → **Reload policies** → confirm the extension appears with your values.
2. Reboot. The kiosk should launch and sign in unattended.
3. Open DevTools (`Shift+Ctrl+i`) and check the console for `[kiosk-signin]` messages. Set `debug: true` in policy for detail.
4. **Turn troubleshooting tools back off before the device goes to a store.**

---

## Tuning for the actual login page

Auto-detection covers common form layouts. When it misses, get the selectors from DevTools on a normal machine and set them in policy.

- **Two-step forms** (username, then password on a second screen) are handled — the script fills whichever field is present.
- **`successSelector`** should match something that only exists once signed in. It stops retries and resets the attempt counter.
- **`errorSelector`** should match the "wrong username or password" element. Getting this right is what protects the shared account from lockout. Worth the five minutes to find it.

---

## "CRX_REQUIRED_PROOF_MISSING" when you download the .crx by hand

**This is expected. It is not a fault, and it does not mean self-hosting is broken.**

Chrome verifies a CRX differently depending on how it is being installed. From `extensions/common/verifier_formats.cc`:

```c
GetWebstoreVerifierFormat() -> CRX3_WITH_PUBLISHER_PROOF   // manual download
GetPolicyVerifierFormat()   -> CRX3                        // policy install
GetExternalVerifierFormat() -> CRX3
```

and in `crx_verifier.cc`:

```c
bool require_publisher_key =
    format == VerifierFormat::CRX3_WITH_PUBLISHER_PROOF ||
    format == VerifierFormat::CRX3_WITH_TEST_PUBLISHER_PROOF;
```

The "publisher proof" is a **second signature applied by the Chrome Web Store using Google's private key**. You cannot generate one. Any self-signed CRX will fail a manual download or drag-and-drop install, forever, no matter how correct everything else is. Setting `ExtensionInstallSources` does not change this — the verify call still runs in publisher-proof mode.

Policy-driven installs — the Admin console force-install path — call `Verify` with plain `CRX3`, where `require_publisher_key` is `false`. That is why the same file that refuses to install by hand installs fine through the Admin console.

**So do not use manual download as a test.** It fails by design and proves nothing. Test the policy path: let the device fetch policy (or reboot), then check `chrome://policy` and `chrome://extensions`.

---

## It isn't installing — triage

Work the hosting side first with one command, then the device side. Do not guess: there are three places the extension ID must agree, and a mismatch in any of them fails silently.

### Step 1: check the hosting

From any machine that can reach the URL — your laptop is fine, it does not need to be the kiosk:

```bash
./verify-hosting.py https://you.github.io/repo/kiosk-signin/update.xml --admin-id <id-from-admin-console>
```

That fetches the update manifest, follows it to the `.crx`, and checks everything that has to line up:

- update manifest is XML, not an HTML 404 page served with status 200 (a **GitHub Pages speciality**)
- `<gupdate>` carries the required namespace
- `codebase` URL actually resolves and returns a real CRX
- the file is CRX3, not CRX2 (Chrome 75+ rejects CRX2)
- **the `appid` matches the key that actually signed the `.crx`**
- `version` in `update.xml` matches `version` inside the package
- `update_url` in the manifest isn't still the placeholder
- `storage.managed_schema` is declared

The two that catch most people:

**appid vs signing key.** If you packed via `chrome://extensions` → Pack extension and let Chrome generate a fresh `.pem`, the ID changed and no longer matches what `package.sh` put in `update.xml` or what you typed into the Admin console. The script derives the ID from the CRX itself and tells you what it really is.

**codebase 404.** `update.xml` names `kiosk-signin-1.0.0.crx` but the file you published is called something else, or sits in a different folder. GitHub Pages returns its 404 page for this, and depending on configuration may do so with status 200 — so a browser looks like it "works" while Chrome gets HTML instead of a package.

Also worth doing if you haven't: add an empty **`.nojekyll`** file at the repo root. Without it Pages runs Jekyll over your files, which can skip or mangle assets.

> Testing the URL in the guest browser proves DNS, TLS and routing. It does not prove the manifest is valid, the codebase resolves, or the IDs agree. Those are what actually fail.

### Step 2: check the device

If hosting passes, the problem is on the device. You need visibility inside the kiosk session:

`Devices > Chrome > Settings > Device settings > Kiosk settings > Kiosk troubleshooting tools` → **Enable**.

> Do this in a **child OU containing only the lab device**. It hands anyone at the keyboard a way out of the kiosk, so it must never be on in production. Turn it off before the device leaves.

Reboot, then from the kiosk session press `Ctrl+n` for a new window and check, in order:

**1. `chrome://policy` → Reload policies.** Is the extension listed under the kiosk app's extension policy? If it isn't there at all, the device is not receiving the policy — check the device is in the OU you configured, not a parent or sibling.

**2. `chrome://extensions`.** Is the extension present?

- **Not present** → it never downloaded. Look at `chrome://device-log` and filter for the extension ID or your hosting hostname. Install failures surface here with a reason.
- **Present but greyed out or erroring** → click Errors on the card.

**3. If present and enabled**, the download worked and the problem is the content script. Open the login page, `Shift+Ctrl+i` for DevTools, look for `[kiosk-signin]` in the console. Set `"debug": { "Value": true }` in the Managed configuration for detail.

Common outcomes at this point:

| Console shows | Meaning |
| --- | --- |
| `no credentials in Admin console policy` | Managed configuration isn't reaching the extension. Check `chrome://policy` shows your values, and that the JSON uses the `{ "Value": ... }` wrapper |
| `no login form appeared` | Selectors didn't match. Get them from DevTools and set them in policy |
| `giving up after N attempts` | It tried and the credentials were rejected. Verify them by signing in by hand |
| nothing at all | The content script isn't running — check `host_permissions` and `content_scripts.matches` cover the actual login URL, including any origin it redirects to |

**4. Still nothing?** Then the MIME question becomes the live suspect. `verify-hosting.py` reports the `Content-Type` and `X-Content-Type-Options` headers GitHub Pages is sending. Since Pages cannot set custom headers, the test is to publish the same two files on a server where you *can* control them — set `Content-Type: application/x-chrome-extension` — and see whether it installs. If it does, that's your answer, and it also settles the hosting decision.

---

## Security

The password is distributed to devices as policy and is readable by anything running in that session, and by anyone who can reach **`chrome://policy`** on the device — that page lists extension policy values in plain text.

> **Block it.** In the Admin console, enable **Block sensitive internal Chrome URLs**, which includes `chrome://policy` in a Google-maintained list. This matters much more in a managed guest session than in a kiosk: an MGS operator has a real browser and can simply navigate there. Do not rely on `chrome://*` in the blocklist — Google recommends against that approach.

Treat the credential as a **low-privilege shared secret**:

- Use a **dedicated, view-only account per store**. Never a personal or administrative login.
- Rotate on a schedule, and immediately if a device is lost. Rotation is an Admin console edit, which is the main practical advantage of this design over a stored browser password.
- Pair with the BIOS lockdown from the field runbook. ChromeOS Flex has no forced re-enrollment, so an unlocked BIOS means someone can boot another OS and read the disk.

### Keeping credentials out of this repo

**This repository is public.** The primary defence is structural, not a scanner: no credential is ever an input to the build. `content.js` reads everything from `chrome.storage.managed` at runtime, `package.sh` copies an explicit allowlist of three files into the `.crx`, and there is no config file to accidentally commit. Keep it that way — if you ever find yourself adding a credential to a file here, the design has gone wrong.

Two things in this tree *are* sensitive:

- **`dist/key.pem`** — the private signing key. The extension ID is derived from it, so anyone holding it can sign a `.crx` that Chrome accepts as an update to this extension. Back it up somewhere private; `dist/` is git-ignored.
- **Pasted diagnostics.** `chrome://policy` dumps and `diagnose-form.js` output contain the live username. `diagnose-form.js` masks the password to a character count, but not the account. Redact before putting either in an issue or a commit.

Three layers enforce this, deliberately in this order:

| Layer | Catches | Bypassable? |
| --- | --- | --- |
| `.gitignore` | Keys, `dist/`, local `.crx`, policy dumps, `.DS_Store` | `git add -f` |
| `.githooks/pre-commit` | Key material, credentials with real values, real account addresses, populated policy blobs | `--no-verify`, and not installed by a fresh clone |
| `.github/workflows/secret-scan.yml` | Same rules over the pushed range, plus asserts each published `.crx` contains only the three expected files | **No** |

The hook is the convenience; **CI is the guarantee.** Git does not clone hooks, so each clone must opt in once:

```bash
git config core.hooksPath .githooks
```

Verify the rules still hold after editing them:

```bash
./scripts/test-scan-secrets.sh     # 25 cases: must-block and must-not-block
./scripts/scan-secrets.sh --all    # audit every tracked file and all history
```

Also switch on GitHub's own **secret scanning** and **push protection** (Settings → Code security), which are free for public repos and catch provider-issued tokens this scanner has no patterns for.

If a credential ever does reach a push: **rotate it in the Admin console first**, then worry about rewriting history. A public commit must be assumed cloned and indexed the moment it lands, so scrubbing history is cleanup, not containment.

---

## Maintenance

This is screen-scraping a login form. It will break when the vendor redesigns their login page — not if.

Assign an owner, and make "does the kiosk still sign itself in" part of whatever monitoring you have. The `successSelector` gives you a clean signal to check. When it does break, the first thing to try is setting the three selector fields in policy — that fixes most breakages without touching code or the Web Store.
