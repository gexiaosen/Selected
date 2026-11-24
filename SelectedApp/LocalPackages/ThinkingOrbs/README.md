# ThinkingOrbs（本地 vendor 拷贝）

- 上游：<https://github.com/haplollc/ThinkingOrbs>
- 版本：**1.1.0** · commit `e2c07bbdec4db797fb302300ef0159b1806a909f`（2026-09-18）
- 许可：MIT —— 见 `LICENSE`（含原作者 Jakub Antalik 与 Haplo LLC 的双版权声明）

## 这个目录的规矩

- `Sources/ThinkingOrbs/` 下 6 个源文件**逐字节等于上游**，本项目不在此改动它们。
  需要本地行为差异时，在 `Sources/SelectedApp/` 侧包一层，不要改这里。
- 只 vendor 运行期需要的东西：上游的 `Tests/`（含 611KB 黄金向量）、`assets/`（README 用的
  GIF/MP4）、`Scripts/` 一概不拷。
- **升级方式**：重新拷贝 6 个源文件 + `LICENSE`，然后重跑浅色/深色、Reduce Motion
  与菜单栏后台驻留的目视验收（界面验收脚本不覆盖动效）。

决策记录：`docs/specs/README.md`