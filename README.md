# 抖音数据分析 Skill

基于 `agent-browser` 的抖音创作者中心数据自动化读取与分析工作流。

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

## 使用方式

### 在 WorkBuddy 中使用

将 `SKILL.md` 所在目录放入 `~/.workbuddy/skills/douyin-data-analysis/`，然后在对话中说「帮我分析抖音数据」即可触发。

### 独立使用

```bash
# 1. 恢复登录态（首次需扫码）
bash scripts/restore_douyin_login.sh

# 2. 一键取数
WS=./output bash scripts/analyze_douyin.sh

# 3. 读取 output/douyin_analysis_*/douyin_data.json 进行分析
```

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
