/*
 * Kiosk Sign-In Assistant
 *
 * Fills the login form on the kiosk's landing page using credentials supplied
 * by Admin console policy (chrome.storage.managed), then optionally submits.
 *
 * Design notes worth reading before changing anything:
 *
 *  1. NOTHING IS HARDCODED. Credentials and selectors come from managed policy,
 *     so per-store accounts and password rotation are Admin console changes,
 *     not extension republishes.
 *
 *  2. FRAMEWORK-SAFE FILLING. Setting input.value directly does not register
 *     with React/Vue/Angular - their internal state stays empty and the form
 *     submits blank. We call the native value setter and dispatch input/change
 *     events so the framework observes the write. This is the single most
 *     common reason autofill scripts appear to work but fail on submit.
 *
 *  3. LOCKOUT GUARD. A wrong password on a shared account, retried on every
 *     page load across a fleet of kiosks, will lock that account out
 *     everywhere. Attempts are capped per boot and abandoned entirely if the
 *     page shows a login error.
 *
 *  4. SPA-AWARE. The login form often does not exist at document_idle. We
 *     observe the DOM until it appears, with a timeout.
 */

(() => {
  'use strict';

  const DEFAULTS = {
    autoSubmit: true,
    rememberMe: true,
    maxAttempts: 3,
    usernameSelector: '',
    passwordSelector: '',
    submitSelector: '',
    rememberMeSelector: '',
    successSelector: '',
    errorSelector: '',
    debug: false
  };

  const WAIT_TIMEOUT_MS = 20000;
  const SETTLE_DELAY_MS = 400;
  const ATTEMPT_KEY = 'kioskSignIn.attempts';    // password submissions
  const STEP1_KEY   = 'kioskSignIn.step1';       // username submissions

  let cfg = DEFAULTS;

  const log = (...args) => { if (cfg.debug) console.log('[kiosk-signin]', ...args); };
  const warn = (...args) => console.warn('[kiosk-signin]', ...args);

  // --- policy shape normalisation -------------------------------------------
  // The Admin console takes policy wrapped as {"key": {"Value": x}} and Chrome
  // unwraps it, so chrome.storage.managed.get() normally returns plain values.
  // We unwrap defensively anyway: if a wrapper ever survives, the alternative
  // is a silent failure that looks exactly like "no credentials configured".

  function normalize(obj) {
    const out = {};
    for (const [key, val] of Object.entries(obj || {})) {
      out[key] = (val && typeof val === 'object' && !Array.isArray(val) &&
                  Object.prototype.hasOwnProperty.call(val, 'Value'))
        ? val.Value
        : val;
    }
    return out;
  }

  // --- attempt accounting ---------------------------------------------------
  // sessionStorage is per-tab and cleared on reboot, which is the scope we
  // want: a few tries per boot, then stop and leave the form for a human.

  function getCount(key) {
    const n = parseInt(sessionStorage.getItem(key) || '0', 10);
    return Number.isFinite(n) ? n : 0;
  }

  function bumpCount(key) {
    sessionStorage.setItem(key, String(getCount(key) + 1));
  }

  const getAttempts = () => getCount(ATTEMPT_KEY);

  // --- element discovery ----------------------------------------------------

  function visible(el) {
    if (!el) return false;
    const style = window.getComputedStyle(el);
    if (style.display === 'none' || style.visibility === 'hidden') return false;
    if (el.disabled || el.readOnly) return false;
    return el.getClientRects().length > 0;
  }

  function pick(selector, fallbackSelectors) {
    if (selector) {
      const el = document.querySelector(selector);
      if (visible(el)) return el;
      log('configured selector matched nothing visible:', selector);
      return null;
    }
    for (const s of fallbackSelectors) {
      const el = [...document.querySelectorAll(s)].find(visible);
      if (el) return el;
    }
    return null;
  }

  const USERNAME_FALLBACKS = [
    'input[autocomplete="username"]',
    'input[type="email"]',
    'input[name*="user" i]',
    'input[name*="email" i]',
    'input[id*="user" i]',
    'input[id*="email" i]',
    'form input[type="text"]'
  ];

  const PASSWORD_FALLBACKS = [
    'input[autocomplete="current-password"]',
    'input[type="password"]'
  ];

  const SUBMIT_FALLBACKS = [
    'button[type="submit"]',
    'input[type="submit"]',
    'form button'
  ];

  const REMEMBER_FALLBACKS = [
    'input[type="checkbox"][name*="remember" i]',
    'input[type="checkbox"][id*="remember" i]'
  ];

  // Ticking "remember me" is what makes the session survive a reboot. Kiosk
  // sessions persist their storage between runs, so a long-lived cookie here
  // is the difference between signing in once and signing in every morning.
  function tickRememberMe() {
    if (!cfg.rememberMe) return;
    const box = pick(cfg.rememberMeSelector, REMEMBER_FALLBACKS);
    if (!box) { log('no "remember me" checkbox found'); return; }
    if (box.checked) { log('"remember me" already ticked'); return; }
    box.click();
    log('ticked "remember me"');
  }

  // Presence is not enough: these pages ship validation messages in the DOM at
  // all times and hide them with CSS. Checking presence alone would abort on
  // every load.
  function visibleMatch(selector) {
    if (!selector) return null;
    return [...document.querySelectorAll(selector)].find(visible) || null;
  }

  // Returns whichever step of the login is currently on screen, or null if
  // nothing fillable is visible yet.
  //
  //   { kind: 'password', password, username? }  single-page form, or step 2
  //   { kind: 'username', username }             step 1 of a two-step form
  //
  // Earlier versions bailed out unless a password field was present, which
  // meant two-step logins (email, Next, then password) were never touched.
  function findStep() {
    const password = pick(cfg.passwordSelector, PASSWORD_FALLBACKS);
    let username = pick(cfg.usernameSelector, USERNAME_FALLBACKS);

    if (password) {
      // A username box that sits AFTER the password box is not part of this
      // form - ignore it.
      if (username && (password.compareDocumentPosition(username) &
                       Node.DOCUMENT_POSITION_FOLLOWING)) {
        username = null;
      }
      return { kind: 'password', password, username };
    }

    if (username) return { kind: 'username', username };

    return null;
  }

  function waitFor(predicate, timeoutMs) {
    return new Promise(resolve => {
      const immediate = predicate();
      if (immediate) return resolve(immediate);

      let done = false;
      const finish = value => {
        if (done) return;
        done = true;
        observer.disconnect();
        clearTimeout(timer);
        resolve(value);
      };

      const observer = new MutationObserver(() => {
        const result = predicate();
        if (result) finish(result);
      });
      observer.observe(document.documentElement, {
        childList: true, subtree: true, attributes: true
      });

      const timer = setTimeout(() => finish(null), timeoutMs);
    });
  }

  // --- framework-safe value writing ----------------------------------------

  function setNativeValue(el, value) {
    const proto = Object.getPrototypeOf(el);
    const desc = Object.getOwnPropertyDescriptor(proto, 'value');
    if (desc && typeof desc.set === 'function') {
      desc.set.call(el, value);          // bypasses React's value shadowing
    } else {
      el.value = value;
    }
    el.dispatchEvent(new Event('input',  { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }

  async function fillField(el, value) {
    el.focus();
    setNativeValue(el, value);
    el.blur();
    el.dispatchEvent(new Event('blur', { bubbles: true }));
    await new Promise(r => setTimeout(r, 120));
  }

  function submit(form, fields) {
    const button = pick(cfg.submitSelector, SUBMIT_FALLBACKS);
    if (button) {
      log('clicking submit');
      button.click();
      return true;
    }
    if (form) {
      log('no button found, requesting form submit');
      if (typeof form.requestSubmit === 'function') form.requestSubmit();
      else form.submit();
      return true;
    }
    // Last resort: Enter in the password field.
    log('no button or form, sending Enter');
    fields.password.dispatchEvent(new KeyboardEvent('keydown', {
      key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true
    }));
    return false;
  }

  // --- main -----------------------------------------------------------------

  async function run() {
    const managed = await new Promise(resolve => {
      try {
        chrome.storage.managed.get(null, items => {
          if (chrome.runtime.lastError) {
            warn('managed storage unavailable:', chrome.runtime.lastError.message);
            return resolve({});
          }
          resolve(items || {});
        });
      } catch (e) {
        warn('managed storage threw:', e);
        resolve({});
      }
    });

    cfg = Object.assign({}, DEFAULTS, normalize(managed));

    if (!cfg.username || !cfg.password) {
      warn('no credentials in Admin console policy - nothing to do. ' +
           'Set username and password in the extension policy for this OU.');
      return;
    }

    // Already signed in? Nothing to do, and reset the counters for next time.
    if (visibleMatch(cfg.successSelector)) {
      log('success marker present, already signed in');
      sessionStorage.removeItem(ATTEMPT_KEY);
      sessionStorage.removeItem(STEP1_KEY);
      return;
    }

    // Credentials were rejected - stop before we lock the account out.
    if (visibleMatch(cfg.errorSelector)) {
      warn('login error visible on page. Stopping so the account is not locked out. ' +
           'Check the username/password in the Admin console policy.');
      sessionStorage.setItem(ATTEMPT_KEY, String(cfg.maxAttempts));
      return;
    }

    log('waiting for a login form...');
    const step = await waitFor(findStep, WAIT_TIMEOUT_MS);
    if (!step) {
      log('no login form appeared - probably already signed in, or the selectors ' +
          'do not match. Run diagnose-form.js in the console.');
      return;
    }

    // Let the page settle before writing, in case it re-renders over us.
    await new Promise(r => setTimeout(r, SETTLE_DELAY_MS));

    // ---- step 1 of a two-step form: username only ------------------------
    if (step.kind === 'username') {
      const done = getCount(STEP1_KEY);
      if (done >= cfg.maxAttempts) {
        warn(`username step submitted ${done} time(s) without reaching a password ` +
             'prompt. Stopping.');
        return;
      }
      log('two-step form: filling the username step');
      await fillField(step.username, cfg.username);
      tickRememberMe();

      if (!cfg.autoSubmit) { log('autoSubmit disabled, leaving the form filled'); return; }

      bumpCount(STEP1_KEY);
      // Submitting navigates to the password page, where this script runs again.
      submit(step.username.closest('form'), step);
      return;
    }

    // ---- password step (or a single-page form) ---------------------------
    const attempts = getAttempts();
    if (attempts >= cfg.maxAttempts) {
      warn(`giving up after ${attempts} sign-in attempt(s) this boot. ` +
           'Form left for manual sign-in.');
      return;
    }
    log('filling the password step, attempt', attempts + 1, 'of', cfg.maxAttempts);

    if (step.username) {
      await fillField(step.username, cfg.username);
    } else {
      log('username field not editable here - expected on the password step');
    }
    await fillField(step.password, cfg.password);
    tickRememberMe();

    if (!cfg.autoSubmit) { log('autoSubmit disabled, leaving the form filled'); return; }

    bumpCount(ATTEMPT_KEY);
    submit(step.password.closest('form'), step);
  }

  run().catch(e => warn('unhandled error:', e));
})();
