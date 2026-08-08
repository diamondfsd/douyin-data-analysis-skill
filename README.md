# 抖音数据分析 Skill

基于 `agent-browser` 的抖音创作者中心数据自动化读取与分析工作流。适用于任何支持浏览器自动化的 AI Agent 平台。

## 功能

- 自动恢复登录态（免扫码优先，cookie 注入恢复）
- 抓取创作者中心官方接口原始数据（播放/点赞/评论/分享/粉丝等核心指标 + 逐视频明细）
- AI 读取数据后生成完整的 HTML 单页分析报告（含 Chart.js 图表、TOP5 排名、逐视频分析、数据驱动的优化建议）

## 目录结构

```
douyin-data-analysis-skill/
├── SKILL.md              # 技能主文件（完整工作流 + 字段参考 + 踩坑记录）
├── README.md             # 本文件
├── scripts/
│   ├── analyze_douyin.sh        # 一键取数脚本（恢复登录 → 抓接口 → 汇总 JSON）
│   └── restore_douyin_login.sh  # 登录态恢复脚本（cookie 注入，免扫码）
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
| `dashboard_*.png` | 创作者中心首页截图（存档用） |
| `content_*.png` | 内容管理页截图（存档用） |

## 技术要点

- **登录态恢复**：`--session-name` 的自动恢复不生效，需手动注入 cookie（`restore_douyin_login.sh`）
- **数据提取优先级**：原始 JSON > DOM 解析 > 截图
- **关键接口**：`overview/all`（首页数据总览）、`item/list`（作品列表）
- **比率类指标**：JSON 中为小数（如 0.2174），展示时需 ×100 转百分比

## License

MIT
