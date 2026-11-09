# Portability

`PartsKit` is plain Foundation Swift almost everywhere. This file is about the small part that
isn't, and the decisions behind making the rest build and test on Linux and Windows too — see PI-1.

## What's Apple-only, and why

- **`Server/HTTPServer+Apple.swift`** — the HTTP server's Network.framework implementation. Only
  compiled `#if canImport(Network)`. Everywhere else, `Server/HTTPServer+POSIX.swift` implements the
  same public `HTTPServer` API (`init(handler:)`, `start(port:allInterfaces:)`, `stop()`, `state`,
  `onState`, the `Handler` typealias and `State` enum — declared once, in `HTTPServer.swift`) with
  plain BSD sockets: a background thread accepts connections, each connection gets its own thread that
  blocks on read/write and bridges to the `async` handler with a semaphore. This is a local
  developer/LAN tool (one request per connection, no keep-alive), not a high-concurrency server, so
  thread-per-connection is simpler than wiring up a reactor and plenty fast for it.
- **`NiimbotBluetooth.swift`** — talking to a NIIMBOT label printer over Bluetooth LE
  (`CoreBluetooth`). There is no portable Bluetooth LE API across Linux/Windows/Apple, and no one
  asked for NIIMBOT printing from Linux or Windows yet (see the roadmap below). `Package.swift`
  excludes this one file from the `PartsKit` target, and drops the `niimbot` executable target and
  product entirely, on any platform without `CoreBluetooth`. `Niimbot.swift` (the packet protocol
  itself — encoding, parsing, per-model print tasks) has no dependency on the transport and stays in
  the portable core; `NiimbotTests.swift` passing unmodified when `NiimbotBluetooth.swift` isn't even
  compiled proves that.

Everything else — `Identify.swift`'s marking/look matching, `Catalog.swift`, the export writers,
order import, the REST/MCP server pieces in `Server/*.swift` apart from the listener itself — is
pure Foundation and was already platform-agnostic; it just had never been built outside Xcode.
Making it actually compile and test on Linux surfaced a few unrelated pre-existing gaps, fixed as
part of this change since otherwise `swift test` couldn't run there at all:

- `RemoteInventory.swift` used `URLSession` without the `#if canImport(FoundationNetworking)` guard
  that `OrderHistory.swift` and `SupplierAPI.swift` already had (Linux's Foundation splits networking
  into a separate module). `Tests/.../ServerTests.swift` and the new `HTTPServerTests.swift` needed
  the same guard; `Tests/.../ExportTests.swift`'s `XMLParser` needed the equivalent
  `canImport(FoundationXML)` guard.
- `Export/Zip.swift`'s `dosTime` had a single expression mixing `??`, `<<` and `|` that the Swift 6.2
  Linux compiler couldn't type-check in reasonable time (unrelated to platform logic — just a
  type-checker performance cliff); split into typed intermediate variables, same result.

## The AI provider seam

`AI/PartIdentificationModel.swift` defines what it means to read a part's markings (OCR text plus
Vision's general image labels) into a `Candidate`: `func read(ocrText:imageLabels:) async throws ->
Candidate?`, as an **instance** method — a type can carry its own configuration (an endpoint, an API
key, a model name), which the on-device Apple Intelligence model doesn't need but a hosted one does.

- **Apple Intelligence** stays exclusive to macOS/iOS, per request, and is unchanged:
  `App/Intelligence/AppleIntelligence.swift`'s `PartReader.read` (a `static func`, since
  `PartReader` is a namespace with no instances) keeps its existing behavior exactly. A new
  `AppleIntelligenceModel` struct in the same file adapts it to the protocol by delegating to
  `PartReader.read` — not `extension PartReader: PartIdentificationModel {}` as first sketched,
  because Swift can't satisfy a protocol's *instance* method requirement with a *static* one; a thin
  wrapper is the actual way to get PartReader onto this contract without changing it.
- **`AI/OpenAICompatibleModel.swift`** is the cross-platform counterpart: any server that speaks the
  OpenAI chat-completions API (OpenAI itself, or a self-hosted one — Ollama, LM Studio, vLLM…).
  It asks for JSON back (`response_format: json_object`) and trusts its reading the same asymmetric
  way `PartReader` does — scored higher only when the part number it returns is actually found in
  the OCR text — reusing `Identify.tokens`/`Identify.markScore` directly rather than re-deriving the
  rule. It ships in this change but is not wired into the app's Settings or Identify flow; that's a
  separate decision (which vendor/endpoint to default to) for a later change.

## Decisions

- **Stay in Swift, don't move to Go or Rust.** `PartsKit` was already pure Foundation Swift apart
  from the two files above, and Swift has official Linux and Windows toolchains. Rewriting would
  discard the existing tested logic (matching, catalog, export, order import, the HTTP/MCP server)
  for no capability gain, and leave two codebases to keep in sync.
- **Fix `PartsKit` in place; don't extract a new "core" package.** It already *is* the portable
  core, by construction (a separate SwiftPM library the app depends on) — there was nothing to
  extract.
- **Android: a camera-only companion app, not a full native client (roadmap, not this change).**
  Mirrors the app's existing iPhone-camera-handoff UX and needs no backend change: it would pair with
  a running server using the address + token Settings › API & MCP already generates, `POST` a photo
  to `/api/identify`, and on confirmation `POST` to `/api/parts` or `/api/parts/{uid}/stock`.
- **Windows/Linux desktop UI: web pages served by `partsd`, not a new native GUI.** The first plan was to
  point `geekychris.github.io/tools/parts-inventory` at `partsd`, but that tool keeps its whole inventory in
  the browser and saves it all at once, so it would overwrite changes made meanwhile through MCP or another
  browser. `Sources/PartsServer/Web` is instead a small page of its own, laid out like the Mac app, that reads
  and changes the inventory through the REST API one edit at a time — see below.
- **Priority order: Linux, then Windows, then `partsd`, then the Android companion, then the full desktop UI** — in
  increasing cost/risk order, since no timeline was given. Linux needed only the platform shim and
  CI; Windows needs the same shim plus the Winsock variant below.

## Known gaps

- **The Windows socket path in `HTTPServer+POSIX.swift` hasn't been run.** It's written to the
  documented Winsock2 API (`socket`/`bind`/`listen`/`accept`/`WSAStartup`), mirroring the Linux
  implementation that *is* verified (built and tested against real sockets, including two servers
  racing for the same port and a loopback-only vs. `allInterfaces` check, on this change's Linux
  toolchain). No Windows toolchain was available while writing it. The `windows-latest` job in
  `.github/workflows/portable-core.yml` is this code's first real compiler. `sockaddr_in` is read and
  written as raw bytes at its fixed, ABI-stable offsets (family/port/address) specifically to avoid
  needing to guess how the Windows Swift overlay names that struct's fields.
- **`allInterfacesListensOnEveryAddress`'s host-discovery helper is POSIX-only.** It uses
  `getifaddrs`, which doesn't exist on Windows (`GetAdaptersAddresses` from iphlpapi.h is the
  equivalent there, a different enough shape that porting it wasn't worth it just for a test helper).
  `firstNonLoopbackIPv4()` returns `nil` on Windows, so that one test skips itself there the same way
  it already does on sandboxes with only a loopback interface — the other three `HTTPServerTests`
  still exercise the Windows socket path.
- NIIMBOT printing has no Linux (BlueZ) or Windows (WinRT Bluetooth) backend. Out of scope here; no
  one has asked for it yet.
- `partsd` identifies photos only with a vision model configured (otherwise `POST /api/identify` answers 501
  and `identify_photo` isn't offered), and only by their markings: no bag-label barcodes (Vision) and no
  recognising boards by look (the app's MobileCLIP model).
- The web pages don't have the app's bag-label scanning, order and BOM import, label printing or Ask; projects
  are read-only there (they come across in a backup).
- `partsd` and the app don't sync. Each has its own inventory; move one to the other with the backup
  file (`GET /api/export?photos=true` on one, `POST /api/import` on the other — a merge, newer wins).

## `partsd`, the headless server

`Sources/PartsServer` (a library) and `Sources/partsd` (the command) serve the same REST API and MCP
tools as the app's Settings › API & MCP, on the same `APIGate`/`HTTPServer`/`MCPEndpoint` stack, so the
same `curl` commands and `claude mcp add` line work against either.

- **The store is the backup file itself** (`inventory.json`, written atomically after every change) with
  photos as files beside it (`photos/`, indexed by `photos.json`) — not SQLite as first planned. It needs no
  C library on any platform, it's the format the app already imports and exports, and a personal inventory
  (thousands of parts) is small enough to keep in memory. `PartsServer` is an actor, so requests take turns.
- **What the app and `partsd` share lives in PartsKit**, so they can't drift: the MCP tool list, the
  instructions given to MCP clients, the OpenAPI document and the supplier-listing JSON
  (`Server/InventoryCatalog.swift`). The operations themselves are written twice — `App/API/InventoryAPI.swift`
  over SwiftData, `PartsServer.swift` over `Backup` — because pulling a storage protocol out of the app's
  SwiftData code was a larger change than this one.
- **Photo identification without Apple's frameworks** (`AI/PhotoIdentify.swift`): there's no OCR on Linux, so
  `OpenAICompatibleModel` alone — which only interprets OCR text — would never be called. A vision model
  (`OpenAICompatibleMarkingReader`) transcribes the markings instead; they go through the same `Identify.rank`
  as the app's Vision text, and a text model's reading (`OpenAICompatibleModel`) is added when that isn't sure.
  On spark: `qwen2.5vl:7b` reads (NE555P and NE555N photos read exactly in 1–6 s; an LM7805 misread as
  "LM3805C" still matched L7805CV), and `qwen2.5:14b` interprets — `qwen2.5vl` itself is poor at it (it took a
  lot code for the part number).
- **Web pages** (`Sources/PartsServer/Web`: `index.html`, `app.js`, `app.css`, no libraries or build step):
  Parts (filters by category, location, stock, maker, package and tag; list or table; the server's parametric
  search), a part's page (stock ± and counts, location, fields, Digi-Key/Mouser fill-in, suppliers, photos,
  history), Identify, Locations, Projects and Settings (backup import/export, the `claude mcp add` line). They're
  files served from `web/` beside the binary (or `$PARTSD_WEB`, or the source tree in a dev build) by `WebSite`,
  outside `/api` and `/mcp` and without the token — they hold no data. The browser is given the token once
  (sign-in, or a `#token=…` link) and keeps it in localStorage. `APIGate` lets a page's own requests through the
  Origin check only when it serves pages (`RequestGuard.sameOrigin`); the token is still required, and the
  pages are sent with a strict Content-Security-Policy (no inline script, nothing from other origins). The
  edits the pages make that the app's API doesn't have are partsd-only endpoints, listed in its OpenAPI
  document: `POST/DELETE /api/parts/{uid}/photos[/{index}]`, `POST /api/parts/{uid}/fill` and
  `PATCH/DELETE /api/locations/{id}`.
- Run it with `swift run partsd` (or `partsd --data DIR --port N --all-interfaces`). The token is made on
  first run and kept in `DIR/token`; supplier keys come from `DIGIKEY_CLIENT_ID`, `DIGIKEY_CLIENT_SECRET`
  and `MOUSER_API_KEY`. `tools/partsd.service` is a systemd user unit for it.

## Roadmap (not implemented in this change)

1. **Android camera companion** — a Kotlin/Jetpack Compose app that takes a photo and calls
   `/api/identify` on a running instance, exactly like the iPhone-camera-handoff flow.
