# The inventory repository format

**Export to folder…** writes the inventory as a folder meant to be committed to a git repository — on
GitHub it reads as a browsable catalogue, and the app (yours, or a friend's) can read it back. The app
doesn't run git: commit and push the folder yourself.

```
inventory.json          the inventory, for programs: the source of truth
README.md               totals, the category tree, low stock
parts.csv               every part, one row each
categories/<slug>.md    a page per top-level category
photos/<id>.<ext>       part photos (optional)
```

## inventory.json

A backup in the web tool's format — schema `gw-parts-inventory`, version 1, the same file as Settings ›
Backup › Export a backup — with these differences, so that git diffs stay small:

- Pretty-printed with sorted keys, ending in a newline.
- Parts sorted by category, then MPN (case-insensitive, numbers by value), then id; locations by their
  path ("Cabinet A › Drawer 1"), then id; history by time.
- No photos inside it (`photos` is left out, and parts' `photoIds` are emptied unless photos are exported).
- Only parts and locations unless *Include projects and stock history* is on; `projects` and `history`
  are then empty arrays and parts' `prices` (what was paid) are emptied. `settings` carries the currency and default low-stock level.

Readers need only this file: `Backup.read` then `rows()` in PartsKit, or any JSON reader.

## README.md

The inventory's name (Settings › Export and share, default "Parts inventory"), the totals (parts, units,
categories), the date exported, links to `parts.csv` and `inventory.json`, the category tree with the
number of parts at or under each level, and the parts at or below their low-stock level.

## parts.csv

One row per part, in the same order as inventory.json: MPN, Manufacturer, Description, Category, Value,
Package, Qty, Low stock, Location, Datasheet, Supplier part numbers ("Digi-Key: 296-1395-1-ND; Mouser: …"),
Tags, Notes, Updated (a UTC date, 2026-10-22). RFC 4180 quoting, UTF-8 without a byte-order mark, LF line
ends. (Export as CSV… writes the same columns with a byte-order mark and CRLF, for Excel.)

## categories/&lt;slug&gt;.md

One page per top-level category; parts without a category are on `uncategorised.md`. The slug is the
category's name folded to lower-case ASCII letters and digits joined by hyphens ("ICs & Modules" →
`ics-modules`); categories whose slugs clash are numbered in name order (`ics`, `ics-2`). A page has a
table of the parts directly in the category, then a section per sub-category ("Capacitors › Ceramic")
with an anchor made the same way (`#capacitors-ceramic`; levels with no parts of their own get one too).
Columns: MPN, Manufacturer, Description, Value, Package, Qty (low ones in bold), Location, Datasheet,
Suppliers (links to the supplier's page or search), and Photo first when photos are exported.

## photos/

With *Include photos*, each part's photos as `<photo id>.<jpg|png|heic|…>`; the category pages show the
first one as a thumbnail.

## Exporting again

The same inventory gives byte-identical files, apart from the date in README.md and `exportedAt` in
inventory.json; files that haven't changed aren't rewritten. The exporter owns `inventory.json`,
`README.md`, `parts.csv`, `categories/` and `photos/`: it replaces them and removes files there that no
longer apply (a category that's gone, photos switched off). Everything else in the folder — `.git`, a
licence, your own notes — is left alone. Edits made by hand to the owned files are replaced.
