# CWA for iPhone — first build

A native SwiftUI companion for Calibre-Web Automated, targeting iOS 26+.
Uses the system Liquid Glass tab bar when built with Xcode 26.

## Included
- HTTPS server login with credentials stored in this device's Keychain
- Alphabetical library, recently added, paginated title/author search
- Authenticated cover images and book details
- Browse normal and magic shelves
- Download books and export via the iOS share sheet to Files or a reader
- Light/dark appearance, Dynamic Type, native navigation

## Not yet included
Shelf editing, metadata editing, uploads, built-in reading, and iPhone/Kobo reading-position sync.
The app does not change your Kobo configuration or write to the CWA database.

## Compatibility and validation
Endpoints and Atom feed structure were checked against CWA tag v4.0.6.
This is an initial build, not a release tested on an iPhone or against your server.
GitHub's workflow compiles the app and runs parser/origin checks on a Mac.
An actual server login and device UI test are still required.

## Build without a Mac
1. Add `CWA`, `Tests`, `project.yml`, and this README to your repository root.
2. Ensure `.github/workflows/build-ios.yml` exists in GitHub. If the browser upload omits
   the dot-folder, choose Add file > Create new file, use that exact path, and paste
   the contents of `build-ios.yml` from the top level of this download.
3. Commit to `main`. Open Actions > Build iPhone app.
4. When the run succeeds, download the `CWA-iPhone` artifact from the run summary.
5. Extract that artifact ZIP to obtain `CWA.ipa`.
6. Transfer the IPA to Files on your iPhone (iCloud Drive works), open AltStore >
   My Apps > +, and select it. Keep AltServer running and reachable during installation.

The IPA is unsigned; AltStore signs it using your account. No Apple credentials or
signing certificates are needed in GitHub. Free-account signing needs refreshes
before the seven-day expiration. Artifacts are automatically removed after three days;
you can keep a downloaded copy and run another build when needed.

## Connect
Enter the CWA HTTPS base address and your CWA username/password, not your Apple Account.
Use the normal site URL, not the Kobo `/kobo/...` token URL. The app accepts a trailing
`/opds` and normalizes it. HTTP Basic authentication must be available on CWA's OPDS
endpoints. Accounts requiring an interactive SSO/MFA login are not supported in this build.
CWA user's existing catalog visibility and download permissions apply.

## Privacy
Server details are entered only on the phone. Requests and redirects are restricted
to the same HTTPS origin. No analytics, external libraries, or cloud proxy. A public
source repository does not expose your books. Do not commit real credentials or URLs.

## Sources used to check compatibility
- https://github.com/crocodilestick/Calibre-Web-Automated/tree/v4.0.6
- `cps/opds.py` and `cps/templates/feed.xml` in that tag
- https://developer.apple.com/documentation/swiftui/tabview

The client is an independent implementation; it does not bundle CWA source code.
