/* ---------------------------------------------------------------------------
 * Paste this whole file into the DevTools console ON THE LOGIN PAGE.
 *
 * It reports what the extension can see: whether the content script is even
 * running, what managed configuration arrived, and every visible input with a
 * suggested CSS selector you can paste straight into the Admin console.
 *
 * On the kiosk: Shift+Ctrl+i opens DevTools (kiosk troubleshooting tools must
 * be enabled). You can also run this in normal Chrome on the same login page -
 * the form is identical, and it is easier to copy the output from there.
 * ------------------------------------------------------------------------- */

(async () => {
  const line = '-'.repeat(72);
  console.log('%c[diagnose] Kiosk Sign-In Assistant', 'font-weight:bold;font-size:14px');
  console.log(line);

  // 1. Where are we? -------------------------------------------------------
  console.log('URL   :', location.href);
  console.log('Origin:', location.origin);
  console.log('Frames:', window.top === window ? 'top frame' : 'IN AN IFRAME');
  if (window.top !== window) {
    console.warn('This form is inside an iframe. The content script needs all_frames:true '
               + '(it has it) AND the iframe origin must be in host_permissions.');
  }

  // 2. Is the content script running? --------------------------------------
  console.log(line);
  const marker = document.documentElement.dataset.kioskSigninSeen;
  console.log('Content script marker:', marker || '(not set - see note)');
  console.log('If you see no "[kiosk-signin]" lines above this, the content script is NOT '
            + 'injecting on this origin. Check host_permissions / matches cover ' + location.origin);

  // 3. Managed configuration ----------------------------------------------
  console.log(line);
  if (typeof chrome !== 'undefined' && chrome.storage && chrome.storage.managed) {
    try {
      const cfg = await new Promise(r => chrome.storage.managed.get(null, r));
      const shown = Object.assign({}, cfg);
      if (shown.password) shown.password = '(set, ' + String(shown.password).length + ' chars)';
      console.log('chrome.storage.managed:', shown);
      if (!cfg || !Object.keys(cfg).length) {
        console.warn('EMPTY. The Managed configuration is not reaching the extension. '
                   + 'Check chrome://policy, and that the JSON uses the { "Value": ... } wrapper.');
      }
    } catch (e) {
      console.warn('could not read managed storage:', e.message);
    }
  } else {
    console.log('chrome.storage.managed not available here '
              + '(expected if you are running this in a normal tab rather than as the extension)');
  }

  // 4. What inputs exist? --------------------------------------------------
  console.log(line);

  const visible = el => {
    const s = getComputedStyle(el);
    return s.display !== 'none' && s.visibility !== 'hidden'
        && !el.disabled && el.getClientRects().length > 0;
  };

  const cssEscape = s => (window.CSS && CSS.escape) ? CSS.escape(s) : s;

  const suggest = el => {
    if (el.id) return `#${cssEscape(el.id)}`;
    for (const attr of ['data-testid', 'data-test', 'name', 'autocomplete', 'aria-label']) {
      const v = el.getAttribute(attr);
      if (v) {
        const sel = `${el.tagName.toLowerCase()}[${attr}="${v}"]`;
        if (document.querySelectorAll(sel).length === 1) return sel;
      }
    }
    if (el.type) {
      const sel = `input[type="${el.type}"]`;
      if (document.querySelectorAll(sel).length === 1) return sel;
    }
    return '(no stable selector - inspect manually)';
  };

  const inputs = [...document.querySelectorAll('input, button, [role="button"]')]
    .filter(visible);

  if (!inputs.length) {
    console.warn('No visible inputs or buttons found. The form may still be rendering - '
               + 'wait a second and run this again.');
  }

  console.table(inputs.map(el => ({
    tag: el.tagName.toLowerCase(),
    type: el.type || '',
    name: el.name || '',
    id: el.id || '',
    autocomplete: el.getAttribute('autocomplete') || '',
    placeholder: el.placeholder || '',
    label: (el.getAttribute('aria-label') || el.textContent || '').trim().slice(0, 30),
    suggestedSelector: suggest(el)
  })));

  // 5. Best guesses --------------------------------------------------------
  console.log(line);
  const pw = inputs.find(el => el.type === 'password');
  const user = inputs.find(el =>
    el.type === 'email' ||
    /user|email|login/i.test(`${el.name} ${el.id} ${el.getAttribute('autocomplete') || ''}`));
  const submit = inputs.find(el =>
    el.type === 'submit' || el.tagName === 'BUTTON' || el.getAttribute('role') === 'button');

  console.log('Suggested Managed configuration additions:');
  const out = {};
  if (user) out.usernameSelector = { Value: suggest(user) };
  if (pw) out.passwordSelector = { Value: suggest(pw) };
  if (submit) out.submitSelector = { Value: suggest(submit) };
  console.log(JSON.stringify(out, null, 2));

  if (!pw && user) {
    console.warn('TWO-STEP FORM: a username field is visible but no password field. '
               + 'The extension must fill and submit the username first, then wait for '
               + 'the password step. Requires extension 1.0.3 or later.');
  }
  if (!pw && !user) {
    console.warn('Neither a username nor a password field is visible yet.');
  }
  console.log(line);
})();
