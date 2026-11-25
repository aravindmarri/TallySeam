# Build Status

_Last updated: 2026-11-24 (CI run #64)_

Development happens on Windows. iOS builds and tests run on GitHub Actions (`.github/workflows/ios-build.yml`, `macos-15` runner, XcodeGen).

## Latest: CI run #64, commit `1f40a9e` (version 1.3)

| Check | Result |
|---|---|
| Simulator compile and tests | **Pass: 302 of 302** |
| Unsigned IPA | **Pass:** 1.3 (64), arm64 device build, 2,119,380 bytes |
| dSYM | **Pass:** UUID `98BE669A-F049-3AB2-A271-1FDD3445C314` matches the app; kept 90 days |
| Debug-only diagnostic actions absent from the release binary | **Pass** |
| MetricKit delivery on a real iPhone | **Not done** (simulator tests use synthetic data) |
| Run on a real iPhone | **Not done** |

Run: https://github.com/aravindmarri/TallySeam/actions/runs/45541535031

Runs #62 (a repeated end of one operation crashed) and #63 (a test used fractional seconds) failed and were fixed.

## Earlier summary (CI run #41, commit `f781bcc`)

| Check | Result |
|---|---|
| iOS Simulator compile | **Pass** (GitHub Actions) |
| Automated tests | **Pass: 236 of 236** (0 failed, 0 skipped), Swift Testing and XCTest on the iOS Simulator |
| Unsigned device archive | **Pass.** `TallySeam-unsigned-ipa` artifact (1,585,501 bytes, kept for 14 days) |
| IPA verification (CI) | **Pass.** Real device build: platform `iphoneos` / Mach-O `IOS`, `arm64` only, bundle ID `io.github.aravindmarri.tallyseam`, version 1.0 (41), display name TallySeam, built with Xcode 26.6, FoundationModels weak-linked (Apple Intelligence included; runs on iOS 17+), minimum iOS 17.0, no bundled frameworks, no Network/CloudKit/WebKit linkage |
| Network-use checks | **Pass.** Static source scan, linked-framework check on the IPA, and a runtime test showing OCR, calculations and backups make no requests |
| Run on a real iPhone | **Not done.** Install with Sideloadly and a free Apple Account: see README → INSTALL_ON_IPHONE |
| Manual UI check (layout, VoiceOver, Dynamic Type, dark mode) | **Not done** |
| Airplane-mode check on a device | **Not done.** The code makes no network calls, and Vision OCR ran offline in the simulator test |
| Static source checks (`python tools/check_sources.py`) | **Pass:** 94 Swift files |

Run: https://github.com/aravindmarri/TallySeam/actions/runs/44854121801

### CI history

| Run | Commit | Result | Notes |
|---|---|---|---|
| #2 | `bbd8fcd` | Fail | Missing `TransactionType.categoryKind`; the editor body was too complex to type-check |
| #3 | `e1d33a9` | **Pass** | First successful build; unsigned IPA produced |
| #4 | `947bd8d` | **Pass** | 60 of 60 tests (Phases 1–3) |
| #5 | `1e5dce1` | Fail | Tests called a main-actor method from a nonisolated context |
| #6 | `7e9f320` | Fail | Nested `#require` macro (the error wasn't annotated yet) |
| #7 | `67473bf` | Fail | Same error, now annotated |
| #8 | `045d4e8` | **Pass** | 98 of 98 tests (Phases 1–4) |
| #9 | `6e683b9` | **Pass** | 114 of 114 tests (Phases 1–5) |
| #11 | `079c90e` | **Pass** | Docs only |
| #12 | `aea4b18` | Fail | Phase 6: 124 of 125; a test read category kinds before adding a custom category (test bug). IPA job passed |
| #13 | `bd249b2` | Fail | A new test expression was too slow to type-check. IPA job passed and the IPA was verified |
| #14 | `e75e5ae` | **Pass** | 132 of 132 tests (Phases 1–6 and install readiness); IPA verified |
| #16 | `d24c455` | **Pass** | 153 of 153 tests (Phase 7: CSV import and export); IPA verified |
| #41 | `f781bcc` | **Pass** | 236 of 236; CI now uses the newest Xcode (26.6), so Apple Intelligence is compiled in (weak-linked). Builds up to #39 were made with Xcode 16 and left it out |
| #36 | `29fa332` | Fail | Phase E: a main-actor helper was called from the background assistant |
| #37 | `6f58855` | Fail | IPA job passed; the new performance test had expressions too slow to type-check |
| #39 | `f1b4e14` | **Pass** | 236 of 236 tests (statement import Phase E); IPA verified |
| #35 | `429c46b` | **Pass** | 227 of 227 tests (statement import Phase D), first try; schema 4.0.0; IPA verified |
| #33 | `030ed7f` | **Pass** | 217 of 217 tests; app renamed to TallySeam everywhere (new app ID, store file and backup tag; old backups still import); IPA verified |
| #30 | `0412770` | **Pass** | 216 of 216 tests (statement import Phase C), first try; IPA verified |
| #24 | `6de2d28` | Fail | Phase B: 201 of 202; one test crashed and wasn't named (annotation gap). IPA job passed |
| #25 | `4abf04a` | Fail | Annotator now reports crashes: "unexpected exit" in a migration test |
| #26 | `7f77666` | Fail | CI now publishes failing test names: `SchemaV3MigrationTests` crashed with a trap |
| #27 | `5c2b46f` | Fail | Test split: writing a 2.0.0 store and upgrading it both pass; only saving a `MerchantAlias` crashed |
| #28 | `fd46f5c` | **Pass** | 205 of 205 tests (statement import Phase B); `MerchantAlias` uses a UUID key like every other model; IPA verified |
| #20 | `176cded` | Fail | Statement import Phase A: a CSV closure mixed `return nil` with an implicit switch result and didn't type-check |
| #22 | `abd7a24` | **Pass** | 182 of 182 tests (statement import Phase A); IPA verified |
| #19 | `ad976d9` | **Pass** | 165 of 165 tests (counts-in-month, schema 2.0.0 migration, quick account setup); IPA verified |

## About the unsigned IPA

`TallySeam-unsigned-ipa` is **not signed and cannot be installed on an iPhone as-is.** It must first be re-signed with your own Apple Account, for example with Sideloadly or AltStore. With a free Apple Account, apps signed this way expire after 7 days and must be re-signed. CI artifacts are kept for 14 days.

## Implemented features (compiled and covered by passing CI tests where noted)

**Phase 1:** foundation
- XcodeGen project (iOS 17, iPhone), SwiftData schema V1 with a migration plan, CloudKit off, store protected with iOS Data Protection
- First launch creates only the default categories and settings, with no sample data
- Five tabs with empty states

**Phase 2:** manual transactions
- Add, edit, delete (with confirmation), and duplicate (opens an unsaved copy)
- Search and filters
- Category and payment-method management; deleting a category in use requires reassigning its transactions; only the last four card digits are stored
- Credit-card repayments are recorded as transfers, with a warning when one is entered as an expense

**Phase 3:** dashboard and reports
- Category donut and 6-month cash-flow chart on the dashboard
- Reports: period presets and custom dates, monthly income vs expenses, category, payment-method and merchant breakdowns, daily trend, month-over-month comparison, year to date
- Each chart has accessibility labels and a "Show data" table

**Phase 4:** offline receipt scanning
- Import from Photos (including screenshots) or the camera
- Images are re-rendered and re-encoded, which strips metadata including GPS
- On-device Apple Vision text recognition, with labels and prices from separate columns put back on one line
- Deterministic parser for merchant, date, total, tax, discount and currency, each with a confidence level. It handles change and cash lines, labels and amounts on separate lines, discounts before or after the subtotal, tax rates, European number formats, and OCR misreads such as "T0TAL"
- Review screen: the image next to editable fields, with uncertain values flagged; nothing is saved until you tap Save; manual entry if OCR finds no text
- Duplicate warnings for the same or a similar image (perceptual hash) and for an expense with the same amount, day and merchant. You can save anyway or attach the receipt to the existing expense
- Images are stored in Application Support with complete file protection; image paths are validated, and files left by an interrupted save are cleaned up
- Category suggestions from your past choices for the merchant, then a built-in merchant directory, then header keywords
- Receipts appear on the transaction detail screen and are never counted as separate spending

**Phase 5:** bills and budgets
- Bill editor: name, optional expected amount (empty means it varies), currency, weekly, monthly, yearly or every N days, category and payment method used when paid, notes
- Due status by calendar day: overdue, due today, due within 7 days, upcoming, paused
- Record Payment either creates one expense linked to the bill or links an expense you already recorded (for example from a receipt), so it isn't counted twice. The bill then moves one period on from its due date. An expense can only be linked to one bill
- Skip a payment, pause or resume, delete (recorded payments stay as ordinary expenses)
- Monthly and yearly bills due on the last day of a month stay on the last day (Jan 31 → Feb 29 → Mar 31)
- Monthly budgets, overall or per expense category, in any supported currency; at most one active budget per category and currency
- Budget progress uses the same rules as every other total: expenses minus refunds, in the budget's currency only; transfers, card repayments and unpaid bills never count. 80% used is shown as near the limit
- Budgets screen with month navigation; dashboard shows budget progress and upcoming bills with their status

**Phase 6:** privacy and quality
- Face ID / Touch ID / passcode app lock (LocalAuthentication). It locks when the app goes to the background, and changing the setting requires authentication. If the device has no passcode the lock isn't applied, so you can't be locked out
- Privacy cover whenever the app isn't active, so the app switcher never shows financial data
- Encrypted backup export and import: PBKDF2-HMAC-SHA256 (600,000 iterations, random salt) and AES-256-GCM, with the file header authenticated. Receipt images are included. Import only adds items, matches default categories by name, imports a clashing budget as paused, and is all-or-nothing on errors
- Delete All Data (type DELETE to confirm) and cleanup of receipts left behind by deleted transactions
- Accessibility: every icon-only button has a label; budget progress and chart rows have spoken values

**Phase 7:** CSV import and export
- Export every transaction as CSV (date, type, refund, title, merchant, category, payment method, positive and signed amounts, currency, notes, source). Text that a spreadsheet would run as a formula is prefixed with an apostrophe. The file isn't encrypted and the app says so
- Import bank statements: RFC 4180 reader (quotes, embedded line breaks, BOM, comma/semicolon/tab, Windows-1252 fallback), columns guessed from header names, one amount column or separate debit and credit columns, date format detected from the values (the region breaks ties), month-name dates
- Every row is previewed as new, already in the app, or unreadable (with the reason). A row is "already in the app" when a transaction on the same day has the same type, amount and a matching description; each existing transaction matches only one row. Re-importing the same file adds nothing
- Categories come from a category column by name and type, otherwise from the existing suggestion engine. The statement's account and currency apply to every row. All rows are saved together or not at all

**Statement import Phase E** (run #39): see docs/STATEMENT_IMPORT.md
- Encrypted backups include accounts, sessions, statements, lines, matches and learned spellings; add-only, deduplicated by id and file fingerprint, validated, all-or-nothing; older backups still import
- Description assistant: rule-based explanations, merchant names and category suggestions on every iPhone; optional Apple Intelligence (iOS 26, availability-gated, off by default, answers checked, suggestions only). The Apple Intelligence path compiles from run #41 (Xcode 26.6) but has no automated test of the model itself
- Delete saved statements while keeping transactions; Smart Suggestions switch in Settings
- Faster matching (day numbers and merchant keys computed once, binary search by date); 1,000 lines vs 3,000 transactions tested under 15 s

**Statement import Phase D** (run #35): see docs/STATEMENT_IMPORT.md
- Balance checks: transactions read vs closing/new balance, the statement's own summary (bank: opening + deposits − withdrawals; card: previous + purchases + fees + interest − payments), totals read vs printed; pending lines excluded
- Running-balance walk pinpoints the line where a bank balance stops adding up
- Verdicts (verified, differences, not proven) with explanations; "reconciled" requires every line reviewed and a verified balance
- Reconciliation overview: verified vs unverified spending, spending by account and credit cards, bank cash flow from statements, statements with verdicts; statement balances shown as printed, never as a current balance; Home shows the verified share
- Schema 4.0.0 adds `runningBalance` to statement lines; the shipped 3.0.0 model is frozen and the upgrade is tested on a real 3.0.0 store

**Statement import Phase C** (run #30): see docs/STATEMENT_IMPORT.md
- Line review side by side with differences highlighted: confirm, reject (next candidate promoted), choose another, add as new (category suggestion, account, transfer accounts), add as card payment or transfer, skip, review later; undo for every action
- Amounts change only when the user chooses the statement amount (old amount kept for undo); dates never change; new transactions use the statement's transaction date
- Bulk confirm of strong, unambiguous, exact-amount matches after a preview (all or nothing)
- Transfer pairing across accounts: the bank's card payment and the card's payment credit back one transfer; tested end to end (spending stays $100)
- Overlapping-statement duplicates, identical lines within a statement, app transactions missing from the statement
- Undo a whole import: deletes only the transactions it added, restores amounts, releases matches

**Statement import Phase B** (run #28): see docs/STATEMENT_IMPORT.md
- Schema 3.0.0 adds FinancialAccount, ImportSession, ImportedStatement, StatementTransaction, ReconciliationMatch, MerchantAlias (new tables only). The 2.0.0 → 3.0.0 upgrade is tested on a real store: write 2.0.0, upgrade, keep data, add new data, reopen
- Matching: hard currency and direction rules; score from amount 45, merchant 25, date 15, account 15; calendar-day windows (default ±2); never strong on amount and date alone; one transaction per line; ties shown; card repayments match transfers only
- Merchant normalization with built-in and learned aliases
- Save & Find Matches (one all-or-nothing save; duplicate files refused by SHA-256), statement details with reasons, re-run matching, undo import. Matching never changes transactions
- CI now names failing and crashing tests in annotations

**Statement import Phase A** (run #22): see docs/STATEMENT_IMPORT.md
- Import tab with an Import Center: several PDF, CSV, TXT and image files at once; format detection (XLSX/OFX/QFX recognised, not supported yet); SHA-256 fingerprints
- PDFKit text extraction with on-device Vision OCR for scanned pages; password-protected PDFs (password used in memory only)
- Document type suggestion with reasons; statement header extraction (institution, account type, last four only, period, balances, totals, due date, minimum payment, currency), all editable
- Transaction line parsing: posting dates, wrapped descriptions, running balances, sections, CR/DR, year inference, pending, line kinds; unreadable lines kept for manual entry
- CSV balance and status columns; pending rows skipped by default; column mappings remembered per layout
- Statements are previewed only; nothing is saved to the database until Phase B/C

**Counts in month and account setup** (run #19)
- A transaction can count in the previous or next month (e.g. a November salary paid on October 29). Totals, budgets, reports and the dashboard use that month; the list keeps the real date. Backups and CSV keep it
- Schema 2.0.0 adds the optional `countedMonth`. Schema 1.0.0's `MoneyTransaction` is frozen and a lightweight migration upgrades existing stores; a test writes a real 1.0.0 store on disk and opens it with the new app
- Set Up Accounts adds Cash, debit and credit cards in one step (e.g. Wells Fargo Debit, Capital One Credit, American Express Credit); payment methods can be added from the transaction editor; new transactions start with the last-used method

**Install readiness**
- Stable bundle ID `io.github.aravindmarri.tallyseam`, so a re-signed build installs over the previous one and keeps its data. The build number is the CI run number
- CI unzips the IPA and fails unless it is the real arm64 iPhone device build

## Tests (236, all passing in CI run #39)

| File | Count | Covers |
|---|---|---|
| `FinanceCalculationTests.swift` | 14 | Totals, transfers, refunds, month boundaries, leap year, time zones, card double counting, currencies, rounding |
| `TransactionTests.swift` | 20 (+ parameterized cases) | Draft validation, edit and duplicate rules, amount parsing, filters, repayment detector |
| `RepositoryTests.swift` | 9 | SwiftData add, edit, delete and duplicate; category reassignment; payment-method rules; card double counting end to end |
| `ReportCalculationTests.swift` | 14 | Breakdowns, daily series (leap year, DST), monthly flows, month-over-month, ranges |
| `PersistenceTests.swift` | 3 | First-launch setup, save and reload, default settings |
| `ReceiptParserTests.swift` | 18 (+ parameterized cases) | Synthetic receipts: standard, cash and change, split columns, discounts, grand total and tip, fallbacks, number formats, dates, merchants, currency |
| `ReceiptServicesTests.swift` | 12 | OCR line assembly; **real Vision OCR on a rendered synthetic receipt**; fingerprints; duplicate detection; category suggestions |
| `BillBudgetTests.swift` | 16 | Due status, next due dates (month ends, leap years, custom intervals), bill validation, payment candidates, budget progress and thresholds; SwiftData: recording or linking a payment creates exactly one expense, failed links don't advance the bill, deleting a bill keeps payments, budget rules |
| `PrivacyDataTests.swift` | 11 | PBKDF2 published test vectors; encryption round trip; wrong password; tampered data and header; weak passwords; app-lock logic; full backup round trip onto a fresh install; clashing budget; invalid backups import nothing; delete all data; receipt cleanup |
| `InstallReadinessTests.swift` | 7 | On-disk store survives close and reopen (force-close); repeated launches add nothing; schema-version guard; store opens through the migration plan; a frozen v1 backup keeps importing; network detector works; OCR, calculations and backups make no requests |
| `CSVTests.swift` | 21 | CSV reading (quotes, line numbers, delimiters, encodings, broken files) and writing; date orders, month names and format detection; amount formats (signs, brackets, CR/DR, symbols, grouping); column guessing; single and debit/credit statements; invalid rows; category matching; duplicates; export format; export then import restores every field; SwiftData save and totals |
| `CountedMonthAndAccountsTests.swift` | 12 | Early salary in the next month's totals; reporting dates across month and year ends; budgets and daily spending; draft save, edit and duplicate; backup and CSV keep the month; schema 1.0.0 store upgrades with nothing lost; account setup names, de-duplication, last-four validation, creating Cash, Wells Fargo, Capital One and Amex |
| `StatementImportTests.swift` | 17 | Format detection; fingerprints; searchable multi-page PDF; scanned PDF through OCR; password-protected PDF (none, wrong, right); invalid files; routing of CSV, image, OFX, locked PDF and statement PDF; classification of bank, card, receipt, invoice, payment confirmation, unknown; bank and card header extraction; bank and card transaction lines (wrapped lines, balances, posting dates, kinds, issues kept); year across December/January; signs, CR/DR, pending, impossible dates; money tokens and last four; re-parse keeps edited lines; CSV balance and pending columns; remembered mappings |
| `ReconciliationTests.swift` | 23 | Merchant normalization (Walmart spellings, prefixes, store numbers, locations, Amazon, learned aliases) and similarity; Walmart posted 2 days later; date differences both ways, windows, weekend delay, posting dates; calendar days across month, year and DST; currency and direction rules; card repayment matches only the transfer and totals stay $100; tip differences; identical purchases one-to-one; ties shown; confirmed transactions skipped; repository save, duplicate file, wrong type, account reuse, re-run with a narrower window, undo import, delete all; learned aliases stored once; window preference; 2.0.0 store written, upgraded and extended |
| `StatementReviewTests.swift` | 11 | Confirm learns an alias and undo restores; statement amount only on request, restored by undo, dates unchanged; reject promotes the next candidate and stays rejected after re-matching; currency, direction and already-matched rules; adding a missing purchase (transaction date, category, account, notes) and undo deleting it; skip and undo; bulk confirm only strong and all-or-nothing; the $100 card repayment across two statements (one transfer, spending $100, one line per account, undo releases the other side); overlapping statements and identical lines; transactions missing from the statement; incomplete when lines couldn't be read |
| `BalanceValidationTests.swift` | 10 | Bank statement balances; unread lines mean not proven; a missing row found by the running balance (exact line); card formula; a misread summary figure; no opening balance; pending lines left out; verified-spending coverage with refunds, transfers, other currencies and counted months; 3.0.0 → 4.0.0 upgrade on a real store; saved bank statement keeps running balances and needs a proven balance to be reconciled |
| `PhaseETests.swift` | 9 | Statements round-trip through a backup (lines, statuses, matches, aliases, verified spending); restoring twice adds nothing; links to transactions missing from a backup are released; broken statement data imports nothing; old backups still import; deleting statement data keeps transactions; rule-based insights; model answers checked (unknown categories, numbers, long names rejected); rules used unless the model is on and available; matching performance |
| `ReceiptStorageTests.swift` | 8 | File save, load and delete; path-traversal rejection; orphan cleanup; linking receipts to new or existing transactions; failed saves write nothing; receipts aren't counted as spending |

Xcode counts parameterized cases separately, which is why the total is 236. All tests use synthetic data only.

## Known issues and risks

- The app hasn't been run on a physical iPhone yet. Camera capture can only be tested on a device.
- The UI hasn't been reviewed by eye: chart layout, the largest Dynamic Type sizes, VoiceOver flow and dark mode.
- Receipt parsing is rule-based. Unusual layouts will need manual correction, which the review screen supports.
- Deleting a transaction keeps its receipt record and image. Remove them with Settings → Backup & Data → Delete Unattached Receipts.
- Swift 5 language mode with complete strict-concurrency checking. Warnings should be cleared before moving to Swift 6 mode.
- Bills have no reminder notifications yet; due status shows in the app only.
- A monthly bill on the 30th that passes through February moves to the 29th (or 28th) and stays there; only bills on the last day of a month are kept at month end.
- Installing on a physical iPhone hasn't been tested yet. Face ID, the camera, the privacy cover and the system file pickers can only be checked on a device.
- The runtime network test detects URLSession traffic. Lower-level sockets are covered by the static source scan and the linked-framework check, not at runtime.

## Building

- **CI:** every push to `main` builds, runs the tests and produces the unsigned IPA.
- **Mac (optional):** Xcode 16+, `brew install xcodegen`, `xcodegen generate`, then build and test the `TallySeam` scheme.

## Next tasks

1. Install with Sideloadly and a free Apple Account (README → INSTALL_ON_IPHONE) and work through the personal test checklist on the iPhone.
2. Fix anything found on the device, then record the results here.
