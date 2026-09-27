# iPolicija — plan

Goal: photo → report ready to send in ~15 seconds. You never see or click the epolicija form.
You always press the final **Send** yourself. The app never submits on its own.

## What epolicija.lt actually is (mapped 2026-09-26)

- **No public or JSON API for reports.** The only JSON bit is `GET /api/reports/report-types`;
  traffic violations are type `4003`.
- **The report wizard** is `https://www.epolicija.lt/forms/report/4003/authenticated/`, built on
  ZK 8.0.5 (Java, server-held form state). Every field change is an event POSTed to `/forms/zkau`,
  keyed by widget IDs that are random per session (e.g. `gI4C62`). Replaying raw HTTP means
  scraping IDs and mimicking ZK's request order — brittle, so we don't.
- **Login:** e-valdžios vartai (VIISP, `ap.epaslaugos.lt`) → your bank → Smart-ID →
  `POST /auth/viisp` → session cookies on epolicija. VIISP has no direct Smart-ID option
  (alternatives: mobile e-signature, ID card).
- **Logged-in form has no reCAPTCHA** (the anonymous one does).
- **All 12 steps are rendered in the page up front, just hidden**, so they can be driven through
  ZK's own client-side widgets by label.

## Field map for "car parked on the pavement"

| Step | Field (label on form) | Value the app sets |
|---|---|---|
| 1 Jūsų vaidmuo | Kaip Jūs susiję su įvykiu? | Mačiau (sužinojau apie) įvykį |
| 2 Aprašymas | Ar apie įvykį buvote pranešęs anksčiau? | Ne |
| | Kas įvyko? | Neleistinoje vietoje pastatyta transporto priemonė *(or the disabled-spot / blocking-traffic option)* |
| | Nurodykite, koks KET pažeidimas | template text, e.g. "Automobilis pastatytas ant šaligatvio" |
| 3 Vieta | Ar žinomas tikslus adresas? | Taip *(fallback: Ne → pin the photo's coordinates on the form's map)* |
| | Šalis | Lietuva (default) |
| | Vietovė | town from photo GPS; registry search, min 3 chars, **must match a registry entry** |
| | Gatvė | search by surname fragment, as the form's hint asks ("J. Basanavičiaus g." → "Basana"); free text accepted if no match |
| | Namo numeris | house number from GPS; free text accepted if no match |
| | Apibūdinkite vietą | Šaligatvis |
| | Patikslinkite vietą | optional free text (nearest landmark) |
| 4 Laikas | Ar galite nurodyti datą? | Taip, žinau, kada įvyko įvykis |
| | Data ir laikas | photo EXIF time (date-picker input; exact format to verify) |
| 5 Žala | Ar Jums padaryta žala? | Ne |
| 6 Galimas kaltininkas | Ar žinomas kaltininkas? | Nežinomas |
| | Ar dalyvavo transporto priemonė? | Taip |
| | Valstybinis numeris | OCR plate, e.g. ABC123 |
| | Rūšis, markė, modelis… | optional (colour/make if entered) |
| 7 Liudininkai | Ar žinomi kiti asmenys? | Ne |
| 8 Aplinkybės | Nurodykite įvykio aplinkybes… (textarea) | template with plate, place and time |
| 9 Vaizdo medžiaga | Ar filmavote? | Taip |
| | File upload | up to 10 files, 30 MB total; jpg/png only → convert HEIC to JPEG |
| 10 Jūsų duomenys | Name, phone*, email*, address | pre-filled from your profile; app only checks they're present |
| 11 Teisės ir atsakomybė | 5 legal declarations (witness duties, BK 236 false-report liability, Lithuanian, truthful) | **not auto-ticked silently:** shown on the app's confirm screen; your Send tap is the confirmation |
| 12 Peržiūra ir pateikimas | Submit (+ e-signature if required) | **only on your tap** |

## App flow

1. Take or pick 1–3 photos → plate (Vision OCR), location (EXIF, else GPS), time (EXIF, else now).
2. One screen: plate, violation type (pavement pre-selected), address, time, photos. Edit if needed.
3. Tap **Prepare**: a hidden web view fills steps 1–11 and stops at the review step.
4. The app shows the site's own review text plus the declarations. Tap **Send** → submit
   (Smart-ID confirm on your phone if the site asks for a signature).
5. If logged out: a visible web view shows the VIISP login once; cookies persist afterwards.

## Architecture (Swift, no third-party deps)

- `CaptureService` — PhotosPicker/camera, EXIF (time, GPS), HEIC→JPEG, resize under 30 MB.
- `PlateOCR` — Vision, LT plate regex, picks the best match across all photos.
- `PhotoMetadata` ✅ — reads GPS + capture time from the original photo bytes (EXIF).
  Photo GPS wins; current location is used only for photos taken in the last 15 minutes
  (e.g. in-app camera); otherwise the address is left for you to type.
- `AddressResolver` ✅ — CLGeocoder (Lithuanian locale) → Vietovė / Gatvė / Namo numeris,
  plus the street search fragment the form expects.
- `EpolicijaSession` — WKWebView with persistent `WKWebsiteDataStore.default()`. Detects
  logged-in state by loading the form URL and checking it didn't redirect to login.
- `FormDriver` — injected JS helpers working through ZK widgets:
  - `pick(label)` for radio/checkbox, `fill(label, text)` for textbox/textarea,
    `search(label, text, choice)` for server-backed selects, `setDate(label, date)`,
    `attach(files)` (File objects via `DataTransfer` → uploader input), `next()` via
    "TĘSTI PILDYMĄ", `errors()` reads the form's validation messages after each step.
  - Every step: set fields → `next()` → assert no errors and the expected next step title.
    Any mismatch → stop, open the half-filled form visibly so you can finish by hand.
- `ReportStore` — local history of sent reports (plate, place, time, epolicija report number).

## Phases

- **Phase 0 — mapping** ✅ fields above. Still open (need a real report to see):
  final review/submit screen, whether an e-signature step appears, date-picker format,
  address-search behaviour, how long the login session lasts.
- **Phase 1 — FormDriver dry run.** Fill steps 1–11 in a visible web view on test data,
  stop at review, screenshot. **Never submitted during development.** First real submit is
  your own next report, sent by you.
- **Phase 2 — capture screen + hidden driver + confirm screen.**
- **Phase 3 — hardening:** step/label drift detection, retries, history, login-expiry handling.

## Risks

- Form changes break the driver → it fails loudly and falls back to the visible form.
- The address dropdowns search a registry; GPS-derived street names may need fuzzy matching.
- File upload from injected JS (`DataTransfer`) must be verified in WKWebView; fallback is
  simulating a drop on the "Įtempkite failą" area.
- Unofficial automation of a government site: one report at a time from your account,
  same as by hand, but it can break at any time.

## Test run 2026-09-27 (browser panel, test data, never submitted)

Driver: `iPolicija/epolicija-driver.js`. Verified sequence for a witness report of a parked car:

1. Jūsų vaidmuo → pick "Mačiau (sužinojau apie) įvykį" → next
2. Aprašymas → "Ar apie įvykį buvote pranešęs anksčiau?" = Ne; "Kas įvyko?" = "Neleistinoje vietoje
   pastatyta transporto priemonė" (no extra text field for this option) → next
3. Vieta → "Ar Jums žinomas tikslus įvykio adresas?" = Taip; Šalis defaults to Lietuva;
   search("Vietovė", "Vilnius") → registry returns "Vilnius (Vilniaus miesto sav.)";
   search("Gatvė", "Gedimi") → "Gedimino pr."; search("Namo numeris", "1") → "1"
   (registry lists house numbers; each field unlocks after the previous one);
   "Apibūdinkite vietą" = Šaligatvis → next
4. Laikas → "Taip, žinau, kada įvyko įvykis"; setDate("Data ir laikas", ...) → shows "YYYY-MM-DD HH:mm" → next
5. Žala → information text only for a witness, nothing to fill → next
6. Galimas kaltininkas → "Ar žinomas įvykio galimas kaltininkas (asmuo)?" = Nežinomas;
   fill("Valstybinis numeris", plate) (no "was a vehicle involved" question in this form) → next
7. Liudininkai → "Ar Jums žinomi kiti asmenys…?" = Ne → next
8. Įvykio aplinkybės → textarea (not filled in the test — stopped here)

Still unverified: steps 8–12 (description text, photo upload, Jūsų duomenys, declarations, review/submit).
Login session expired within a day (logged in 2026-09-26 21:46, logged out by 2026-09-27 18:55).

## In-app flow (built 2026-09-27)

- `EpolicijaController` — WKWebView with persistent cookies; injects `epolicija-driver.js`;
  opens the form, detects "not logged in" (redirect away from the form) and shows the login page;
  once the form loads, runs `__ip.fillReport(payload)` via `callAsyncJavaScript`.
- `fillReport` fills steps 1–10 (photo via the uploader's own `_uploadFile`, since its change
  listener only exists after a click) and stops at "Jūsų teisės, pareigos ir atsakomybė".
- `ReportSheet` — the web view with a progress overlay while filling, a login banner, and a
  "your turn" banner at the declarations. The person ticks the declarations and taps PATEIKTI.
  On any failure the half-filled form stays visible to finish by hand.
- First real report = first end-to-end test (photo upload, final screen, signing unknown).

## Login + declarations (2026-09-27)

- Declarations on step 11 are ticked automatically (on request); the app clicks
  "Peržiūrėti ir pateikti" (the step-11 label of the next button) to open the summary page and stops.
  It never clicks "Pateikti policijai" (the submit button on the summary page).
- Login automation, no credentials stored: on epolicija.lt/report the app clicks
  "Pažeistos Kelių eismo taisyklės" → "Prisijungti per e. valdžios vartus". Bank choice, bank login
  and Smart-ID stay manual (by choice). On the gateway's "Asmens duomenų perdavimas" page
  (route personalDataTransfer) the app clicks "Prisijungti".
- The gateway also has a direct "Smart ID" login (i18n keys login.smartId.*) that asks for the
  personal code; it isn't offered for epolicija as of today.
- SEB: after Smart-ID, SEB asks to agree to pass data to the gateway ("Asmens duomenų gavėjas:
  Valstybės skaitmeninių sprendimų agentūra" → "Sutinku"). On *.seb.lt the app watches for that
  page (up to 3 min, it appears without a page load) and clicks "Sutinku" only when that recipient
  is named. Other banks: not handled yet.
- 2026-09-27: first full run on the phone worked end to end (login → fill → summary page).
