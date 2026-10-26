# bcard — business card extractor

Reads a folder of business-card scans (JPEG, PNG, HEIC, TIFF, PDF), pulls out contact fields with
on-device OCR, stores them in SQLite, and exports `cards.csv` and `cards.xlsx`.

- **Local and private.** Uses Apple Vision for OCR and Apple's NaturalLanguage/NSDataDetector for
  parsing. Nothing leaves the machine; no API keys, no network.
- **Fast.** Runs a pool of OCR worker processes, about 45–65 cards/s on Apple silicon. A run of
  2,000 cards takes under a minute.
- **Portable.** One ~1 MB universal binary (Apple silicon + Intel), macOS 13 or later, no dependencies.
- **Resumable.** Each card's content hash is stored, so re-running skips cards already done. Edited or
  new files are picked up automatically.

## Quick start

```sh
make                          # list all commands
make trial CARDS=~/Cards      # try the first 50 cards
make scan  CARDS=~/Cards      # all cards → out/cards.db, out/cards.csv, out/cards.xlsx
make csv                      # re-export just the CSV (or: make xlsx, make export)
make ocr   FILE=~/Cards/card0042.jpg   # see why one card was misread
```

`make build` builds the universal binary at `bin/bcard`. The other commands build it automatically
whenever the source has changed. Building requires Xcode or the Command Line Tools. The binary
itself needs nothing else, so you can copy `bin/bcard` to any Mac running macOS 13+.

Make variables: `CARDS`, `OUT` (default `out`), `DB` (default `$OUT/cards.db`), `LIMIT`, `JOBS`,
`FILE`, and `ARGS` for any extra option below (e.g. `ARGS=--force`).

### Using the binary directly

```sh
bin/bcard scan ~/Cards --out ~/Desktop   # → cards.db (in the current dir), cards.csv, cards.xlsx
bin/bcard export --format xlsx           # re-export from the database without re-scanning
bin/bcard ocr ~/Cards/card0042.jpg       # debug one card: OCR lines, scores, parsed fields
```

The first run on a machine can pause for ~20 s while macOS compiles the Vision text model. Later
runs start immediately.

### How cards are grouped

| Input | Treated as |
|---|---|
| `card.pdf` with 1 page | single-sided card |
| `card.pdf` with 2 pages | one card: page 1 front, page 2 back |
| `stack.pdf` with more pages | one card per 2 pages (`--pdf-pages-per-card N` to change) |
| `x_front.jpg` + `x_back.jpg` (also `-front`, ` front`, `recto`/`verso`) | one double-sided card |
| `x_a.jpg` + `x_b.jpg`, or `x_f.jpg` + `x_b.jpg` | one double-sided card |
| any other image | single-sided card |

For any other naming scheme, pass a regex over the filename (without extension) that captures
`(base)(side)`, e.g. files named `0042-1.jpg` / `0042-2.jpg`:

```sh
bin/bcard scan ~/Cards --pair-regex '^(.+)-([12])$'
```

Sub-folders are scanned recursively. Pairing only happens within the same folder.

### Options

| Option | Default | |
|---|---|---|
| `--db <path>` | `./cards.db` | SQLite database |
| `--out <dir>` | current dir | where `cards.csv` / `cards.xlsx` go |
| `--jobs <n>` | cores − 2, max 8 | OCR worker processes |
| `--force` | off | re-process cards already in the database |
| `--limit <n>` | all | only the first n cards |
| `--fast` | off | ~4× faster OCR, noticeably less accurate |
| `--languages <list>` | automatic | e.g. `en-US,de-DE,fr-FR` |
| `--pair-regex <re>` | see above | repeatable |
| `--pdf-pages-per-card <n>` | 2 | |
| `--format <csv\|xlsx\|both>` | both | which export files to write |
| `--no-export` | off | skip CSV/XLSX |

## Fields

One row per card in table `cards`. The CSV and XLSX columns are the same and in the same order.

| Group | Columns |
|---|---|
| Source | `card_key`, `source_files`, `sides` |
| Person | `full_name`, `prefix`, `first_name`, `middle_name`, `last_name`, `suffix`, `credentials` |
| Role | `job_title`, `department`, `company` |
| Online | `email`, `email_alt`, `website`, `linkedin`, `twitter`, `other_social` |
| Phone | `phone_work`, `phone_ext`, `phone_mobile`, `phone_fax`, `phone_other` |
| Address | `street`, `city`, `region`, `postal_code`, `country`, `address_full` |
| Quality | `language`, `confidence` (0–1), `needs_review` (0/1), `review_reasons` |
| Raw | `front_text`, `back_text` (full OCR text for anything not captured above) |
| Bookkeeping | `error`, `content_hash`, `ocr_ms`, `processed_at` |

Multiple values in one cell (extra emails, extra phones) are separated by `; `.

In the XLSX, rows with `needs_review = 1` are shaded. The header is frozen and filterable.

## How extraction works

1. **OCR.** Vision's accurate recognizer runs on each side. If the card is sideways or upside down,
   it re-reads the card upright so the layout is meaningful.
2. **Pattern fields.** Emails, URLs, social handles and phone numbers are pulled out with patterns.
   Phone type comes from labels such as `T`, `Tel`, `M`, `Cell`, `F`, `Fax`, `Direct`, `(c)`.
   Toll-free numbers go to `phone_other`.
3. **Address.** Apple's address detector runs first. Rules for US, Canadian, UK and EU formats fill
   gaps, and suite/floor lines and country lines are attached to the address.
4. **Name, title, company.** Each remaining line is scored using:
   - person/organization tagging from NaturalLanguage
   - title vocabulary (Director, VP, Partner…) and legal suffixes (Inc, LLC, GmbH…)
   - whether a line matches the email address (`jdoe@` → "Jane Doe") or the domain (`acmewidgets.com` → "Acme Widgets")
   - font size and position (a title usually sits right below the name)

   If no company line is found, it is taken from the email or web domain and flagged.
5. **Two sides.** The side with more contact detail wins, and the other side fills any gaps.
6. **Confidence.** Points are deducted for a missing name, company or contact detail, low OCR
   confidence, or non-Latin script. Under 0.7 sets `needs_review`.

## Limitations

- The parser is rule-based. Unusual layouts can swap title and company, or miss a name, so check
  the `needs_review` rows. Raw text is always kept, so nothing is lost.
- Names in non-Latin scripts (Japanese, Chinese, Arabic…) are kept in the raw text but not split into
  fields. When the other side is in English, that side is used.
- Logos drawn as artwork rather than text can't be read. The company then comes from the email/web
  domain (flagged `company inferred from domain`).
