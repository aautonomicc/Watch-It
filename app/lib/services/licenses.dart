import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Registers licenses Flutter's own registry can't see: the app's own
/// code, the Rust crates statically linked into libwatchit_core, the
/// native media libraries media_kit loads, and the bundled Anton font.
///
/// self_encryption is GPL-3.0, which makes every W@tch binary a combined
/// work distributed under GPLv3 (own code stays MIT) — so the in-app
/// licenses page must carry the full GPL text. See COPYING.GPL-3.0 and
/// the README License section.
void registerNativeLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(['W@tch'], '''
W@tch's own source code is available under the MIT License:

MIT License

Copyright (c) 2026 aautonomicc

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Because this app links the GPL-3.0 self_encryption library (see its entry
on this page), the app as a whole — this binary you are running — is
distributed under the terms of the GNU General Public License v3. The
complete source code is available at
https://github.com/aautonomicc/Watch-It''');

    final gpl = await rootBundle.loadString('assets/licenses/gpl-3.0.txt');
    yield LicenseEntryWithLineBreaks(['self_encryption'], '''
self_encryption (https://crates.io/crates/self_encryption) is the
Autonomi network's chunk encryption library, statically linked into this
app's embedded client. It is licensed under the GNU General Public
License v3.0:

$gpl''');

    yield const LicenseEntryWithLineBreaks(['watchit_core Rust crates'], '''
The embedded Autonomi client and streaming server (libwatchit_core) is
built from these Rust crates, statically linked into this app. Except
for self_encryption (GPL-3.0, listed separately), all are under
permissive licenses:

ant-core (MIT OR Apache-2.0), axum (MIT),
blake3 (CC0-1.0 OR Apache-2.0), bytes (MIT),
futures (MIT OR Apache-2.0), hex (MIT OR Apache-2.0),
rmp-serde (MIT), rusqlite (MIT, bundling SQLite — public domain),
serde_json (MIT OR Apache-2.0), tokio (MIT), tokio-stream (MIT),
tracing (MIT), tracing-subscriber (MIT),
tracing-android (MIT OR Apache-2.0),
xor_name (MIT OR BSD-3-Clause),
plus their transitive dependencies under the same or compatible
permissive licenses.

Full license texts accompany each crate's source on crates.io and in the
Cargo registry.''');

    yield const LicenseEntryWithLineBreaks(['libmpv', 'FFmpeg'], '''
Video playback uses media_kit, which loads a prebuilt libmpv (the mpv
media player as a library) that itself incorporates FFmpeg.

mpv/libmpv is licensed under the GNU General Public License v2 or later
(with LGPL-2.1-or-later available for some build configurations);
FFmpeg is licensed under the GNU Lesser General Public License v2.1 or
later, with some optional parts under the GNU General Public License v2
or later. Both are compatible with this app's GPLv3 distribution terms.

Source code for these libraries is available from https://mpv.io and
https://ffmpeg.org. On Android the prebuilt libmpv and its build
scripts are published by the media_kit project at
https://github.com/media-kit/libmpv-android-video-build; on Linux the
AppImage bundles the Linux distribution's libmpv package, whose
copyright notices are included inside the AppImage under
usr/share/doc.''');

    final ofl = await rootBundle.loadString('assets/fonts/Anton-OFL.txt');
    yield LicenseEntryWithLineBreaks(['Anton font'], ofl);
  });
}
