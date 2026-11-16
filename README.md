# Shrink

An iPhone app that makes a video or photo small enough to send: compress it to fit Discord, an email,
WhatsApp or any size limit, and share it. Everything happens on the phone; nothing is uploaded.

- `ios/` the SwiftUI app, the compression engine (`ShrinkCore`) and its tests. XcodeGen builds the Xcode
  project from `ios/project.yml`.
- `shared/presets.json` each destination's size limit, with its official source and the date it was checked.
- `.github/workflows/` builds and tests on GitHub's Macs; an `ios-*` tag uploads to TestFlight.

Copyright © 2026 ajejey. All rights reserved. The code is public to read; it is not licensed for reuse.
