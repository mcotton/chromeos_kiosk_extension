#!/usr/bin/env python3
"""
verify-hosting.py - check a self-hosted Chrome extension end to end.

Run this from any machine that can reach the hosting URL (your laptop is fine;
it does not need to run on the kiosk). It fetches the update manifest, follows
it to the .crx, and checks every value that has to line up for a policy-driven
install to succeed.

    ./verify-hosting.py https://you.github.io/repo/kiosk-signin/update.xml

Optionally pass the extension ID you entered in the Admin console so it can be
compared too - that is a common place for a mismatch to hide:

    ./verify-hosting.py https://.../update.xml --admin-id abcdefgh...

Exit code is 0 only if every check passes.
"""

import argparse
import hashlib
import io
import json
import struct
import sys
import urllib.request
import urllib.error
import xml.etree.ElementTree as ET
import zipfile

GUPDATE_NS = '{http://www.google.com/update2/response}'

PASS, FAIL, WARN, INFO = 'PASS', 'FAIL', 'WARN', 'INFO'
_results = []


def report(status, label, detail=''):
    _results.append(status)
    colour = {PASS: '\033[32m', FAIL: '\033[31m', WARN: '\033[33m', INFO: '\033[36m'}[status]
    reset = '\033[0m'
    print(f'  {colour}[{status:4}]{reset} {label}')
    if detail:
        for line in str(detail).splitlines():
            print(f'         {line}')


def fetch(url, what):
    req = urllib.request.Request(url, headers={'User-Agent': 'verify-hosting/1.0'})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.read(), dict(resp.headers), resp.status, resp.geturl()
    except urllib.error.HTTPError as e:
        report(FAIL, f'{what} returned HTTP {e.code}', url)
        return None, {}, e.code, url
    except Exception as e:
        report(FAIL, f'{what} could not be fetched', f'{url}\n{e}')
        return None, {}, None, url


# --- minimal protobuf reader, enough for the CRX3 header --------------------

def read_varint(buf, pos):
    result = shift = 0
    while True:
        if pos >= len(buf):
            raise ValueError('truncated varint')
        b = buf[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, pos
        shift += 7


def iter_fields(buf):
    """Yield (field_number, payload_bytes) for length-delimited fields."""
    pos = 0
    while pos < len(buf):
        key, pos = read_varint(buf, pos)
        field, wire = key >> 3, key & 7
        if wire == 2:
            length, pos = read_varint(buf, pos)
            yield field, buf[pos:pos + length]
            pos += length
        elif wire == 0:
            _, pos = read_varint(buf, pos)
        elif wire == 5:
            pos += 4
        elif wire == 1:
            pos += 8
        else:
            raise ValueError(f'unsupported wire type {wire}')


def crx_public_keys(data):
    """Extract candidate public keys from a CRX3 file's header."""
    if data[:4] != b'Cr24':
        raise ValueError('not a CRX file (magic is not "Cr24")')
    version, header_len = struct.unpack('<II', data[4:12])
    if version != 3:
        raise ValueError(f'CRX version {version}; Chrome 75+ requires CRX3')
    header = data[12:12 + header_len]
    zip_start = 12 + header_len
    keys = []
    for field, payload in iter_fields(header):
        # field 2 = sha256_with_rsa (repeated AsymmetricKeyProof)
        if field == 2:
            for sub_field, sub_payload in iter_fields(payload):
                if sub_field == 1:      # public_key
                    keys.append(sub_payload)
    return keys, data[zip_start:]


def extension_id(public_key_der):
    digest = hashlib.sha256(public_key_der).hexdigest()[:32]
    return ''.join(chr(ord('a') + int(c, 16)) for c in digest)


# --- checks -----------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('update_url', help='URL of update.xml')
    ap.add_argument('--admin-id', help='extension ID entered in the Admin console')
    args = ap.parse_args()

    print(f'\nChecking {args.update_url}\n')

    # 1. update manifest ----------------------------------------------------
    print('Update manifest')
    body, headers, status, final_url = fetch(args.update_url, 'update.xml')
    if body is None:
        return finish()

    if final_url != args.update_url:
        report(WARN, 'URL redirected', f'{args.update_url}\n  -> {final_url}\n'
                                       'Redirects can break the updater. Use the final URL.')

    head = body.lstrip()[:200].lower()
    if head[:1] != b'<' or head.startswith(b'<!doctype html') or b'<html' in head:
        report(FAIL, 'update.xml is not an update manifest',
               'This looks like an HTML page. On GitHub Pages that usually means\n'
               'the path is wrong and you are being served the 404 page - which\n'
               'Pages sometimes returns with status 200, so the fetch "succeeds".\n'
               f'First bytes: {body[:100]!r}')
        return finish()

    try:
        root = ET.fromstring(body)
    except ET.ParseError as e:
        report(FAIL, 'update.xml is not well-formed XML', e)
        return finish()

    app = root.find(f'{GUPDATE_NS}app')
    if app is None:
        app = root.find('app')          # namespace missing
        if app is not None:
            report(FAIL, 'update.xml is missing the gupdate namespace',
                   "The <gupdate> element needs "
                   "xmlns='http://www.google.com/update2/response'")
            return finish()
        report(FAIL, 'update.xml has no <app> element')
        return finish()

    appid = app.get('appid', '')
    uc = app.find(f'{GUPDATE_NS}updatecheck')
    if uc is None:
        report(FAIL, 'update.xml has no <updatecheck> element')
        return finish()
    codebase = uc.get('codebase', '')
    xml_version = uc.get('version', '')

    report(PASS, 'update.xml parsed', f'appid={appid}\nversion={xml_version}\ncodebase={codebase}')

    if len(appid) != 32 or not all('a' <= c <= 'p' for c in appid):
        report(FAIL, 'appid is not a valid extension ID',
               'Must be exactly 32 characters, each in the range a-p.')

    if not codebase.startswith('https://'):
        report(FAIL, 'codebase is not HTTPS', codebase)

    if args.admin_id:
        if args.admin_id.strip() == appid:
            report(PASS, 'appid matches the ID you entered in the Admin console')
        else:
            report(FAIL, 'appid does NOT match the Admin console ID',
                   f'update.xml : {appid}\nAdmin console: {args.admin_id.strip()}')

    # 2. the .crx -----------------------------------------------------------
    print('\nExtension package')
    crx, crx_headers, crx_status, crx_final = fetch(codebase, '.crx')
    if crx is None:
        report(INFO, 'The codebase URL is the single most common thing to get wrong.',
               'Check the filename and path in update.xml match what you published.')
        return finish()

    report(PASS, f'.crx downloaded ({len(crx):,} bytes)')

    ctype = crx_headers.get('Content-Type', '')
    nosniff = crx_headers.get('X-Content-Type-Options', '')
    report(INFO, 'Response headers', f'Content-Type: {ctype or "(none)"}\n'
                                     f'X-Content-Type-Options: {nosniff or "(none)"}')
    if nosniff.lower() == 'nosniff' and ctype != 'application/x-chrome-extension':
        report(WARN, 'nosniff is set and Content-Type is not application/x-chrome-extension',
               "Chrome's documented MIME rules are about click-to-install, not policy\n"
               'installs, so this is probably harmless here - but if every other check\n'
               'passes and it still will not install, this is the next suspect.')

    if crx[:4] != b'Cr24':
        report(FAIL, 'downloaded file is not a CRX',
               'Got HTML? That is a 404 page served with status 200.\n'
               f'First bytes: {crx[:80]!r}')
        return finish()

    try:
        keys, zip_bytes = crx_public_keys(crx)
    except ValueError as e:
        report(FAIL, 'CRX header could not be parsed', e)
        return finish()

    if not keys:
        report(FAIL, 'no public key found in the CRX header')
        return finish()

    derived = [extension_id(k) for k in keys]
    report(PASS, 'CRX3 format confirmed', f'derived ID: {", ".join(derived)}')

    # 3. the three-way agreement -------------------------------------------
    print('\nConsistency')
    if appid in derived:
        report(PASS, 'appid matches the key that signed the .crx')
    else:
        report(FAIL, 'appid does NOT match the signing key',
               f'update.xml says : {appid}\n'
               f'.crx is signed by: {", ".join(derived)}\n\n'
               'You almost certainly packed with a different .pem than the one used\n'
               'to generate the appid. Re-pack using dist/key.pem, or regenerate\n'
               'update.xml from the key you actually packed with.')

    try:
        with zipfile.ZipFile(io.BytesIO(zip_bytes)) as zf:
            manifest = json.loads(zf.read('manifest.json'))
    except Exception as e:
        report(FAIL, 'could not read manifest.json from inside the .crx', e)
        return finish()

    mver = manifest.get('version', '')
    if mver == xml_version:
        report(PASS, f'version matches inside and outside the package ({mver})')
    else:
        report(FAIL, 'version mismatch',
               f'update.xml      : {xml_version}\n'
               f'manifest.json   : {mver}\n'
               'Chrome compares these. They must be identical.')

    mupdate = manifest.get('update_url', '')
    if not mupdate:
        report(WARN, 'manifest.json has no update_url',
               'Required for self-hosted extensions. Auto-updates will not work.')
    elif 'REPLACE' in mupdate:
        report(FAIL, 'manifest.json update_url is still the placeholder', mupdate)
    elif mupdate.rstrip('/') != final_url.rstrip('/'):
        report(WARN, 'manifest.json update_url differs from where this manifest lives',
               f'manifest.json: {mupdate}\nfetched from : {final_url}')
    else:
        report(PASS, 'manifest.json update_url matches')

    if 'storage' in manifest and 'managed_schema' in manifest.get('storage', {}):
        report(PASS, 'managed_schema declared',
               'This is what makes the Managed configuration field appear.')
    else:
        report(FAIL, 'no storage.managed_schema in manifest.json',
               'Without it the Admin console will not offer Managed configuration,\n'
               'and the extension cannot receive credentials.')

    return finish()


def finish():
    fails = _results.count(FAIL)
    warns = _results.count(WARN)
    print()
    if fails:
        print(f'\033[31m{fails} check(s) failed\033[0m'
              + (f', {warns} warning(s)' if warns else ''))
        return 1
    print(f'\033[32mAll checks passed\033[0m'
          + (f', {warns} warning(s)' if warns else ''))
    print('\nHosting looks correct. If it still will not install, the problem is\n'
          'on the device side - see the triage steps in README.md.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
