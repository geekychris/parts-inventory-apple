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
  camera on iPhone and iPad (VisionKit's DataScanner), from a photo, or typed in by a USB scanner.
  A bag adds stock to the matching part or makes a new one.
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
- **Ask** — questions about your inventory in plain words ("do I have a 3.3 V regulator?"),
  answered by Apple Intelligence using the app's own search as a tool. Nothing leaves the device.
- **Projects** — BOMs imported in the web tool, shown against stock (how many boards you can build).
- **Backups** — import and export the web tool's JSON backup (`gw-parts-inventory` v1), so you can
  move between the two. Import merges by id; the newer copy of each item wins.

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

## Tests

```sh
cd PartsKit && swift test          # the parsers and matching — the same cases as the web tool's tests
TEST_RUNNER_TEST_PHOTOS_DIR=/path/to/photos \
  xcodebuild test -project PartsInventory.xcodeproj -scheme PartsInventory \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO
```

The second runs the real pipeline (Vision, MobileCLIP, Apple Intelligence) on `chip.jpg`, `pot.jpg`,
`stepper.jpg` and `tact.jpg` in that folder.

Debug builds accept `-demo` (sample parts), `-tab identify` and `-identify <path>` at launch.

## Layout

- `PartsKit/` — a Swift package with no UI: engineering values and packages, the search, bag-label
  parsing, the built-in catalog (`Resources/catalog.json`, shared with the web tool via
  `tools/export-catalog.sh`), marking matching and ranking, look scoring, and the backup format.
- `App/` — the SwiftUI app: SwiftData models (`Model/`), Vision and Core ML (`Vision/`), Foundation
  Models (`Intelligence/`) and the screens (`Views/`).
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
