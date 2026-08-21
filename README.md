# 抖音数据分析 Skill

基于 `ego-browser` 直接操作抖音创作者中心的分析工作流。登录态和页面状态由 ego-browser task space 保存；AI agent 在同一任务空间中完成登录、刷新、取数和验证，不依赖 profile、cookie 文件或常驻 daemon。

## 目录

```text
douyin-data-analysis-skill/
├── SKILL.md
├── README.md
└── scripts/
    ├── analyze_douyin.sh          # 离线归一化首页原始 JSON
    └── fetch_douyin_comments.sh   # 离线归一化评论原始 JSON
```

## 依赖

- 已配置的 `ego-browser` 运行环境。
- Python 3，用于离线 JSON 归一化。
- 用户自己的抖音创作者中心账号。

## 正确的浏览器用法

首次打开时创建一个短名称任务空间，并记住返回的数字 ID：

```bash
ego-browser nodejs <<'EOF'
const task = await useOrCreateTaskSpace('douyin data analysis')
await openOrReuseTab('https://creator.douyin.com/creator-micro/home', { wait: true, timeout: 30 })
cliLog(JSON.stringify({ taskId: task.id, page: await pageInfo() }))
cliLog(await snapshotText())
EOF
```

后续刷新、扫码后检查、重试和取数都复用这个 ID：

```bash
ego-browser nodejs <<'EOF'
const task = await useOrCreateTaskSpace(123)
await gotoAndWait('https://creator.douyin.com/creator-micro/home', { timeout: 30, settle: 2 })
cliLog(await snapshotText())
EOF
```

如果用户接管了浏览器，必须等用户明确说继续，再从 `takeOverTaskSpace(123)` 开始。二维码或验证截图返回后直接展示给用户，不要重建任务空间或运行恢复脚本。

## 数据流程

在 ego-browser heredoc 内：

1. `snapshotText()` 和 DOM 文本确认登录状态。
2. 登录成功后，`Network.enable`、`drainEvents()`，再用 `gotoAndWait` 刷新首页。
3. 从页面自身的 `Network.responseReceived` 事件筛选总览和作品响应。
4. 用 `Network.getResponseBody` 读取响应体并写入 `overview.json`、`items.json`。
5. 运行离线归一化脚本。

```bash
RAW_DIR=/absolute/path/to/douyin_analysis_YYYYMMDD_HHMMSS \
  bash scripts/analyze_douyin.sh
```

输出 `douyin_data.json`，并将数据和作品原始响应存档到 `douyin_archive/`。

评论页同样直接由 ego-browser 打开和滚动，原始响应写入 `comment_response_*.json` 后运行：

```bash
RAW_DIR=/absolute/path/to/douyin_comments_YYYYMMDD_HHMMSS \
  bash scripts/fetch_douyin_comments.sh \
  'https://creator.douyin.com/creator-micro/interactive/comment?item_id=7672002224478918574&enter_from=content_manage_v2' \
  200
```

输出 `comments.json`，默认保留最多 200 条去重后的一级评论。完整的浏览器 heredoc、刷新、交接、CDP 取数和报告要求见 [SKILL.md](SKILL.md)。

## 安全边界

只读取用户本人在 `creator.douyin.com` 创作者中心可见的数据。不猜测或重放接口，不使用 `fetch` 绕过页面，不自动回复或批量互动，不保存或导出 cookie。
