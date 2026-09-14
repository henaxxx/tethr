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
| macOS | 26.0+ — 1.0 (libgphoto2) shipping; `main` now uses ImageCaptureCore |
| iOS | 17.0+ — submitted, awaiting review |

Other PTP cameras will likely manage file listing, previews and import. Remote
control leans on vendor-specific opcodes and is Nikon-shaped today. If you own
something else, see [Adding a camera](#adding-a-camera) — that is the single
most useful thing anyone could contribute.

## Layout

```
TethrKit/  Swift package shared by both apps: PTP packets, property
           descriptors, NEF parsing, Nikon live view, per-model safety rules.
mac/       Swift Package. Raw PTP over ImageCaptureCore, via TethrKit.
ios/       xcodegen project. Raw PTP over ImageCaptureCore, via TethrKit.
probe/     A bare harness for firing arbitrary PTP opcodes at a camera from iOS.
ios/store/site/   The website, deployed to Cloudflare Pages.
```

Both apps reach the camera the same way and share that layer. Until September
2026 the Mac app drove libgphoto2 instead; version 1.0 still does, and what that
route cost is kept below.

## Building

**macOS**

```sh
brew install exiftool          # only to bundle it; geotag writing uses it
cd mac && swift build          # development
./build.sh                     # assemble and sign Tethr.app
./build.sh release             # notarise and staple (needs a Developer ID)
```

`build.sh` copies ExifTool (a Perl script) into the bundle, so writing
locations into NEF files does not depend on Homebrew. Nothing else is bundled.

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

Both apps open the camera with ImageCaptureCore. It offers no remote shutter
worth using (`ICCameraDevice.requestTakePicture` is unavailable on iOS), but
`requestSendPTPCommand` accepts raw opcodes on iOS 13+ and macOS 10.15+, so
TethrKit builds PTP packets by hand: `PTP.swift` is the container format,
`PropDesc.swift` parses device property descriptors so the exposure scrubbers
are driven by what the camera actually reports rather than a hardcoded table,
`NEF.swift` walks the TIFF IFDs of a RAW file to find the embedded full-size
JPEG, `NikonLiveView.swift` holds the live view sequence, and
`CameraCapabilities` refuses opcodes known to hang Nikon 1 bodies.

**macOS** downloads every frame shot after connecting into the destination
folder. **iOS** leaves the RAW on the card and reads only the embedded JPEG,
importing to Photos on request.

## What cost the most time

Recorded here so that the next person does not have to rediscover it.

**macOS**

- Raw PTP through ImageCaptureCore behaves as it does on iOS: properties,
  capture, `ObjectAdded`/`CaptureComplete` events, downloads and live view
  (25 fps on a D300) all worked unchanged.
- `ptpcamerad` keeps the card catalogue while the camera stays attached, so a
  new session — even from a freshly launched app — is ready in milliseconds.
  After a camera power cycle commands block for about 40 s, and the "catalogue
  complete" callback fires before the files trickle in (about 10 a second).
- Downloads land with mode 0600. Set them back to 0644 if anything else will
  read them.
- Never start a subprocess from a SwiftUI computed property. It runs on every
  body evaluation and starves the main thread.

**macOS 1.0, libgphoto2**

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

**iOS**

- ImageCaptureCore *is* available on iOS (13.2+), and raw PTP commands *do* go
  through. Reports to the contrary are about older releases.
- Nikon's `ChangeCameraMode` is 0x90C2; 0x9008 is `DeleteProfile`. With the
  right opcode, live view works.
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

MIT, except for ExifTool, which the macOS build bundles under the Perl licence.
Mac 1.0 also bundled libgphoto2 and friends under LGPL-2.1.
See [LICENSE](LICENSE).

---

# 日本語

無線を持たない一眼カメラを、USB で Mac や iPhone につなぐアプリです。

撮ったカットがその場で届き、シャッターも絞りも ISO もアプリから操作でき、
ジオタグという概念が存在しなかった時代のカメラの RAW に、iPhone の GPS が入ります。

**動作確認は Nikon D300 のみ**です。ほかの PTP 対応機でも、一覧・プレビュー・
取り込みは動く見込みですが、リモート操作はメーカー独自のコマンドに依存します。
お持ちの機種で試した結果を Issue に投げていただけると、それが一番助かります。

構成は `TethrKit/`（両アプリ共通の、生の PTP を組み立てる部品）、`mac/`、`ios/`、
`probe/`（任意の PTP オペコードをカメラに投げる実験用）です。Mac 版も iOS 版も
ImageCaptureCore 経由で生の PTP 命令を送り、その部分を TethrKit で共有しています。
2026 年 9 月までの Mac 版（1.0）は libgphoto2 を使っていました。

ビルド手順と、実装中に時間を溶かした落とし穴は、上の英語セクションに全部書いて
あります。とくに「What cost the most time」は、同じことをやる人には役に立つはずです。

ライセンスは MIT です。macOS 版が同梱する ExifTool は Perl ライセンスのまま、
その条件に従います（Mac 版 1.0 が同梱していた libgphoto2 は LGPL-2.1）。
