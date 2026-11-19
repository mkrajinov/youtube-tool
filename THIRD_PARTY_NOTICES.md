# Third-party software

YouTube Tool runs these programs as separate processes. They ship unmodified in
`YouTubeTool.app/Contents/Helpers`; versions are pinned in `scripts/fetch-tools.sh`.

## yt-dlp

- Project: https://github.com/yt-dlp/yt-dlp
- License: The Unlicense (public domain). The standalone `yt-dlp_macos` build also
  contains Python and other components under their own licenses, listed in
  `THIRD_PARTY_LICENSES.txt` on the yt-dlp release page.

## FFmpeg (ffmpeg, ffprobe)

- Project: https://ffmpeg.org
- Build: static macOS arm64 build by Martin Riedl, https://ffmpeg.martin-riedl.de
- License: GNU General Public License version 3 (built with `--enable-gpl --enable-version3`).
  The complete corresponding source is the FFmpeg release tarball
  (https://ffmpeg.org/releases/) for the version in `scripts/fetch-tools.sh`, plus the
  build scripts at https://git.martin-riedl.de/ffmpeg/build-script.
  License text: https://www.gnu.org/licenses/gpl-3.0.txt

## Deno

- Project: https://github.com/denoland/deno
- License: MIT, https://github.com/denoland/deno/blob/main/LICENSE.md
