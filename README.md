# Parts Inventory for iPhone, iPad and Mac

A native SwiftUI version of the [parts inventory](https://geekychris.github.io/tools/parts-inventory/)
web tool: keep track of electronic components, scan supplier bag labels, and identify a part from a
photo — by the markings printed on it or, when there are none, by how it looks. The data is stored
with SwiftData and synced through your private iCloud database.

## What it does

- **Parts** — a searchable inventory with the web tool's parametric search (`10k 0603 1%`,
  `100n 16V`, `cat:caps`, `loc:drawer`, `low`), stock changes with history, locations, suppliers,
  datasheets and photos.
- **Scan** — Digi-Key, Mouser (ECIA format 06 Data Matrix) and LCSC (QR) bag labels, live with the
  camera, from a photo, or typed in by a USB scanner. A bag adds stock to the matching part or makes
  a new one.
- **Cameras** — any connected camera, on every device: the Mac's own, a USB webcam or microscope,
  Continuity Camera (an iPhone) and Desk View; the iPhone's back and front cameras; a USB-C camera on an
  iPad. Pick one above the picture (or in Settings); the choice is remembered, and cameras plugged in or
  unplugged are picked up straight away.
- **iPhone camera handoff (Mac)** — *From iPhone* (in Identify and beside the live camera, or File ›
  Import From Device) uses Continuity Camera's Take Photo: the iPhone's own camera opens on the phone,
  with zoom, macro and tap to focus, and the photo goes straight to Identify. Best for tiny markings —
  a Mac app can show the iPhone's live picture but can't zoom it.
- **Identify** — a photo of any part:
  1. barcodes (a bag label goes straight to receiving);
  2. the markings, read with Vision OCR (tried at four rotations when upright reads nothing useful)
     and matched against a built-in list of ~160 hobby parts and your own inventory, allowing for
     OCR look-alikes (O/0, I/1, S/5…), suffixes and split words;
  3. when the markings aren't enough, **how it looks**: Apple's MobileCLIP-S2 on the Neural
     Engine, in two steps — which of ~45 kinds of part (pot, relay, stepper, push button…), then,
     only as far as it looks like a board, which board;
  4. **Apple Intelligence** (the on-device Foundation Models) reads the OCR text into a part number,
     maker, description, category and package. Its reading is only trusted when its part number is
     actually in the text.
  Unknown numbers get search links (Octopart, Digi-Key, Mouser, LCSC, eBay, AllDatasheet).
- **Batch add** — for adding many parts: keep taking photos (*iPhone: Take Photo* / ⌘T on a Mac — with
  *Keep the iPhone camera open* the phone's camera opens again after each photo — the live camera, or a
  pile of photos or files). Each is read, identified and looked up at Digi-Key and Mouser while you carry
  on; Return (*Add & next*) adds it with both suppliers' numbers, prices and stock, the datasheet, package,
  parameters and the photo (or adds to the stock of a part you already have), ⌘⌫ skips, ⌘↑/⌘↓ move. When the
  queue is done, the photo source opens again. *Add sure matches without asking* adds a photo straight away
  when the number read on the part matches exactly one listing. In Identify, *Add and take another* (⌘Return)
  does the same for one part at a time. (`partlookup --read "<markings>" <number>` shows the batch decision.)
- **Part number lookup** — *Look up online* on a part, on an Identify result, or while adding a part
  asks Digi-Key's and Mouser's APIs at once: manufacturer, description, stock, price breaks, datasheet,
  package and parameters. *Fill in from this* fills only the empty fields and adds the supplier's part
  number with its prices. Needs free keys (below), kept in the Keychain.
- **Ask** — questions about your inventory in plain words ("do I have a 3.3 V regulator?"),
  answered by Apple Intelligence using the app's own search as a tool. Nothing leaves the device.
- **Projects** — BOMs imported in the web tool, shown against stock (how many boards you can build).
- **Backups** — import and export the web tool's JSON backup (`gw-parts-inventory` v1), so you can
  move between the two. Import merges by id; the newer copy of each item wins.
- **API and MCP** — other programs can use the inventory while the app runs: a REST API and an MCP
  server for Claude Code and other assistants (below).

## API and MCP

Settings › **API & MCP** › *Enable API and MCP server* (off until you turn it on). The app then serves
`http://127.0.0.1:8765` — this Mac only, unless *Allow other devices on my network* is on. Every request
needs the token shown there (made once, kept in the Keychain, *Make a new token* to replace it):
`Authorization: Bearer <token>`. Requests from web pages on other sites are refused (Origin check).
On iPhone and iPad it answers only while the app is open.

**Claude Code** — copy the command from Settings, or:

```sh
claude mcp add --transport http parts-inventory http://127.0.0.1:8765/mcp \
  --header "Authorization: Bearer <token>"
```

Tools: `search_parts` (the same search as the app: "10k 0603 1%", "cat:caps", "loc:drawer 2", "low"),
`get_part`, `add_part` (with `lookup` to fill in from Digi-Key and Mouser), `update_part`, `adjust_stock`,
`set_stock`, `delete_part` (needs `confirm`), `list_locations`, `add_location`, `list_projects`,
`get_project`, `supplier_lookup`, `identify_photo` (base64 photo) and `low_stock`. The endpoint speaks
MCP's Streamable HTTP transport with JSON responses (protocol 2025-11-25, 2025-06-18 and 2025-03-26).

**REST** — JSON under `/api`, described by `/api/openapi.json`. Parts look like the backup file's parts
(ids are the same), plus `locationPath`, `photoCount`, `isLow` and `summary`.

| | |
|---|---|
| `GET /api/health` | up? (no token needed) |
| `GET /api/parts?q=&category=&location=&low=true&limit=&offset=` | search |
| `POST /api/parts` | add (`{"mpn": …, "qty": 5, "location": "Cabinet A / Drawer 3", "lookup": true}`) |
| `GET` · `PATCH` · `DELETE /api/parts/{id}` | one part (GET includes recent stock history) |
| `POST /api/parts/{id}/stock` | `{"delta": -2, "note": "…"}` or `{"set": 40}` — recorded in its history |
| `GET /api/parts/{id}/photos/{n}` | a photo |
| `GET` · `POST /api/locations` | locations; `{"path": "Shelf / Box 2"}` makes one |
| `GET /api/projects`, `GET /api/projects/{id}` | BOMs with need, have and the matched part |
| `GET /api/lookup?q=LM358DR` | Digi-Key and Mouser listings |
| `POST /api/identify` | a photo (raw image, form upload, or `{"image": "<base64>"}`) → markings and candidates |
| `GET /api/export`, `POST /api/import` | the backup file both ways (`?photos=true` to include photos) |

```sh
T=<token>
curl -H "Authorization: Bearer $T" "http://127.0.0.1:8765/api/parts?q=10k%200603"
curl -H "Authorization: Bearer $T" -H "Content-Type: application/json" \
  -d '{"mpn":"NE555P","qty":10,"location":"Cabinet A / Drawer 2","lookup":true}' http://127.0.0.1:8765/api/parts
curl -H "Authorization: Bearer $T" -H "Content-Type: application/json" \
  -d '{"delta":-2,"note":"timer kit"}' http://127.0.0.1:8765/api/parts/<id>/stock
curl -H "Authorization: Bearer $T" --data-binary @chip.jpg -H "Content-Type: image/jpeg" http://127.0.0.1:8765/api/identify
```

Changes made through the API are the same as changes made in the app: stock changes go into the part's
history ("API — <note>"), and everything syncs through iCloud like any other edit.

## Building

Requires Xcode 26 (iOS, iPadOS and macOS 26), [XcodeGen](https://github.com/yonaskolb/XcodeGen) and
[uv](https://docs.astral.sh/uv/).

```sh
uv run tools/make-clip-embeddings.py --download-dir /tmp/mobileclip   # fetches the look model (~68 MB, not in git)
xcodegen generate
open PartsInventory.xcodeproj
```

Without the model the app still builds; recognising by look is then switched off.

**iCloud.** The app uses the container `iCloud.com.hitorro.PartsInventory` (team T2M6R36LYY).
Build once from Xcode with your team selected so it registers the container and the iCloud
capability. An unsigned build (no iCloud entitlement) keeps its data on the device instead — the app
checks its own entitlements, because CloudKit stops the app rather than reporting an error.

**Supplier keys.** Both are free; add them in Settings › Supplier lookups.

- *Digi-Key* — sign in at [developer.digikey.com](https://developer.digikey.com), create an organisation,
  then a **production** app subscribed to **Product Information V4** (any callback URL, e.g.
  `https://localhost`). Copy its client ID and secret. The app uses the 2-legged (client credentials)
  sign-in, so no browser login is needed. About 1,000 lookups a day.
- *Mouser* — sign in to mouser.com, open [API Hub](https://www.mouser.com/api-hub/) › **Search API**
  and register; the key arrives at once (My Account › APIs). 30 lookups a minute, 1,000 a day.

Try the keys from a terminal without the app:

```sh
cd PartsKit
DIGIKEY_CLIENT_ID=… DIGIKEY_CLIENT_SECRET=… MOUSER_API_KEY=… swift run partlookup LM358DR
```

## Tests

```sh
cd PartsKit && swift test          # the parsers and matching — the same cases as the web tool's tests
TEST_RUNNER_TEST_PHOTOS_DIR=/path/to/photos \
  xcodebuild test -project PartsInventory.xcodeproj -scheme PartsInventory \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO
```

The second runs the real pipeline (Vision, MobileCLIP, Apple Intelligence) on `chip.jpg`, `pot.jpg`,
`stepper.jpg` and `tact.jpg` in that folder.

Debug builds accept `-demo` (sample parts), `-tab identify` and `-identify <path>` at launch, and
`-apiServer` (start the API and MCP server for this run), `-apiToken <t>` and `-apiPort <n>`. The app's
tests run against an in-memory store, never the real inventory; `APITests` drive the REST API and MCP
over HTTP.

## Layout

- `PartsKit/` — a Swift package with no UI: engineering values and packages, the search, bag-label
  parsing, the built-in catalog (`Resources/catalog.json`, shared with the web tool via
  `tools/export-catalog.sh`), marking matching and ranking, look scoring, the backup format, and the
  Digi-Key and Mouser clients (`SupplierAPI.swift`, with the `partlookup` command), and the HTTP server,
  request checks and MCP endpoint behind the API (`Server/`).
- `App/` — the SwiftUI app: SwiftData models (`Model/`), Vision and Core ML (`Vision/`), Foundation
  Models (`Intelligence/`), the REST routes and MCP tools (`API/`) and the screens (`Views/`).
- `tools/` — `make-clip-embeddings.py` (text embeddings for the look labels, and the image encoder)
  and `export-catalog.sh`.

## Licences

The look model is Apple's **MobileCLIP-S2** image encoder, from the Core ML conversions at
[apple/coreml-mobileclip](https://huggingface.co/apple/coreml-mobileclip) (revision 3e0a7bf,
2024-11-19), with text embeddings computed from its matching text encoder. That repository states the
Apple Sample Code License, which allows redistribution in binary form. Apple's MobileCLIP GitHub
repository has since moved its weights to the Apple Machine Learning Research Model License, which
allows non-commercial research only. Personal use is fine either way; before selling the app or putting
it on the App Store, check the terms or switch to a model with a clear commercial licence. The model
isn't stored in this repository.
