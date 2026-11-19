# YouTube Tool

A native macOS app that downloads YouTube videos as mp4, or audio only as m4a, mp3, opus
or wav. yt-dlp, FFmpeg and Deno are built in, so nothing else needs installing.

Requires macOS 15 or later on Apple Silicon.

## Install with Homebrew

```sh
brew install --cask mkrajinov/tap/youtube-tool
```

Update with `brew upgrade --cask youtube-tool`. Remove with
`brew uninstall --cask youtube-tool`; add `--zap` to also delete settings and the
updatable yt-dlp copy.

Downloads are saved to `~/Downloads/YouTubeTool` (changeable in Settings). If downloads
start failing because YouTube changed something, use Settings → Tools → Update to fetch
the latest yt-dlp.

## Build from source

Needs Xcode 16 or later.

```sh
./scripts/build-app.sh      # fetches the pinned tools, builds YouTubeTool.app
open YouTubeTool.app
swift test                  # unit tests; YTT_LIVE=1 adds real download tests
```

## Release

1. Bump `VERSION`, commit, then tag and push: `git tag v<version> && git push origin main v<version>`.
2. The **Build and release** GitHub Action runs the tests, builds
   `YouTubeTool-<version>.zip` and the cask `youtube-tool.rb`, and attaches both to a
   GitHub release. With the `HOMEBREW_TAP_SSH_KEY` secret (private half of a write deploy
   key on [mkrajinov/homebrew-tap](https://github.com/mkrajinov/homebrew-tap), same as the
   fritzbox release) it also updates `Casks/youtube-tool.rb` there; otherwise copy the
   cask by hand.

Run it from the Actions tab for a test build without a release. Locally,
`./scripts/release.sh` produces the same files in `dist/`; with `SIGN_IDENTITY` and
`NOTARY_PROFILE` set it signs with a Developer ID and notarizes (see the script header).

## Third-party software

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). FFmpeg is GPLv3.
