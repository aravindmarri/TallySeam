#!/usr/bin/env python3
"""Windows-friendly static sanity checks for the Swift sources.

This is NOT a compiler. It catches structural mistakes that are easy to make
without Xcode: unbalanced brackets, duplicate top-level type names, and files
that would be added to the wrong target. It also fails if app code uses any
network or iCloud API, since the app must work fully offline. Run: python tools/check_sources.py
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / "TallySeam"
PAIRS = {")": "(", "]": "[", "}": "{"}


def strip_strings_and_comments(src: str) -> str:
    """Remove comments and string literal contents (keeping interpolations' structure out)."""
    out, i, n = [], 0, len(src)
    while i < n:
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j == -1 else j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j == -1 else j + 2
        elif src.startswith('"""', i):
            j = src.find('"""', i + 3)
            i = n if j == -1 else j + 3
            out.append('""')
        elif src[i] == '"':
            j = i + 1
            depth = 0
            while j < n:
                if src[j] == "\\" and j + 1 < n and src[j + 1] == "(":
                    depth += 1; j += 2; continue
                if depth and src[j] == ")":
                    depth -= 1; j += 1; continue
                if src[j] == "\\":
                    j += 2; continue
                if src[j] == '"' and depth == 0:
                    break
                if src[j] == "\n":
                    break
                j += 1
            out.append('""')
            i = j + 1
        else:
            out.append(src[i]); i += 1
    return "".join(out)


def check_balance(path: pathlib.Path, errors: list) -> None:
    code = strip_strings_and_comments(path.read_text(encoding="utf-8"))
    stack = []
    line = 1
    for ch in code:
        if ch == "\n":
            line += 1
        elif ch in "([{":
            stack.append((ch, line))
        elif ch in PAIRS:
            if not stack or stack[-1][0] != PAIRS[ch]:
                errors.append(f"{path.relative_to(ROOT)}:{line}: unexpected '{ch}'")
                return
            stack.pop()
    for ch, ln in stack:
        errors.append(f"{path.relative_to(ROOT)}:{ln}: unclosed '{ch}'")


# APIs that would let the app reach the network or sync off the device. The app must work fully offline.
NETWORK_APIS = re.compile(
    r"\b(URLSession|URLRequest|NWConnection|NWPathMonitor|CFNetwork|WKWebView|SFSafariViewController|"
    r"CKContainer|CKDatabase|NSUbiquitousKeyValueStore|ubiquityIdentityToken|openURL)\b"
    r"|\bimport\s+(Network|CloudKit|WebKit)\b|https?://")


# The only web addresses allowed: the developer's own pages on the About screen. A SwiftUI Link hands
# the address to Safari; the app itself makes no network request.
ALLOWED_LINKS = re.compile(
    r'^\s*Link\(destination: URL\(string: "https://(aravindmarri\.com|blogs\.aravindmarri\.com|github\.com/aravindmarri)"\)!\) \{$')


def check_offline(path: pathlib.Path, errors: list) -> None:
    """Scans every line except pure comment lines (string literals are included on purpose)."""
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if line.lstrip().startswith("//"):
            continue
        if NETWORK_APIS.search(line) and not ALLOWED_LINKS.match(line):
            errors.append(f"{path.relative_to(ROOT)}:{n}: network or cloud API in app code: {line.strip()}")


def main() -> int:
    errors: list = []
    files = sorted(APP.rglob("*.swift"))
    decl = re.compile(r"^(?:@\w+\s+)*(?:public |private |fileprivate |internal )?(?:final )?(struct|class|enum|protocol|actor)\s+(\w+)", re.M)
    seen: dict = {}
    for f in files:
        check_balance(f, errors)
        text = strip_strings_and_comments(f.read_text(encoding="utf-8"))
        is_test = "Tests" in f.parts
        for _, name in decl.findall(text):
            key = (name, is_test)
            if key in seen:
                errors.append(f"duplicate type '{name}' in {f.relative_to(ROOT)} and {seen[key]}")
            seen[key] = f.relative_to(ROOT)
        if not is_test:
            check_offline(f, errors)
        if is_test and "@testable import TallySeam" not in text:
            errors.append(f"{f.relative_to(ROOT)}: test file missing '@testable import TallySeam'")
    print(f"Checked {len(files)} Swift files.")
    for e in errors:
        print("ERROR", e)
    print("OK" if not errors else f"{len(errors)} problem(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
