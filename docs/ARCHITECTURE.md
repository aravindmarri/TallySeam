# Architecture

## Overview

- **UI:** SwiftUI with an MVVM-style split. Views read live data with `@Query` and call repositories to change it.
  Form state and filtering live in pure value types (`TransactionDraft`, `TransactionFilter`), not in views.
- **Persistence:** SwiftData with a single local store. `cloudKitDatabase: .none` is set explicitly.
- **Dependency injection:** `AppContainer` (`@Observable`, `@MainActor`) holds `PersistenceService`, the repositories and
  `FinanceCalculationService`. It is injected with `.environment(...)`, and tests build their own in-memory containers.

```
View ──@Query──▶ SwiftData (read)
 │
 └─▶ Repository (TransactionRepository / ReferenceDataRepository) ──▶ ModelContext.save()
 │
 └─▶ FinanceCalculationService (pure, on TransactionRecord snapshots)
```

## Data model

| Model | Notes |
|---|---|
| `MoneyTransaction` | Lives in `Transaction.swift`. Renamed to avoid a clash with `SwiftUI.Transaction`. |
| `SpendingCategory` | Lives in `Category.swift`. Renamed to avoid the Objective-C `Category` typedef. |
| `PaymentMethod` | Stores only the last four digits, never a full number. Apple Pay can link to the card behind it. |
| `Receipt` | Image file in Application Support; the record holds only a relative path. |
| `RecurringBill` | An obligation only. It is never counted as spending. |
| `Budget`, `AppSettings` | `AppSettings` is a single row. |

- **Enums:** stored as raw `String` values with typed computed accessors.
- **Snapshots:** each model has a matching `Codable` `*Record` value type where needed. `TransactionRecord` is what calculations use.
- **Schema versioning:** `TallySeamSchemaV1`–`V4` plus `TallySeamMigrationPlan` (lightweight stages only). The latest
  version references the live models; an older version keeps a frozen copy of any model that changed after it
  (V1 freezes `MoneyTransaction`, V3 freezes `StatementTransaction`). A model that has shipped is never edited in
  place: add a field in a new version. Every upgrade is tested on a real on-disk store written with the old schema.
  | Version | Change |
  |---|---|
  | 1.0.0 | Initial models |
  | 2.0.0 | `MoneyTransaction.countedMonth` (count in another month) |
  | 3.0.0 | Statement import tables (new models only) |
  | 4.0.0 | `StatementTransaction.runningBalance` |
- **Fixed identifiers:** bundle ID `io.github.aravindmarri.tallyseam`, store file `Application Support/Store/TallySeam.store`,
  backup tag `TallySeam-Backup` (the tag used by early builds is still read).

## Financial rules

1. **Money storage:** amounts are `Int64` minor units using ISO 4217 exponents (JPY 0, KWD 3, others 2).
   Conversions go through `Decimal`, and money is never stored as a `Double`. Charts may convert to `Double` only for plotting.
2. **Direction:** amounts are always non-negative magnitudes, and `transactionType` gives the direction. `isRefund` reverses the
   amount within its bucket: a refunded expense lowers expenses, and a reversed income lowers income.
3. **What counts:** only `income` and `expense` count toward cash flow. `transfer` and `adjustment` never do.
4. **Credit cards:** a purchase on a card is an `expense`, counted on the day of the purchase. Paying the card bill is a `transfer`
   from the bank account to the card, so it isn't counted again. The editor warns when an expense looks like a card payment and
   offers a one-tap switch to Transfer. It never changes the data without the user's action.
5. **Date ranges:** ranges include their start and exclude their end, and are built with the user's `Calendar`.
   Calculations use `transactionDate`, never `createdAt`.
6. **Currencies:** summaries include only the selected currency. Other currencies are counted and reported as excluded, never converted.
7. **Net cash flow:** income minus expenses. It is never presented as a balance or net worth.
8. **Bills and receipts:** neither is ever summed as spending.

## Statement import and reconciliation

Full rules: [STATEMENT_IMPORT.md](STATEMENT_IMPORT.md).

```
Files picker ─▶ StatementImportService ─▶ DocumentFormatDetector
                   │                         ├─ PDFStatementReader (PDFKit text, Vision OCR for scanned pages)
                   │                         ├─ PlainTextDocumentReader
                   │                         └─ CSVParser ─▶ CSVImportView (column mapping)
                   ▼
             StatementPreview  (DocumentClassifier, StatementHeaderExtractor, StatementLineParser)
                   │  Save & Find Matches
                   ▼
StatementRepository ─▶ ImportedStatement / StatementTransaction / ReconciliationMatch
        │                 ▲
        │                 └── StatementReconciliationService (pure, deterministic scoring)
        ├─ review: confirm · reject · create · skip · undo · bulk · pair transfers
        └─ StatementBalanceValidator ─▶ verdict (verified / differences / not proven)
```

- **No double counting:** statement models are never summed. Income and spending come only from `MoneyTransaction`. A
  statement line counts only once it is confirmed against, or turned into, a transaction. Card payments and own-account
  transfers become one `transfer` transaction, which can be backed by one line on each account's statement.
- **User approval:** matching only proposes. Transactions are created, and amounts changed, only by explicit user actions,
  each in one all-or-nothing save with undo. Dates are never overwritten by posting dates.
- **Reconciled** means every line is reviewed and the statement's balance is verified by `StatementBalanceValidator`.
- **On-device assistance:** `StatementDescriptionAssisting` has a rule-based implementation used everywhere, and an
  optional Apple Intelligence implementation (iOS 26, `FoundationModels`, availability-gated, off by default). Model answers
  are checked (`DescriptionAnswerParser`) and only ever suggest a merchant name, a category from the user's own list and an
  explanation. They never compute totals or change records.
- **Performance:** matching computes day numbers and merchant keys once and compares each line only with transactions
  within the date reach (binary search). PDF pages are read and OCR'd one at a time.
- **Privacy:** documents are read from the picker's security-scoped URL into memory and not copied. Only the last four
  digits of account numbers are kept, and PDF passwords are never stored. Statement data is included in encrypted
  backups, and can be deleted separately while transactions are kept.

## Data safety

- **Category delete:** deleting a category that is in use requires a reassignment (move to a category of the same kind, or leave
  uncategorized). Budgets for the deleted category are deactivated, not deleted.
- **Payment method delete:** a payment method with history can only be deactivated, so past records keep it.
- **Transaction delete:** deleting a transaction always asks for confirmation. Duplicating opens an unsaved draft.
- **Store errors:** on a store-open failure the app shows an error. It never resets the store.

## Diagnostics

`Services/Diagnostics` is separate from financial data. `DiagnosticsService` (injected as `AppLogger`, shared instance by default) checks
the user's choice and writes under one lock; `LocalLogStore` keeps JSON Lines files; `DiagnosticPrivacyFilter` allows only catalog
events; `CrashDiagnosticsService` listens to MetricKit only while wanted; `DiagnosticExportService` validates and zips. It starts before
the database and adds no SwiftData models. See [DIAGNOSTICS.md](DIAGNOSTICS.md).

## Future: split transactions

A parent transaction holds the total, and child `TransactionSplit` rows (category, amount) add up to it.
Category totals will come from the children, while cash flow counts the parent once.
