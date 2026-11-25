# TallySeam

> Formerly *MyMoney AI*. TallySeam has its own app ID (`io.github.aravindmarri.tallyseam`), so on an iPhone it
> installs as a new, empty app next to the old one. To bring your data over, export an encrypted backup from the
> old app (Settings → Backup & Data) and import it into TallySeam; old backups are still accepted.

An offline, private iPhone app for tracking income, expenses, receipts and bills.
It is built with SwiftUI, SwiftData, Swift Charts and Apple Vision, targets iOS 17+, and uses no third-party packages, accounts or network access.

> **Build status:** GitHub Actions compiles the app and runs 302 tests on every push (all passing). An unsigned IPA is produced for re-signing.
> See [docs/BUILD_STATUS.md](docs/BUILD_STATUS.md) for what has been verified and what hasn't.

## Repository layout

```
TallySeam/                ← repository root
├── project.yml           ← XcodeGen spec (source of truth for the Xcode project)
├── TallySeam/            ← app sources (this is the source folder, not a nested project)
│   ├── App/  Models/  Features/  Services/  Components/  Utilities/  Resources/
│   └── Tests/            ← unit tests (Swift Testing + XCTest), synthetic data only
├── tools/check_sources.py← static checks that run on Windows
└── docs/                 ← ARCHITECTURE, ROADMAP, BUILD_STATUS
```

The `.xcodeproj` is generated on the Mac and is not committed.

## INSTALL_ON_IPHONE

Install and test TallySeam on your own iPhone from a Windows PC, **free**: no paid Apple Developer membership, no TestFlight, no Mac.

> **Status:** CI builds the device app and checks it automatically (see [docs/BUILD_STATUS.md](docs/BUILD_STATUS.md)). Installing on a physical iPhone has **not been verified yet**. Please report what happens.

### What you need (all free)

- Windows 10/11 PC and a USB cable for the iPhone
- iPhone on iOS 17 or later
- A free Apple Account. You may prefer a secondary free Apple Account just for sideloading (see the note on Sideloadly below).
- **iTunes** and **iCloud** for Windows, downloaded **from apple.com, not the Microsoft Store**. Sideloadly needs Apple's device drivers from these installers.
- **Sideloadly** from sideloadly.io (free)

### 1. Download the app (`TallySeam-unsigned-ipa`)

1. Sign in to GitHub and open the repository's **Actions** tab, then the **iOS Build** workflow.
2. Open the most recent run with a green tick on `main`.
3. Under **Artifacts**, download **`TallySeam-unsigned-ipa`**. GitHub delivers it as a ZIP, so unzip it to get **`TallySeam-unsigned.ipa`**.
4. Artifacts are kept for 14 days. If they have expired, open **iOS Build → Run workflow** on `main` to build a fresh one. This is free for a public repository.

The IPA is **unsigned and can't be installed as-is**. Sideloadly signs it with your Apple Account in the next step. CI checks that it is the real arm64 iPhone app (not the simulator build) with bundle ID `io.github.aravindmarri.tallyseam`.

### 2. Prepare the iPhone (first time only)

1. Connect the iPhone by USB, unlock it, and tap **Trust This Computer**.
2. Install with Sideloadly once (step 3). Then on the iPhone, turn on **Settings → Privacy & Security → Developer Mode**, restart, and confirm.

### 3. Sign and install with Sideloadly

1. Open Sideloadly. Your iPhone should appear under **iDevice**.
2. Drag `TallySeam-unsigned.ipa` into the window.
3. Enter your Apple Account email, then click **Start**. Enter the password and any two-factor code when Sideloadly asks; they go to Apple to create a free 7-day signing certificate.
4. **Keep the bundle ID as it is.** In *Advanced options*, leave "Change Bundle ID" off. A constant bundle ID is what lets later installs replace the app **and keep its data**.
5. When it finishes, on the iPhone go to **Settings → General → VPN & Device Management**, tap your Apple Account under *Developer App*, and tap **Trust**.
6. Open **TallySeam**.

### 4. Refresh every 7 days (without losing data)

With a free Apple Account, the signature lasts **7 days**. After that the app won't open, **but its data stays on the iPhone**.

- To refresh, run step 3 again with the **same Apple Account** and the **same (unchanged) bundle ID**, using the same IPA or a newer one. Sideloadly installs over the existing app and your data is kept.
- **Don't delete the app to refresh it.** Deleting an iPhone app erases its data, including TallySeam's database and receipt images.
- Updating to a newer build works the same way: download the newer artifact and install over the old one.
- Free-account limits: up to 3 sideloaded apps at a time, and 10 new app IDs per 7 days. Keeping the bundle ID constant uses only one.
- Optional: Sideloadly can refresh automatically over Wi-Fi while the PC is on. Manual refresh is enough.

If the bundle ID ever changes, iOS treats the app as a different one. You'd get a second, empty copy, and the old copy keeps the old data until it is deleted.

### 5. Back up before you enter real data

1. **Settings → Backup & Data → Export Encrypted Backup**, then choose a password of at least 8 characters.
2. Save the file in **Files**, then copy it to your PC. A backup stored only on the iPhone is lost with the iPhone. If you save to iCloud Drive, the encrypted file leaves the device; that's your choice.
3. **Import Backup** only *adds* items that aren't already there; it never overwrites or deletes. The password can't be recovered.

Make a backup before every refresh or update, at least until on-device testing is complete.

### 6. Personal test checklist

- [ ] App opens; the default categories are present and there is no sample data
- [ ] Add, edit and delete a transaction; force-close (swipe up in the app switcher), reopen: changes are kept
- [ ] Turn on **Airplane Mode**: scan a receipt (camera and Photos), view charts and reports, export a backup. Everything works offline
- [ ] Bills: add, record payment, skip; budgets show progress
- [ ] Settings → Backup & Data → Spreadsheet: export transactions as CSV and open it in Excel; import a bank statement CSV, check the preview, import, then import it again: nothing is added twice
- [ ] Face ID / passcode lock (Settings → Security): locks after leaving the app; the app switcher shows the privacy screen
- [ ] Export a backup, re-sign and reinstall with Sideloadly (step 4): data is still there
- [ ] Larger text sizes, VoiceOver and dark mode look right

### A note on Sideloadly and your Apple Account

Sideloadly is a free third-party tool, not made by Apple. It needs your Apple Account password to request the free signing certificate from Apple. If you'd rather not use your main account, create a separate free Apple Account for sideloading. TallySeam itself never sees your Apple Account and has no network access.

## Developing on Windows

Windows can't compile or run iOS apps. On Windows you can:

1. Edit Swift sources in any editor. VS Code with the Swift extension gives syntax highlighting.
2. Run the static checks with Python 3. They catch unbalanced brackets, duplicate type names and test files that are missing an import:
   ```bash
   python tools/check_sources.py
   ```
3. Commit and push with Git.

These checks are **not** compilation. Type errors, API misuse and test failures only show up on a Mac.

## Building on a Mac

Requirements: macOS with **Xcode 16 or later** (iOS 17+ SDK, Swift Testing) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
XcodeGen is a build-time tool only; the app has no dependencies.

```bash
brew install xcodegen
```

```bash
git clone https://github.com/aravindmarri/TallySeam.git && cd TallySeam
```

```bash
xcodegen generate
```

```bash
xcodebuild -project TallySeam.xcodeproj -scheme TallySeam -destination 'platform=iOS Simulator,name=iPhone 16' build test
```

To run on an iPhone from a Mac, open `TallySeam.xcodeproj` in Xcode, set your Team under *Signing & Capabilities* for the TallySeam target, choose your device, and run. Without a Mac, see [INSTALL_ON_IPHONE](#install_on_iphone).

After the first Mac build, record the results in `docs/BUILD_STATUS.md`.

## Privacy

- Everything stays on the device. The app has no iCloud sync, analytics, ads or accounts, and never connects to your bank.
- Developer Diagnostics is off by default, stays on the device and is shared only by a manual export. It holds no personal or financial data: see [docs/DIAGNOSTICS.md](docs/DIAGNOSTICS.md).
- Never commit screenshots of real finances, real receipts, local databases, exports, signing keys or credentials. `.gitignore` blocks common cases, but always review `git status` before committing.

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Roadmap](docs/ROADMAP.md)
- [Build status](docs/BUILD_STATUS.md)
- [Developer diagnostics](docs/DIAGNOSTICS.md)
