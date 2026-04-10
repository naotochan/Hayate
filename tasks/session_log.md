# Session Log — PicSort

## プロジェクト概要
macOS ネイティブの RAW 写真選別アプリ。Swift + SwiftUI + Metal + CIRAWFilter。速度に全振り。3段階デコードパイプラインでRAW表示を極限まで高速化する。

---

## 2026-04-10 17:30

### 完了したこと
- /office-hours でプロダクト設計セッション実施
- Builder mode で「Engine First」アプローチを選定
- デザインドキュメント作成・レビュー（8.5/10, 2ラウンド, 6件修正）→ APPROVED
- CLAUDE.md にスキルルーティングルール追加

### 次のステップ
- OptiCull / FastRawViewer を1時間触って競合体験
- /plan-eng-review でアーキテクチャ詳細化
- Xcode プロジェクト作成 → CIRAWFilter PoC

### 気づき・メモ
- 競合が想像以上に強い（OptiCull, Keeper, Fovea）。差別化ポイントを実測で見つける必要あり
- CIRAWFilter の draft mode (kCIInputAllowDraftModeKey) の実測速度が設計の鍵
- LRU キャッシュサイズは MTLDevice.recommendedMaxWorkingSetSize で動的調整が必要
