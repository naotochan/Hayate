# Hayate

**Fast RAW photo culling for macOS.**

Hayate is a native macOS app for quickly reviewing and sorting RAW photos. Built with Metal and CIRAWFilter for GPU-accelerated decoding, it displays photos instantly with a 2-tier pipeline: embedded JPEG first, then full RAW.

## Features

- **Instant display** — Embedded JPEG shown in ~16ms, full RAW decode follows
- **Keyboard-driven** — `J`/`L` to navigate, `K`/`M`/`O` for Keep / Maybe / Out (stars profile optional)
- **Draft cull** — JPEG/cache-only navigation; full RAW on focus peaking or zoom (`D`)
- **Prefetch + disk cache** — Neighbors warmed in the background with LRU memory/disk cache
- **Focus peaking** — Leica-style green edge overlay (`F`)
- **Zoom & pan** — Scroll wheel zoom, drag to pan, Space for 2× toggle
- **Grid view** — Thumbnail overview with multi-select, filters, and scene gaps (`G`)
- **Compare mode** — Two-photo pick/skip tournament (`C`)
- **Survey mode** — Optionally skip already-decided photos (Settings)
- **Sidebar** — Pinned / Recent folders (`⌘B`); recent list also on the empty screen
- **Export** — Copy or move Keep (+ Maybe) picks (`⌘E`); optional XMP sidecars
- **Persistence** — Ratings saved to `.hayate.json` in the photo folder

## Keyboard Shortcuts

Defaults (rebindable in Settings; press `?` for the in-app cheat sheet):

| Key | Action |
|-----|--------|
| `J` / `L` | Previous / Next photo |
| `←` / `→` | Previous / Next (aliases) |
| `K` / `M` / `O` | Keep / Maybe / Out |
| `1`–`5` / `0` | Set / clear stars (stars profile) |
| `F` | Toggle focus peaking |
| `D` | Toggle draft cull mode |
| `I` | Toggle EXIF overlay |
| `H` | Toggle histogram |
| `Space` | Toggle fit / 2× zoom |
| `G` | Toggle grid view |
| `C` | Enter compare (2 photos) |
| `Enter` | Compare: keep / pick active |
| `Tab` | Compare: skip (new baseline) |
| `?` | Shortcuts help |
| `⌘B` | Toggle folder sidebar |
| `⌘E` | Export picks |
| `⌘O` | Open folder |
| `⌘Z` | Undo |
| `Delete` | Move to trash |

## Requirements

- macOS 14 (Sonoma) or later
- Metal-compatible GPU

## Install

Download the latest `.zip` from [Releases](../../releases), unzip, and drag `Hayate.app` to your Applications folder.

## Build from source

```bash
# Development
xcodebuild -scheme Hayate -configuration Debug build

# Local install to /Applications (bumps build number)
./scripts/dev-install.sh --run

# Release (.app in build/release/dist/)
./scripts/build-release.sh 0.7.0
```

## Supported Formats

CR3, CR2, NEF, ARW, DNG, and other RAW formats supported by CIRAWFilter.
JPEG-only shots are shown too; for RAW+JPEG pairs only the RAW is listed.

## License

MIT

---

# Hayate

**macOS 向け高速 RAW 写真セレクトアプリ**

Hayate は RAW 写真の選別に特化した macOS ネイティブアプリです。Metal と CIRAWFilter による GPU アクセラレーションで、2段階パイプライン（埋め込み JPEG 即表示 → フル RAW デコード）により瞬時に写真を表示します。

## 機能

- **即時表示** — 埋め込み JPEG を ~16ms で表示、フル RAW デコードが続く
- **キーボード操作** — `J`/`L` でナビ、`K`/`M`/`O` で Keep / Maybe / Out（星プロファイルも可）
- **Draft cull** — JPEG/キャッシュだけでナビ。ピーキングやズーム時のみフル RAW（`D`）
- **プリフェッチ + ディスクキャッシュ** — 前後を LRU で先読み
- **フォーカスピーキング** — Leica スタイルの緑エッジ（`F`）
- **ズーム & パン** — スクロールで拡大、ドラッグで移動、Space で 2 倍トグル
- **グリッド表示** — サムネイル一覧、複数選択、フィルター、シーン区切り（`G`）
- **比較モード** — 2 枚のピック/スキップ（`C`）
- **Survey モード** — 決定済みをスキップして未決定だけ周回（設定）
- **サイドバー** — Pinned / Recent（`⌘B`）。空画面にも Recent を表示
- **書き出し** — Keep（+ Maybe）のコピー/移動（`⌘E`）。任意で XMP サイドカー
- **データ保存** — `.hayate.json` に保存

## インストール

[Releases](../../releases) から最新の `.zip` をダウンロード → 解凍 → `Hayate.app` を Applications フォルダへ。

## 動作環境

- macOS 14 (Sonoma) 以降
- Metal 対応 GPU

## 対応フォーマット

CR3, CR2, NEF, ARW, DNG など CIRAWFilter がサポートする RAW フォーマット。
JPEG のみの写真も表示されます（RAW+JPEG ペアは RAW のみ一覧に表示）。

## ライセンス

MIT
