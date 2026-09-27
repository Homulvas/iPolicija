// Helpers for filling the epolicija.lt report wizard (ZK 8 + selectize + bootstrap-datetimepicker).
// Injected into the app's hidden WKWebView. Fields are found by their visible labels, not IDs,
// because ZK generates new widget IDs on every page load.
//
// Verified on 2026-09-27 against /forms/report/4003/authenticated/ (steps 1–7):
//   pick (radios/checkboxes), search (registry dropdowns: Vietovė, Gatvė, Namo numeris),
//   setDate (Data ir laikas, format "YYYY-MM-DD HH:mm"), fill (text fields), next (TĘSTI PILDYMĄ).
// Not yet verified: file upload (attach), steps 8–11 in fillReport, review/submit.
window.__ip = (() => {
  const norm = s => (s || '').replace(/\s+/g, ' ').trim().replace(/\*$/, '').trim();
  const visible = e => !!(e && e.offsetParent);
  const sleep = ms => new Promise(r => setTimeout(r, ms));

  // Wait until ZK has no request in flight.
  async function idle() {
    await sleep(150);
    for (let i = 0; i < 100; i++) {
      if (!(window.zAu && zAu.processing && zAu.processing())) return;
      await sleep(100);
    }
  }

  // Exact label match first; long labels may be given as a prefix.
  function findQuestion(text) {
    const leaves = [...document.querySelectorAll('span,label,legend,div,p')]
      .filter(e => e.children.length === 0 && visible(e));
    return leaves.find(e => norm(e.textContent) === text)
      || leaves.find(e => norm(e.textContent).startsWith(text));
  }

  // Waits for the question to become visible: ZK renders and animates steps after the DOM exists.
  async function question(text, timeoutMs = 5000) {
    const until = Date.now() + timeoutMs;
    for (;;) {
      const q = findQuestion(text);
      if (q) return q;
      if (Date.now() > until) throw new Error('Question not visible: ' + text);
      await sleep(150);
    }
  }

  function exists(text) {
    return !!findQuestion(text);
  }

  async function groupOf(text) {
    let n = await question(text);
    while (n && !(n.classList && n.classList.contains('form-group'))) n = n.parentElement;
    if (!n) throw new Error('No form-group for: ' + text);
    return n;
  }

  // Radio / checkbox option under a question.
  async function pick(q, option) {
    const input = [...(await groupOf(q)).querySelectorAll('input[type=radio],input[type=checkbox]')]
      .find(i => norm(i.parentElement.textContent) === option);
    if (!input) throw new Error(`Option "${option}" not under "${q}"`);
    if (!input.checked) input.click();
    await idle();
    return input.checked;
  }

  // Text field or textarea under a label.
  async function fill(label, text) {
    const el = [...(await groupOf(label)).querySelectorAll('textarea, input[type=text]')].find(visible);
    if (!el) throw new Error('No text field for ' + label);
    el.focus();
    el.value = text;
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    el.blur();
    el.dispatchEvent(new Event('blur', { bubbles: true }));
    await idle();
    return el.value;
  }

  // Registry names vs map names: the registry drops the "g." (street) suffix but keeps other types
  // ("M. K. Čiurlionio" vs "M. K. Čiurlionio g."; "Gedimino pr." in both). Compare the core name.
  const STREET_TYPES = ['g.', 'pr.', 'al.', 'pl.', 'skg.', 'skv.', 'kel.', 'tak.', 'a.', 'krant.'];
  function coreName(name) {
    return norm(name).toLowerCase().split(' ')
      .filter(w => !STREET_TYPES.includes(w) && !(w.length <= 3 && w.endsWith('.')))
      .join(' ');
  }
  function bestOption(opts, wanted) {
    const w = norm(wanted).toLowerCase();
    const withoutG = w.replace(/\s+g\.$/, '');
    const exact = opts.find(o => norm(o.text).toLowerCase() === w)
      || opts.find(o => norm(o.text).toLowerCase() === withoutG);
    if (exact) return exact;
    const core = coreName(wanted);
    const sameCore = opts.filter(o => coreName(o.text) === core);
    return sameCore.length === 1 ? sameCore[0] : null;
  }

  // Server-backed selectize dropdown: type a query, wait for options, choose the matching one.
  // If nothing matches, the typed text is cleared — these fields accept free text on blur, and a
  // leftover fragment would be saved as an "unrecognised address".
  async function search(label, typed, choose) {
    const sel = (await groupOf(label)).querySelector('select');
    const s = sel && sel.selectize;
    if (!s) throw new Error('No search dropdown for ' + label);
    if (sel.disabled || s.isDisabled) throw new Error(label + ' is disabled');
    s.focus();
    const inp = s.$control_input[0];
    inp.value = typed;
    inp.dispatchEvent(new Event('input', { bubbles: true }));
    inp.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true, key: typed.slice(-1) }));
    let opts = [];
    for (let i = 0; i < 30; i++) {
      await sleep(200); await idle();
      opts = Object.values(s.options).filter(o => o.value !== '');
      if (opts.length) break;
    }
    const match = bestOption(opts, choose);
    if (!match) {
      inp.value = '';
      if (s.setTextboxValue) s.setTextboxValue('');
      inp.dispatchEvent(new Event('input', { bubbles: true }));
      if (s.close) s.close();
      s.blur();
      await idle();
      return { ok: false, options: opts.map(o => o.text) };
    }
    s.setValue(match.value);
    s.blur();
    await sleep(300); await idle();
    return { ok: true, chosen: match.text };
  }

  // bootstrap-datetimepicker; isoLocal = 'YYYY-MM-DDTHH:mm'. The form shows "YYYY-MM-DD HH:mm".
  async function setDate(label, isoLocal) {
    const inp = [...(await groupOf(label)).querySelectorAll('input')].find(visible);
    const $i = jQuery(inp);
    const dtp = $i.data('DateTimePicker') || $i.parent().data('DateTimePicker');
    if (!dtp) throw new Error('No date picker for ' + label);
    dtp.date(moment(isoLocal, 'YYYY-MM-DDTHH:mm'));
    inp.dispatchEvent(new Event('change', { bubbles: true }));
    inp.dispatchEvent(new Event('blur', { bubbles: true }));
    await idle(); await sleep(300); await idle();
    return inp.value;
  }

  // Upload photos into the visible file uploader. files = [{ name, type, base64 }].
  async function attach(files) {
    const input = [...document.querySelectorAll('input[type=file]')].find(i => {
      let n = i;
      for (let k = 0; k < 6 && n; k++) { n = n.parentElement; if (n && visible(n)) return true; }
      return false;
    });
    if (!input) throw new Error('No visible file uploader');
    const dt = new DataTransfer();
    for (const f of files) {
      const bytes = Uint8Array.from(atob(f.base64), c => c.charCodeAt(0));
      dt.items.add(new File([bytes], f.name, { type: f.type || 'image/jpeg' }));
    }
    // The uploader (wgt.af.Uploader) only attaches its "change" listener after its button is
    // clicked, so hand the files straight to its upload routine (same path as drag & drop).
    const uploader = zk.Widget.$(input);
    if (!uploader || typeof uploader._uploadFile !== 'function') throw new Error('Uploader widget not found');
    uploader._uploadFile(dt.files);
    // Wait until every file name shows up on the page (upload finished).
    for (let i = 0; i < 150; i++) {
      await sleep(200); await idle();
      const text = document.body.innerText;
      if (files.every(f => text.includes(f.name))) return { ok: true };
    }
    return { ok: false, error: 'Upload did not finish in 30 s' };
  }

  // Name of the current wizard step (the heading after "Vedlio žingsniai").
  function currentStep() {
    const h = stepTitle();
    const i = h.indexOf('Vedlio žingsniai');
    return i >= 0 ? h[i + 1] : null;
  }

  function stepTitle() {
    return [...document.querySelectorAll('h1,h2,h3,h4')].filter(visible).map(e => norm(e.textContent));
  }

  function errors() {
    return [...document.querySelectorAll('.z-errorbox, .invalid-feedback, .has-error, .text-danger, .z-notification, .alert-danger')]
      .filter(visible).map(e => norm(e.textContent)).filter(Boolean);
  }

  // Move to the next step: "Tęsti pildymą" on steps 1–10, "Peržiūrėti ir pateikti" (opens the
  // summary page) on the declarations step. Exact labels only — never "Pateikti policijai".
  const NEXT_LABEL = /^(Tęsti pildymą|Peržiūrėti ir pateikti)$/i;
  async function next() {
    const b = [...document.querySelectorAll('button')]
      .find(e => visible(e) && NEXT_LABEL.test(norm(e.textContent)));
    if (!b) throw new Error('Next button not visible');
    const before = currentStep();
    b.click();
    await idle();
    // Wait for the next step to render (the review page is slow) or for validation errors.
    for (let i = 0; i < 30; i++) {
      await sleep(200); await idle();
      if (currentStep() !== before || errors().length) break;
    }
    return { errors: errors(), headings: stepTitle() };
  }

  // Debug: every visible question on the current step with its options/inputs.
  function visibleFields() {
    const out = [];
    document.querySelectorAll('.form-group').forEach(g => {
      if (!visible(g)) return;
      const q = [...g.querySelectorAll('span,label')].find(e => e.children.length === 0 && visible(e) && norm(e.textContent));
      const inputs = [...g.querySelectorAll('input,textarea,select')];
      const opts = inputs.filter(i => (i.type === 'radio' || i.type === 'checkbox') && visible(i.parentElement))
        .map(i => (i.checked ? '☑' : '☐') + norm(i.parentElement.textContent));
      out.push({ q: q && norm(q.textContent), opts });
    });
    return out.filter(x => x.q || x.opts.length);
  }

  // Fill the witness report for a parked car, tick the declarations and stop on the review page
  // ("Peržiūra ir pateikimas"). Submitting is always left to the person.
  //
  // d = { whatHappened, placeType, city, street, streetSearch, house, extraPlace,
  //       dateTime ('YYYY-MM-DDTHH:mm'), plate, vehicle, description, hasVideo, photos: [{name,type,base64}] }
  //
  // Returns { ok, step, log, error?, notes } — on failure the form stays where it stopped,
  // so the app can show it and the person can finish by hand.
  async function fillReport(d) {
    const log = [];
    const notes = [];
    const expect = async name => {
      for (let i = 0; i < 33 && currentStep() !== name; i++) await sleep(150);
      if (currentStep() !== name) throw new Error(`Expected step "${name}", got "${currentStep()}"`);
    };
    const advance = async () => {
      const from = currentStep();
      const r = await next();
      log.push({ from, to: currentStep(), errors: r.errors });
      if (r.errors.length) throw new Error(`${from}: ${r.errors.join('; ')}`);
      if (currentStep() === from) throw new Error(`Stuck on "${from}"`);
    };

    try {
      await expect('Jūsų vaidmuo įvykyje');
      await pick('Kaip Jūs susiję su įvykiu?', 'Mačiau (sužinojau apie) įvykį');
      await advance();

      await expect('Aprašymas');
      await pick('Ar apie įvykį buvote pranešęs anksčiau?', 'Ne');
      await pick('Kas įvyko?', d.whatHappened);
      await advance();

      await expect('Vieta');
      await pick('Ar Jums žinomas tikslus įvykio adresas?', 'Taip');
      const place = [];
      const city = await search('Vietovė', d.city, d.city);
      if (!city.ok) throw new Error(`Town "${d.city}" not in the address registry (${city.options.join(', ') || 'no matches'})`);
      if (d.street) {
        const street = await search('Gatvė', d.streetSearch || d.street, d.street);
        if (street.ok && d.house) {
          const house = await search('Namo numeris', d.house, d.house);
          if (!house.ok) { place.push(`namo nr. ${d.house}`); notes.push(`House ${d.house} not in registry`); }
        } else if (!street.ok) {
          place.push(d.house ? `${d.street} ${d.house}` : d.street);
          notes.push(`Street "${d.street}" not in registry — written into "Patikslinkite vietą"`);
        }
      }
      await pick('Apibūdinkite vietą', d.placeType);
      if (d.extraPlace) place.push(d.extraPlace);
      if (place.length) await fill('Patikslinkite vietą', place.join(', '));
      await advance();

      await expect('Laikas');
      await pick('Ar galite nurodyti įvykio datą?', 'Taip, žinau, kada įvyko įvykis');
      await setDate('Data ir laikas', d.dateTime);
      await advance();

      await expect('Žala');
      if (exists('Ar Jums padaryta žala?')) await pick('Ar Jums padaryta žala?', 'Ne');
      await advance();

      await expect('Galimas kaltininkas');
      await pick('Ar žinomas įvykio galimas kaltininkas (asmuo)?', 'Nežinomas');
      await fill('Valstybinis numeris', d.plate);
      if (d.vehicle) await fill('Transporto priemonės rūšis, markė, modelis', d.vehicle);
      await advance();

      await expect('Liudininkai');
      await pick('Ar Jums žinomi kiti asmenys, galintys suteikti reikšmingos informacijos apie įvykį?', 'Ne');
      await advance();

      await expect('Įvykio aplinkybės');
      await fill('Nurodykite įvykio aplinkybes', d.description);
      await advance();

      await expect('Vaizdo medžiaga ir kiti dokumentai');
      // "Did you film it / know who could have?" — Ne for photos only, Taip when a video is attached.
      const filmedQ = 'Ar Jūs filmavote įvykį arba žinote, kas galėjo filmuoti';
      const filmedEl = await question(filmedQ, 3000).catch(() => null);
      if (filmedEl) await pick(norm(filmedEl.textContent), d.hasVideo ? 'Taip' : 'Ne');
      if (d.photos && d.photos.length) {
        const up = await attach(d.photos);
        if (!up.ok) throw new Error(up.error);
      }
      await advance();

      await expect('Jūsų duomenys');   // pre-filled from the profile
      await advance();

      // Declarations: ticked on request; the person reads them on the review page and submits.
      await expect('Jūsų teisės, pareigos ir atsakomybė');
      const declarations = [];
      const boxes = [...document.querySelectorAll('.form-group input[type=checkbox]')]
        .filter(i => visible(i.parentElement) && !/cookies/i.test(i.id));
      for (const box of boxes) {
        if (!box.checked) { box.click(); await idle(); }
        declarations.push(norm(box.parentElement.textContent));
      }
      await sleep(500); await idle();   // let the ticks reach the server before moving on
      try {
        await advance();   // "Peržiūrėti ir pateikti" → summary page; never "Pateikti policijai"
      } catch (first) {
        // Retry once: re-tick anything that didn't stick, give it a moment, click again.
        for (const box of boxes) if (!box.checked) { box.click(); await idle(); }
        await sleep(1000); await idle();
        await advance();
      }

      window.scrollTo(0, 0);
      return { ok: true, step: currentStep(), log, notes, declarations };
    } catch (e) {
      return { ok: false, step: currentStep(), log, notes, error: String(e && e.message || e) };
    }
  }

  return { idle, question, groupOf, exists, pick, fill, search, setDate, attach, next, errors,
           stepTitle, currentStep, visibleFields, fillReport };
})();


// Login helpers. No credentials are stored or typed: the person picks their bank and confirms
// Smart-ID; these only click the steps around that.
window.__ipLogin = (() => {
  const norm = s => (s || '').replace(/\s+/g, ' ').trim();
  const visible = e => !!(e && e.offsetParent);
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  async function waitFor(fn, ms) {
    const until = Date.now() + ms;
    for (;;) {
      const r = fn();
      if (r) return r;
      if (Date.now() > until) return null;
      await sleep(200);
    }
  }
  // Innermost visible element whose text matches (click events bubble up to the real handler).
  const byText = (selector, re) =>
    [...document.querySelectorAll(selector)]
      .filter(e => visible(e) && re.test(norm(e.textContent) || norm(e.value))).pop();

  // epolicija.lt/report: choose "Pažeistos Kelių eismo taisyklės", then "Prisijungti per e. valdžios vartus".
  async function startEpolicijaLogin() {
    const reportType = await waitFor(() => byText('*', /^Pažeistos Kelių eismo taisyklės$/i), 10000);
    if (!reportType) return { ok: false, error: 'Report type not found' };
    reportType.click();
    const login = await waitFor(() => byText('button,a,span,div', /^Prisijungti per e\. valdžios vartus$/i), 5000);
    if (!login) return { ok: false, error: 'Login button not found' };
    login.click();
    return { ok: true };
  }

  // Government gateway "Asmens duomenų perdavimas" page after the bank: click "Prisijungti".
  async function confirmDataTransfer() {
    const onPage = await waitFor(() => /Asmens duomenų perdavimas/.test(document.body.innerText), 15000);
    if (!onPage) return { ok: false, skipped: true };
    const button = await waitFor(() => byText('button,a', /^Prisijungti$/i), 5000);
    if (!button) return { ok: false, error: '"Prisijungti" not found' };
    button.click();
    return { ok: true };
  }

  // SEB bank: after Smart-ID it asks to agree to pass your data to the gateway. Click "Sutinku" only
  // when the recipient is the gateway operator. The page appears without a new page load, so watch
  // for up to 3 minutes.
  async function confirmSebConsent() {
    if (window.__ipSebWatching) return { ok: false, skipped: true };
    window.__ipSebWatching = true;
    try {
      const button = await waitFor(() => {
        const text = document.body ? document.body.innerText : '';
        if (!/Asmens duomenų gavėjas/.test(text) || !/Valstybės skaitmeninių sprendimų agentūra/.test(text)) return null;
        return byText('button,a,input[type=submit],input[type=button]', /^Sutinku$/i);
      }, 180000);
      if (!button) return { ok: false, error: 'SEB consent page not shown' };
      button.click();
      return { ok: true };
    } finally {
      window.__ipSebWatching = false;
    }
  }

  return { startEpolicijaLogin, confirmDataTransfer, confirmSebConsent };
})();
