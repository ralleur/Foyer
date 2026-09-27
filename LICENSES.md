# Licenses

## Vela

The Vela source code in this repository is licensed under the **GNU General Public License v3.0** (see `LICENSE`). As the sole copyright holder you may distribute builds under additional terms (for example through the App Store); the GPL only binds recipients of the code. No third-party GPL code is included, so nothing forces the combined work into GPL-incompatible territory.

## Third-party dependencies

| Component | Version | License | Use |
| --- | --- | --- | --- |
| [MPVKit](https://github.com/mpvkit/MPVKit) (`MPVKit` product, **not** `MPVKit-GPL`) | 1.0.0 | LGPL v3.0 for the bundles as declared by the project | advanced playback engine |
| ├ libmpv | 0.41 | LGPL v2.1+ (built without GPL components) | player core |
| ├ FFmpeg | 9.0 | LGPL v2.1+ (no `--enable-gpl`, no non-free) | demuxing/decoding |
| ├ libass | | ISC | ASS/SSA rendering |
| ├ libplacebo | | LGPL v2.1+ | GPU rendering, tone mapping |
| ├ MoltenVK | | Apache 2.0 | Vulkan on Metal |
| ├ shaderc | | Apache 2.0 | shader compilation |
| ├ dav1d | | BSD-2-Clause | AV1 software decoding |
| ├ uavs3d | | BSD | AVS3 decoding |
| ├ libdovi | | MIT | Dolby Vision RPU handling |
| ├ FreeType | | FTL (BSD-style) | fonts |
| ├ HarfBuzz | | MIT (old) | text shaping |
| ├ FriBidi | | LGPL v2.1+ | bidirectional text |
| ├ libunibreak | | Zlib | line breaking |
| ├ lcms2 | | MIT | color management |
| ├ uchardet | | MPL 1.1 / GPL 2 / LGPL 2.1 (tri-license, used under LGPL) | subtitle charset detection |
| ├ GnuTLS, nettle, GMP | | LGPL v2.1+ / LGPL v3 | TLS for FFmpeg |
| ├ OpenSSL | | Apache 2.0 | TLS |
| ├ libbluray | | LGPL v2.1+ | (linked by MPVKit; not used by Vela) |
| Jellyfin server & API | | GPL-2.0 (server) | Vela uses only the public HTTP API; no Jellyfin code is included |
| XcodeGen | | MIT | development tool only, not shipped |

The exact component versions are those bundled in MPVKit release 1.0.0 (see the upstream `Package.swift` checksums; Xcode's `Package.resolved` pins the release).

## Rejected on license grounds

- **KSPlayer** — GPL-3.0; would make App Store distribution problematic.
- **MPVKit-GPL** — adds GPL-licensed libsmbclient and GPL FFmpeg components; not needed for HTTP playback.
- **FFmpeg with `--enable-gpl`** (libx264, libpostproc…) — not needed for playback.

## LGPL compliance checklist for distribution

LGPL allows use in a proprietary/App Store app if users can relink or replace the library. Before submitting to the App Store:

1. Keep this file and the in-app *Open source licenses* screen up to date; ship the LGPL license texts (the MPVKit repository contains them) with the app or link to them.
2. Provide the library sources or a written offer: MPVKit's repository with build scripts (`make build`) reproduces every xcframework used.
3. Relinking: MPVKit ships dynamic xcframeworks, so the libraries can be replaced in the app bundle; do not enable static linking or symbol stripping that would prevent this. If a static configuration is ever used, publish the app's object files or keep the dynamic build.
4. Do not modify the libraries without publishing the modifications.

## App Store notes

- `NSAllowsArbitraryLoads` is enabled so users can reach plain-HTTP Jellyfin servers on their home network; App Review typically accepts this for media server clients with the justification "connects to user-configured private media servers".
- GPL-3.0 for the app itself is fine for a self-published app because the copyright holder is the publisher; third parties who fork the code must comply with GPL-3.0 (and cannot publish to the App Store without their own license grant).
