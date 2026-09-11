fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios create_app

```sh
[bundle exec] fastlane ios create_app
```

レコード作成の手順を表示（作成自体は Web 画面で行う）

### ios metadata

```sh
[bundle exec] fastlane ios metadata
```

掲載文だけを反映（ビルドもスクショも触らない）

### ios shots

```sh
[bundle exec] fastlane ios shots
```

スクリーンショットだけを反映（fastlane/screenshots/ を読む）

### ios upload_build

```sh
[bundle exec] fastlane ios upload_build
```

ビルド（.ipa）をアップロード。先に ./release.sh を実行しておくこと

### ios status

```sh
[bundle exec] fastlane ios status
```

App Store Connect 側の現在の状態を確認

### ios push_all

```sh
[bundle exec] fastlane ios push_all
```

掲載文 + スクショ + ビルド をまとめて反映（提出はしない）

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
