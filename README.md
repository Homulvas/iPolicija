# iPolicija

An iPhone app that turns a photo of a badly parked car into a ready-to-send
[epolicija.lt](https://www.epolicija.lt) traffic-violation report in seconds instead of minutes.

You take or pick a photo. The app reads the licence plate, takes the address and time from the
photo, fills in the whole epolicija form for you, and stops on the final summary page. **You read
it and tap “Pateikti policijai” yourself — the app never submits a report.**

> Unofficial personal project. Not affiliated with or endorsed by the Lithuanian Police.
> It drives the public epolicija.lt website the same way a person would; if the site changes,
> parts of it will break.

## How it works

1. **Photo** — take one in the app or choose from the library.
2. **On the phone, no network:**
   - licence plate via Apple Vision OCR (Lithuanian formats + a fallback for foreign/personalised plates);
   - location and time from the photo's EXIF/GPS, reverse-geocoded into Lithuanian address parts;
   - violation type (blocked pavement by default) and a generated Lithuanian description.
3. **Prepare report on epolicija.lt** opens the site inside the app:
   - **Login (if needed):** the app selects the traffic report and “Prisijungti per e. valdžios vartus”.
     You choose your bank and confirm Smart-ID. For SEB the app clicks the bank's “Sutinku” consent,
     then “Prisijungti” on the gateway's “Asmens duomenų perdavimas” page.
   - **Filling:** role, what happened, address (via the site's address-registry search), date/time,
     plate, witnesses, description, photo upload, declarations — then opens the summary page.
4. **You** review the summary and tap **Pateikti policijai**.

If any step fails, the half-filled form stays on screen with a message saying where it stopped,
so you can finish by hand.

## Privacy and safety

- No passwords, personal codes or bank credentials are stored or typed by the app. Login state
  lives only in the app's own web-view cookies, as in a normal browser.
- Plate reading, geocoding and description generation happen on the device.
- The app only ever clicks “Tęsti pildymą” / “Peržiūrėti ir pateikti”; submitting is always manual.
- The SEB “Sutinku” click only happens on `seb.lt` when the page names
  “Valstybės skaitmeninių sprendimų agentūra” as the data recipient.

## Project layout

| File | What it does |
|---|---|
| `iPolicija/ContentView.swift` | Main screen: photo, plate, violation type, address, time, description, “Prepare report”. |
| `iPolicija/PlateOCR.swift` | Vision OCR + plate ranking (LT standard/EV/taxi/historic/temporary/military, generic fallback). |
| `iPolicija/PhotoMetadata.swift` | Reads GPS and capture time from the original photo bytes. |
| `iPolicija/AddressResolver.swift` | Reverse geocoding (Lithuanian locale) and the street search fragment the form expects. |
| `iPolicija/ReportData.swift` | Report model, violation → form option mapping, generated description. |
| `iPolicija/EpolicijaController.swift` | In-app WKWebView: persistent login, login helpers, runs the form filler. |
| `iPolicija/ReportSheet.swift` | The epolicija sheet: progress overlay and login / ready / error banners. |
| `iPolicija/epolicija-driver.js` | Injected script that fills the ZK-based form by visible labels. |
| `PLAN.md` | Design notes and everything learned about the epolicija form. |

### Why a web view and not an API?

epolicija's report form has no JSON API. It is a server-rendered ZK application whose widget IDs
change on every page load, so the app drives the real page through its own JavaScript widgets
(radio buttons, selectize address search, bootstrap date picker, the uploader's upload routine),
finding every field by its label. Details in `PLAN.md`.

## Building

Requirements: a Mac with Xcode 16+, an iPhone on iOS 18.2+.

1. Open `iPolicija.xcodeproj`.
2. Under *Signing & Capabilities*, pick your team (a free Apple ID works).
3. Select your iPhone and press **Run**. The first time, trust the developer certificate on the
   phone: *Settings → General → VPN & Device Management*.

With a free Apple ID the app stops launching after 7 days; press **Run** again to renew. After the
first cable install, Xcode can install over Wi-Fi when the phone and Mac are on the same network.

Debug builds show the text the plate reader found under the plate field, and the web view can be
inspected from Safari on the Mac (*Develop → your iPhone*).

## Limitations

- Only the “KET pažeidimas” (traffic violation) report as a witness, one photo per report.
- Bank-specific consent automation exists for SEB only.
- The epolicija login session lasts less than a day, so expect a bank + Smart-ID login about daily.
- Foreign plates are matched by shape only, without format-based OCR correction.
