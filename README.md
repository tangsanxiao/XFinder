# XFinder

A high-performance, minimal macOS multi-pane file manager — built to make working alongside coding agents (like Claude Code) and managing what they produce smooth and fast.

**[English](#english) · [中文](#中文)**

---

## English

XFinder keeps several folders visible in one window so you can view, compare, move, rename, and organize files across directories at once — without juggling Finder windows. On top of solid file management, it adds an agent-aware layer: see what an agent just changed, review the diff, and hand context to the local Claude CLI — all without leaving the app.

Designed and implemented with help from an LLM. It doesn't try to replace Finder; it's a focused workspace for multi-directory, agent-driven workflows.

### Basic file management

- Group multiple folders into one **workspace**; show them as independent panes in one window.
- Per-pane navigation: back / forward / parent folder / breadcrumb path.
- List, icon, and column views — chosen **per pane**.
- Workspace layouts: Single, Two/Three Columns, Three Rows, Grid, and Main + Stack; the layout auto-fits as panes are added or closed.
- **Keyboard navigation** in the focused pane: ↑/↓ move (Shift extends), →/← expand/collapse folders, Return renames, Cmd+↓ open, Cmd+↑ parent, Cmd+Delete trash. Selection follows you across folder jumps.
- **Cmd+F** filter the current folder; **Cmd+Option+F** recursively search the focused folder; **Cmd+Shift+G** go to a path; double-click empty space to go up.
- **Category quick-filter**: narrow a pane to documents / code / data / images / archives / logs / build-and-dependency noise (rule-based, no LLM).
- Multi-selection with Shift / Cmd / Cmd+A; context-menu copy/move to another pane, duplicate, compress to zip (collision-safe), move to Trash — all act on the whole selection.
- Drag files onto a folder row to move them (multi-file aware); inline rename; create folders and Markdown files; undo/redo common file operations.
- Double-click a Markdown file to open the built-in lightweight reader/editor. Preview, source, and split modes support headings, links, task lists, tables, code blocks, and local images; saves detect external changes before overwriting.
- Finder-style essentials: Space Quick Look, Cmd+I Get Info, app menu commands for common File/Edit actions, and a cancellable file-task overlay for long compression jobs.
- Read Aloud for selected Markdown, text/code/data files, HTML/RTF, and searchable PDFs. Optional Doubao Speech provides a more natural voice; configuration/network failures automatically fall back to the local macOS voice.
- Real Finder system icons; sortable, resizable columns; relative modified dates; zebra striping.
- Live auto-refresh via FSEvents; reveal in Finder; open Terminal at a folder.
- Starred folders and system bookmarks (Desktop, Downloads, Documents, …) in the sidebar.
- Pane locations, sort order, view mode, and settings persist across launches; bilingual UI (English / 中文, follows the system by default).

### AI agent workflow

- **Agent Inbox**: a cached local review workbench that aggregates Claude / Codex sessions and git activity by project. It shows agent-session counts, uncommitted changes, risk findings, lazily extracted decisions / todos, and a commit-message draft; projects can be pinned, multi-selected, and hidden locally, and detail text can be selected for copying.
- **Git awareness**: changed files show a status badge (modified / untracked / added / …) inline; folders mark when their contents changed.
- **Project status card** (per repo): current branch, uncommitted-change count, and recent commits.
- **Recent changes**: the files git reports as changed, newest-first by modification time — the fast answer to "what did the agent just touch?" Click one to jump to it.
- **Diff viewer**: open any changed file's `git diff` in-app with add/delete coloring (no editor or terminal needed).
- **All Sessions**: read local Claude / Codex transcripts, group them by project, search titles/projects/transcript text, and jump here directly from Agent Inbox related sessions.
- **Claude bridge** (opt-in, no API keys — it reuses your installed `claude` CLI):
  - *Explain with Claude* from the diff viewer — sends that file's diff as context so the explanation is about the actual edit (what changed, intent, risks).
  - *Analyze* / *Ask Claude…* / *Ask About Selection* against a folder.
  - *Open in Claude Code* — launch the interactive CLI in Terminal at the pane's directory.

### Settings

Open from the gear at the bottom of the sidebar:

- **Language** — System / 中文 / English.
- **Read Aloud** — optional Doubao Speech API key, resource, and voice; off by default with system-voice fallback.
- **Claude integration** — off by default; optional custom `claude` CLI path. When off, all Claude actions are hidden.
- **Debug mode** — shows the Activity & Errors panel and the Restart button.
- **What's New** — the in-app changelog.

### Build & run

```bash
swift run XFinder              # run from source
./scripts/build-app.sh         # build dist/XFinder.app
open dist/XFinder.app
swift test                     # run the test suite
```

### Distribution

`scripts/release.sh` builds, ad-hoc signs, zips, and writes a SHA-256 checksum into `release/`; `.github/workflows/release.yml` publishes a GitHub Release on a `v*` tag. Download `XFinder-*-macOS-*.zip` from Releases, unzip, and move `XFinder.app` to `/Applications`.

Test builds are **ad-hoc signed**, so on first launch macOS may block the app — right-click `XFinder.app` → **Open** → confirm. Public distribution still needs Developer ID signing + Apple notarization.

### Limitations

- Not Developer ID signed or notarized yet; packaged build targets Apple Silicon.
- Not full Finder parity (no tags, smart folders, server browsing, rich metadata editing).
- Automated tests cover pure / file-operation / git-parsing logic; GUI behavior is verified manually.

### License

MIT — see `LICENSE`. Bundled dependency licenses are listed in `THIRD_PARTY_NOTICES.md`.

---

## 中文

XFinder 把多个文件夹放进同一个窗口,让你在多个目录之间同时查看、对比、移动、重命名和整理文件,无需在 Finder 窗口间来回切换。在扎实的文件管理之上,它加了一层"Agent 感知"能力:看清 agent 刚改了什么、直接看 diff、把上下文交给本机 Claude CLI——全程不离开应用。

本工具在 LLM 辅助下设计与实现。它不追求替代 Finder,而是为"多目录 + agent 驱动"的工作流提供一个聚焦的工作区。

### 基础文件管理

- 把多个文件夹组织进一个**工作区**,以独立面板在同一窗口展示。
- 每个面板独立导航:后退 / 前进 / 上级目录 / 面包屑路径。
- 列表、图标、Column 三种视图,**按面板**各自选择。
- 工作区布局:单面板、双列 / 三列、三行、网格、主面板+堆叠;增删面板时布局自动适配。
- 聚焦面板的**键盘导航**:↑/↓ 移动(Shift 扩选)、→/← 展开折叠、Return 重命名、Cmd+↓ 打开、Cmd+↑ 上级、Cmd+Delete 删除;导航跨目录时选中态自动衔接。
- **Cmd+F** 过滤当前目录;**Cmd+Option+F** 递归搜索当前面板目录;**Cmd+Shift+G** 前往路径;双击空白返回上级。
- **类型快速过滤**:把面板收窄到文档 / 代码 / 数据 / 图片 / 压缩包 / 日志 / 构建依赖噪音(纯规则,不用 LLM)。
- Shift / Cmd / Cmd+A 多选;右键复制/移动到另一面板、复制副本、压缩为 zip(自动避免重名)、移到废纸篓——均对整组选中生效。
- 把文件拖到文件夹行即移动(支持多选);内联重命名;新建文件夹和 Markdown 文件;常见文件操作支持撤销/重做。
- 双击 Markdown 文件可进入内置轻量阅读器/编辑器;支持阅读、源码、分屏模式以及标题、链接、任务列表、表格、代码块和本地图片,保存前会检测外部修改,避免静默覆盖。
- Finder 基础体验:空格 Quick Look、Cmd+I 查看信息、菜单栏常用 File/Edit 命令,以及可取消的压缩任务浮层。
- 朗读所选 Markdown、文本/代码/数据文件、HTML/RTF 和可搜索 PDF;可选豆包语音获得更自然的效果,未配置、断网或请求失败时自动切回 macOS 系统语音。
- 真实 Finder 系统图标;可排序、可调宽的列;相对修改时间;斑马纹。
- 基于 FSEvents 的实时自动刷新;在 Finder 中显示;在目录打开终端。
- 侧边栏收藏夹与系统书签(桌面、下载、文稿……)。
- 面板位置、排序、视图模式与设置跨启动持久化;中英双语界面(默认跟随系统)。

### AI Agent 工作流

- **Agent Inbox**: 带缓存的本地审查工作台,按项目聚合 Claude / Codex 会话和 git 活动。它展示 agent 会话数、未提交变更、风险提示、懒加载抽取的决策 / 待办,并生成 commit message 草稿;项目可置顶、多选、本地隐藏,详情文本可选中复制。
- **Git 感知**:变更文件行内显示状态徽标(修改 / 未跟踪 / 新增 / …);文件夹在内容有变化时标记。
- **项目状态卡片**(每个仓库):当前分支、未提交变更数、最近提交。
- **最近变更**:git 报告的变更文件,按修改时间最新在前——快速回答"agent 刚动了什么?",点击即跳转。
- **Diff 速览**:在应用内打开任意变更文件的 `git diff`,加/删行着色(无需编辑器或终端)。
- **全部会话**: 读取本机 Claude / Codex transcript,按项目归组,支持标题、项目和 transcript 正文搜索;可从 Agent Inbox 的相关会话直接跳转。
- **Claude 桥接**(默认关闭,不存任何 API key——复用你已安装的 `claude` CLI):
  - diff 里的 *用 Claude 解释* —— 把该文件 diff 作为上下文,解释这次改动(改了什么、意图、风险)。
  - 针对目录的 *分析* / *向 Claude 提问* / *针对选中提问*。
  - *在 Claude Code 中打开* —— 在终端于该目录启动交互式 CLI。

### 设置

从侧边栏底部的齿轮进入:

- **语言** —— 跟随系统 / 中文 / English。
- **文件朗读** —— 可选配置豆包语音 API Key、资源和音色;默认关闭并始终保留系统语音兜底。
- **Claude 集成** —— 默认关闭;可自定义 `claude` CLI 路径;关闭时所有 Claude 入口隐藏。
- **Debug 模式** —— 显示"操作与错误记录"面板和重启按钮。
- **What's New** —— 应用内更新日志。

### 构建与运行

```bash
swift run XFinder              # 从源码运行
./scripts/build-app.sh         # 构建 dist/XFinder.app
open dist/XFinder.app
swift test                     # 运行测试
```

### 分发

`scripts/release.sh` 会构建、ad-hoc 签名、打包并生成 SHA-256 校验文件到 `release/`;推送 `v*` tag 时 `.github/workflows/release.yml` 自动创建 GitHub Release。从 Releases 下载 `XFinder-*-macOS-*.zip`,解压后把 `XFinder.app` 移到 `/Applications`。

测试版本为 **ad-hoc 签名**,首次打开 macOS 可能拦截——右键 `XFinder.app` → **打开** → 确认。正式公开分发仍需 Developer ID 签名 + Apple 公证。

### 局限

- 尚未 Developer ID 签名与公证;打包版本面向 Apple Silicon。
- 不追求完整 Finder 对齐(无标签、智能文件夹、服务器浏览、丰富元数据编辑)。
- 自动化测试覆盖纯逻辑 / 文件操作 / git 解析;GUI 行为人工验证。

### 许可

MIT — 见 `LICENSE`;随应用分发的依赖许可见 `THIRD_PARTY_NOTICES.md`。

### 许可证

MIT —— 详见 `LICENSE`。
