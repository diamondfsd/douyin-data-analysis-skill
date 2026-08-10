# 抖音数据分析 Skill

基于 `agent-browser` 的抖音创作者中心数据自动化读取与分析工作流。适用于任何支持浏览器自动化的 AI Agent 平台。

## 功能

- 自动恢复登录态（`--profile` 持久化浏览器目录，cookie 自动保存，免扫码优先）
- 单次加载首页并抓取创作者中心官方接口原始数据（播放/点赞/评论/分享/粉丝等核心指标 + 逐视频明细）
- 输入创作者中心作品评论页链接，自动滚动加载并读取最近 200 条评论（可自定义上限），保留原始响应和结构化评论结果
- AI 读取数据后生成完整的 HTML 单页分析报告（含 Chart.js 图表、TOP5 排名、逐视频分析、数据驱动的优化建议）
- HTML 生成后直接交付，不做截图、读图或多尺寸视觉验收

## 目录结构

```
douyin-data-analysis-skill/
├── SKILL.md              # 技能主文件（完整工作流 + 字段参考 + 踩坑记录）
├── README.md             # 本文件
├── scripts/
│   ├── analyze_douyin.sh        # 一键取数脚本（恢复登录 → 抓接口 → 汇总 JSON）
│   ├── fetch_douyin_comments.sh # 指定作品评论页取数（滚动加载 → 原始响应 → 评论 JSON）
│   └── restore_douyin_login.sh  # 登录态恢复脚本（--profile 持久化，免扫码优先）
├── assets/               # 静态资源（预留）
└── references/           # 参考文档（预留）
```

## 前置依赖

- [agent-browser](https://www.npmjs.com/package/agent-browser)（浏览器自动化 CLI）
  ```bash
  npm install -g agent-browser
  ```
- Python 3（用于数据汇总脚本）
- 抖音创作者账号（需扫码登录一次）

## 平台适配

本技能的核心是两个 Shell 脚本（取数 + 登录恢复）和一个 SKILL.md（工作流定义），不绑定特定平台。`SKILL.md` 中描述的 AI 分析步骤（Step 5）是通用逻辑，任何能读文件、写 HTML 的 AI Agent 都能执行。

| 平台 | 接入方式 |
|------|---------|
| **WorkBuddy** | 将目录放入 `~/.workbuddy/skills/douyin-data-analysis/`，对话中触发即可 |
| **Claude Code / Cursor / Windsurf 等** | 将 `SKILL.md` 作为自定义指令或 system prompt 加载，脚本路径用绝对路径引用 |
| **其他 Agent 框架**（LangChain / AutoGPT 等） | 把 `SKILL.md` 作为 task description 注入，调用脚本获取 `douyin_data.json` 后交给 LLM 分析 |
| **纯命令行** | 手动跑脚本取数，自行用 `douyin_data.json` 做分析 |

> **注意**：`SKILL.md` 中部分内容（如 `present_files` 工具调用、交互红线规范）是 WorkBuddy 环境特有的。在其他平台使用时，这些部分可忽略或替换为对应平台的文件展示/用户交互机制，核心取数脚本不受影响。

## 使用方式

### 方式一：作为 AI Agent 技能使用

将 `SKILL.md` 加载到你的 AI Agent 上下文中，然后直接说「帮我分析抖音数据」，Agent 会按工作流自动完成取数和分析。

### 方式二：纯命令行独立使用

```bash
# 1. 恢复登录态（首次需扫码）
bash scripts/restore_douyin_login.sh

# 2. 一键取数
WS=./output bash scripts/analyze_douyin.sh

# 3. 读取 output/douyin_analysis_*/douyin_data.json 进行分析
```

### 读取指定作品的评论

复制创作者中心的作品评论页链接后直接执行。脚本默认取最近 200 条一级评论，第二个参数可设为 1 到 1000。

```bash
WS=./output bash scripts/fetch_douyin_comments.sh \
  'https://creator.douyin.com/creator-micro/interactive/comment?item_id=7672002224478918574&enter_from=content_manage_v2'

# 例如最多取 500 条
WS=./output bash scripts/fetch_douyin_comments.sh '<作品评论页链接>' 500
```

结果写入 `output/douyin_comments_*/`：

| 文件 | 说明 |
|------|------|
| `comment_requests.json` | 页面加载过程中捕获的评论相关请求记录 |
| `raw/` | 浏览器已完成请求的原始响应 |
| `comments.json` | 去重后的结构化一级评论，供分析使用 |

脚本仅接受 `creator.douyin.com` 的作品评论页链接。页面以滚动方式加载，脚本会等待请求不再增加后停止；当作品评论不足或页面未加载完整时，`comments.json` 的 `meta.returned_count` 会小于请求上限。

取数完成后，`douyin_data.json` 包含结构化的核心指标和逐视频明细，你可以：
- 交给任意 LLM（ChatGPT / Claude / DeepSeek 等）生成分析报告
- 用 Python / Excel 自行做数据可视化
- 导入 BI 工具做长期跟踪

## 数据来源

所有数据均通过**抖音创作者中心官方页面**（creator.douyin.com）读取，用户需自行扫码登录、以本人身份访问自己账号的数据。不涉及任何接口破解、反爬绕过或越权访问。

## 输出说明

| 文件 | 说明 |
|------|------|
| `overview.json` | overview/all 接口原始响应 |
| `items.json` | item/list 接口原始响应 |
| `douyin_data.json` | 汇总后的结构化数据（AI 分析的主输入） |
| `comments.json` | 指定作品的结构化一级评论（默认最多 200 条） |

## 技术要点

- **登录态持久化**：使用 `--profile` 持久化浏览器目录（`~/.agent-browser/profiles/douyin`），cookie/localStorage 自动实时写入磁盘，跟正常 Chrome 一样。一次扫码后只要 cookie 没过期就不用再扫
- **代理豁免**：所有脚本开头 `export HTTP_PROXY=""`，避免 agent-browser 的 Chromium 报 `ERR_NO_SUPPORTED_PROXIES`
- **快速取数**：首页只加载一次，两个核心接口出现后立即抓取，不使用重复导航和固定 5 秒等待
- **数据提取优先级**：原始 JSON > DOM 解析；除登录二维码外不截图
- **直接交付**：生成 HTML 后直接返回文件，不重新打开、不截图、不读图、不做重复验收
- **关键接口**：`overview/all`（首页数据总览）、`item/list`（作品列表）
- **评论读取**：滚动作品评论页面，读取浏览器已完成的评论列表响应；不拼接、猜测或重放接口请求
- **比率类指标**：JSON 中为小数（如 0.2174），展示时需 ×100 转百分比

## License

MIT
