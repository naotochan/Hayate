# Hayate

**Fast RAW photo culling for macOS.**

Hayate is a native macOS app for quickly reviewing and sorting RAW photos. Built with Metal and CIRAWFilter for GPU-accelerated decoding, it displays photos instantly with a 2-tier pipeline: embedded JPEG first, then full RAW.

## Features

- **Instant display** — Embedded JPEG shown in ~16ms, full RAW decode follows
- **Keyboard-driven** — Arrow keys to navigate, 1-5 to rate, P to favorite, X to reject
- **Prefetch** — Adjacent photos (N-1, N+1) decoded in background with LRU cache
- **Focus peaking** — Leica-style green edge overlay (F key)
- **Zoom & pan** — Scroll wheel zoom, drag to pan, Space for 2x toggle
- **Grid view** — Thumbnail overview with multi-select and filters (G key)
- **Compare mode** — Side-by-side comparison with pick/skip workflow (C key)
- **Persistence** — Ratings saved to `.hayate.json` in the photo folder

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `<-` `->` | Previous / Next photo |
| `1`-`5` | Set rating |
| `0` | Clear rating |
| `P` | Toggle favorite |
| `X` | Toggle reject |
| `F` | Toggle focus peaking |
| `Space` | Toggle fit / 2x zoom |
| `G` | Toggle grid view |
| `C` | Enter compare mode |
| `Enter` | Compare: pick (keep + reject other) |
| `Tab` | Compare: skip (new baseline) |
| `Cmd+Z` | Undo |
| `Cmd+O` | Open folder |
| `Delete` | Move to trash |

## Requirements

- macOS 14 (Sonoma) or later
- Metal-compatible GPU

## Build

```bash
xcodebuild -scheme PicSort -configuration Release build
```

## Supported Formats

CR3, CR2, NEF, ARW, DNG, and other RAW formats supported by CIRAWFilter.

## License

MIT

---

# Hayate

**macOS 向け高速 RAW 写真セレクトアプリ**

Hayate は RAW 写真の選別に特化した macOS ネイティブアプリです。Metal と CIRAWFilter による GPU アクセラレーションで、2段階パイプライン（埋め込み JPEG 即表示 → フル RAW デコード）により瞬時に写真を表示します。

## 機能

- **即時表示** — 埋め込み JPEG を ~16ms で表示、フル RAW デコードが続く
- **キーボード操作** — 矢印キーでナビ、1-5 でレーティング、P でお気に入り、X でリジェクト
- **プリフェッチ** — 前後の写真を LRU キャッシュで先読み
- **フォーカスピーキング** — Leica スタイルの緑エッジ表示（F キー）
- **ズーム & パン** — スクロールで拡大、ドラッグで移動、Space で 2 倍トグル
- **グリッド表示** — サムネイル一覧、複数選択、フィルター（G キー）
- **比較モード** — 並べて比較、ピック/スキップで素早く選別（C キー）
- **データ保存** — レーティングは写真フォルダ内の `.hayate.json` に保存

## 動作環境

- macOS 14 (Sonoma) 以降
- Metal 対応 GPU

## 対応フォーマット

CR3, CR2, NEF, ARW, DNG など CIRAWFilter がサポートする RAW フォーマット。

## ライセンス

MIT
