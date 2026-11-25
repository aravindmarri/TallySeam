# Developer diagnostics

Optional, local-only logging, crash reports and performance times. **Off by default**, also after an update.
Nothing is uploaded: a report leaves the iPhone only when the user exports and shares it.

## Use it

1. Settings → Developer Diagnostics → **Enable Diagnostics**.
2. Choose a logging level. Optionally turn on performance monitoring and crash reports.
3. Use the app, then review Logs, Crash Reports or Performance.
4. **Export Diagnostic Report** shows a preview, asks for confirmation and creates `TallySeam-Diagnostics-YYYY-MM-DD.zip`.
5. Turning it off stops collection at once. Existing reports can still be viewed, exported or cleared.

If the database can't be opened, the error screen offers the same export when reports exist.

## Privacy design

- **Catalog, not free text.** The level, category and message of an event come from `DiagnosticCode`. Callers can't pass text.
- **Errors** are reduced to an allowlisted domain and a numeric code. Descriptions and `userInfo` are never read.
- **Operation ids** are eight random characters, new each time. No record, account, installation or hardware ids.
- **MetricKit** payloads are never stored raw. Only numbers, binary names, binary UUIDs and offsets are copied.
- Every record is checked when written, when read, and again before export. A failed check blocks the export.

| Level setting | Records |
|---|---|
| Errors only | ERROR, CRITICAL |
| Standard | INFO, WARNING, ERROR, CRITICAL |
| Verbose | Everything, with the same privacy rules |

## Storage

`Application Support/Diagnostics/`, apart from financial data. JSON Lines, 256 KB per file, 7 days, 5 MB in total (oldest
deleted first). iOS file protection is on, and the folder is excluded from device backups and from TallySeam backups.
Preferences are in UserDefaults, so a database failure can still be diagnosed. Low disk space and damaged records are skipped.

## Limits

- iOS doesn't report every crash. Reports usually arrive after a restart, up to a day later.
- Closing the app, or iOS ending it in the background, is not a crash. Daily exit counts come from iOS.
- TallySeam installs no signal handlers. Breadcrumbs are written when an operation starts, so the last one shows what was running.
- CI tests use synthetic data on the simulator. **MetricKit delivery has not been verified on a real iPhone.**

## Read a report on Windows

Unzip it. Open the `.json` and `.jsonl` files in any editor, or list the errors:

```powershell
Get-Content application-logs.jsonl | ConvertFrom-Json | Where-Object level -in ERROR,CRITICAL | Format-Table timestamp,eventCode,durationMs,errorDomain,errorCode
```

Never attach a report to a public issue without reviewing it, and never commit one. `.gitignore` blocks the usual names.

## Symbolicate a crash (macOS)

1. From the CI run of the **same build number**, download the `TallySeam-dSYM-…` artifact (its name has the run number and commit; kept 90 days).
2. Check that the UUIDs match the frame's `binaryUUID`: `dwarfdump --uuid TallySeam.app.dSYM`.
3. For a `TallySeam` frame with offset N (decimal):

```bash
atos -o TallySeam.app.dSYM/Contents/Resources/DWARF/TallySeam -arch arm64 -offset N
```
