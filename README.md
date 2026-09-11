# Tethr

Tethered shooting for cameras that were never meant to have it.

Plug a DSLR into a Mac or an iPhone over USB. Frames arrive as you take them,
the shutter and the exposure settings answer to the app, and your phone's GPS
ends up in the RAW files of a camera built before geotagging existed.

**[tethr.pages.dev](https://tethr.pages.dev/)** · macOS app available there ·
iOS app in App Store review

---

## Status

Written over two days in September 2026 against the camera the author owns.

| | |
|---|---|
| Tested camera | Nikon D300 (2007) |
| macOS | 26.0+ — built, signed, notarised, shipping |
| iOS | 17.0+ — submitted, awaiting review |

Other PTP cameras will likely manage file listing, previews and import. Remote
control leans on vendor-specific opcodes and is Nikon-shaped today. If you own
something else, see [Adding a camera](#adding-a-camera) — that is the single
most useful thing anyone could contribute.

## Layout

```
mac/     Swift Package. Links libgphoto2 directly from Swift.
ios/     xcodegen project. Raw PTP over ImageCaptureCore, no gphoto2.
probe/   A bare harness for firing arbitrary PTP opcodes at a camera from iOS.
ios/store/site/   The website, deployed to Cloudflare Pages.
```

The two apps share no code. They reach the camera by completely different
routes, and that is the interesting part of this repository.

## Building

**macOS**

```sh
brew install libgphoto2 pkg-config
cd mac && swift build          # development
./build.sh                     # bundle dependencies into Tethr.app
./build.sh release             # notarise and staple (needs a Developer ID)
```

`bundle-libs.sh` copies libgphoto2, its camlibs and iolibs, the transitive
dylibs and ExifTool into the bundle and rewrites the install names, so the
shipped app does not depend on Homebrew.

**iOS**

```sh
brew install xcodegen
cd ios && xcodegen generate
open TethrTouch.xcodeproj      # or: ./release.sh
```

Forking? Change `DEVELOPMENT_TEAM` in `ios/project.yml` and the bundle
identifiers. The team ID in this repository is the author's and is public
information — it appears in every signed binary — but it will not sign
anything for you.

## How it works

**macOS** drives libgphoto2 from a serial dispatch queue that owns the
`Camera` pointer, pumping `gp_camera_wait_for_event` at 200 ms (1 ms during
live view). Everything that touches libgphoto2's type-unsafe widget API goes
through a small C shim in `mac/Sources/CGPhoto/`.

**iOS** cannot use libgphoto2, and `ICCameraDevice.requestTakePicture` is
marked unavailable on the platform. But `requestSendPTPCommand` accepts raw
opcodes, so the app builds PTP packets by hand: `PTP.swift` is the container
format, `PropDesc.swift` parses device property descriptors so the exposure
scrubbers are driven by what the camera actually reports rather than a
hardcoded table, and `NEF.swift` walks the TIFF IFDs of a RAW file to find the
embedded full-size JPEG and fetches only those bytes.

## What cost the most time

Recorded here so that the next person does not have to rediscover it.

**macOS**

- `ptpcamerad` and `icdd` grab the USB device first. Kill them before opening
  the camera. SIP will not let you unload them via launchctl.
- A half-open PTP session survives a camera power cycle. Only `gp_port_reset()`
  clears it.
- `gp_widget_get_value` writes a different type depending on the widget — a
  RANGE widget gives you a float where you expected `char *`. Reading it wrong
  is an immediate SIGSEGV. Dispatch on the type in C, not in Swift.
- The CAMLIBS directory has an executable (`print-camera-list`) sitting beside
  the versioned directories. Picking the first entry by name loads nothing.
- `gp_camera_trigger_capture` takes camera control and does not give it back.
  Write `controlmode=0` to return it, or the body stays locked.
- `capturetarget` defaults to internal RAM: shots never reach the card, arrive
  named `capt0000.nef`, and never appear on the camera's own screen.
- Never start a subprocess from a SwiftUI computed property. It runs on every
  body evaluation and starves the main thread.

**iOS**

- ImageCaptureCore *is* available on iOS (13.2+), and raw PTP commands *do* go
  through. Reports to the contrary are about older releases.
- Live view and `ChangeCameraMode` (0x9008) are the exceptions: the responses
  are swallowed.
- Property-change events never arrive. Poll `NIKON_CheckEvent` (0x90C7) and
  widen the interval when nothing changes.
- The framework enumerates the entire card with `GetObjectInfo` at session
  start and there is no way to skip it. Split the tethered shots from the card
  contents in the UI so the wait is not in the way.
- Thumbnail requests ignore the size you ask for. Parse the RAW file yourself.
- Record locations independently of the camera connection. The track matters
  most while you are *not* tethered.

**Shipping**

- `fastlane` changes the working directory when it runs a lane. Resolve paths
  from `__dir__`.
- `deliver` uploads the binary *before* running precheck, so a precheck failure
  does not mean the upload failed.
- App Store Connect's API does not allow creating app records. `produce` uses
  the old Apple ID path instead, which is a separate outage risk.

## Adding a camera

`probe/` is an iOS app that sends arbitrary PTP opcodes to an attached camera
and prints the raw response. It is how every Nikon opcode in this repository
was confirmed.

If you have a camera that is not a D300:

1. Build and run `probe/`, attach the camera, and try `GetDeviceInfo` (0x1001).
   The operations array tells you what the body actually supports.
2. Open an issue with that output and your model name. Even just the device
   info is useful — it says what is possible before anyone writes code.

## Privacy

Neither app collects anything. No analytics, no advertising, no third-party
SDKs, no accounts. Location data stays on the device except when the user
explicitly sends it to their own Mac over the local network.
See [the privacy policy](https://tethr.pages.dev/privacy).

## Licence

MIT, except for the third-party libraries the macOS build bundles —
libgphoto2 and friends under LGPL-2.1, ExifTool under the Perl licence.
See [LICENSE](LICENSE).

---

# 日本語

無線を持たない一眼カメラを、USB で Mac や iPhone につなぐアプリです。

撮ったカットがその場で届き、シャッターも絞りも ISO もアプリから操作でき、
ジオタグという概念が存在しなかった時代のカメラの RAW に、iPhone の GPS が入ります。

**動作確認は Nikon D300 のみ**です。ほかの PTP 対応機でも、一覧・プレビュー・
取り込みは動く見込みですが、リモート操作はメーカー独自のコマンドに依存します。
お持ちの機種で試した結果を Issue に投げていただけると、それが一番助かります。

構成は `mac/`（libgphoto2 を Swift から直接リンク）、`ios/`（ImageCaptureCore
経由で生の PTP を組み立てる。gphoto2 は使っていません）、`probe/`（任意の PTP
オペコードをカメラに投げる実験用）の3つです。2つのアプリはコードを共有せず、
まったく別の経路でカメラに到達しています。

ビルド手順と、実装中に時間を溶かした落とし穴は、上の英語セクションに全部書いて
あります。とくに「What cost the most time」は、同じことをやる人には役に立つはずです。

ライセンスは MIT です。macOS 版が同梱する libgphoto2 は LGPL-2.1、ExifTool は
Perl ライセンスのまま、それぞれの条件に従います。
