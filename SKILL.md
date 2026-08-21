---
name: douyin-data-analysis
description: 抖音数据分析与复盘工作流。通过 ego-browser 直接操作抖音创作者中心，在同一任务空间中复用登录态、刷新页面、读取运营数据和指定作品评论，并生成数据驱动的分析报告。用户要求分析抖音作品评论、评论区反馈、评论主题，或提供 creator.douyin.com 的作品评论页链接时使用。
---

# 抖音数据分析与复盘

## 核心原则

浏览器由 AI agent 直接控制，任务空间是唯一的浏览器状态来源：

- 一个用户任务只创建一次 ego-browser task space，后续 heredoc 轮次复用同一个数字 ID。
- 登录态、打开的标签页、页面刷新和扫码进度都留在该任务空间中。不创建 profile，不导出 cookie，不调用“恢复登录”脚本。
- 需要刷新时直接对当前任务空间调用 `gotoAndWait` 或 `gotoUrl`；不要重新启动脚本来“恢复”页面。
- 普通页面先 `snapshotText()`，登录判断读 DOM 文本，不依赖 URL/title。
- 取数读取页面自身已经完成的网络响应；禁止 `fetch`、`serverFetch`、`browserFetch` 重放抖音请求。
- 登录、验证码、手机确认属于用户操作：截图后 `handOffTaskSpace(task.id)`。只有用户明确说继续，才用 `takeOverTaskSpace(task.id)` 接管。
- 数据脚本只做离线 JSON 归一化，不启动浏览器。

本技能只读取抖音创作者中心官方页面中用户本人已授权可见的数据，不修改内容、不自动回复、不批量互动、不越权访问。

## Task Space 生命周期

所有浏览器操作都通过 Bash heredoc 调用 ego-browser；不要先创建 Shell daemon 或写 `.js` 文件：

```bash
ego-browser nodejs <<'EOF'
const task = await useOrCreateTaskSpace('douyin data analysis')
await openOrReuseTab('https://creator.douyin.com/creator-micro/home', { wait: true, timeout: 30 })
cliLog(JSON.stringify({ taskId: task.id, page: await pageInfo() }))
cliLog(await snapshotText())
EOF
```

将第一次返回的 `task.id` 记为本次任务的唯一 ID。后续同一任务，包括刷新、重试、用户扫码后继续和重新取数，都用这个 ID：

```bash
ego-browser nodejs <<'EOF'
const task = await useOrCreateTaskSpace(123)
await gotoAndWait('https://creator.douyin.com/creator-micro/home', { timeout: 30, settle: 2 })
cliLog(await snapshotText())
EOF
```

用户接管后不能用 `useOrCreateTaskSpace` 抢回控制权。用户明确回复“继续”后，下一轮从 `takeOverTaskSpace(123)` 开始：

```bash
ego-browser nodejs <<'EOF'
const task = await takeOverTaskSpace(123)
await gotoAndWait('https://creator.douyin.com/creator-micro/home', { timeout: 30, settle: 2 })
cliLog(await snapshotText())
EOF
```

任务完成且不需要保留页面时，最后单独执行一个 heredoc：

```bash
ego-browser nodejs <<'EOF'
const result = await completeTaskSpace(123, { keep: false })
cliLog(JSON.stringify(result))
EOF
```

只有用户明确要求继续查看该页面、需要人工操作，或结果无法通过文件交付时才使用 `{ keep: true }`。检查 `done: true` 后再告知用户已经完成收尾。

## 登录和刷新

### 首次打开

打开首页后用 `snapshotText()` 和 DOM 文本判断状态：

```bash
ego-browser nodejs <<'EOF'
const task = await useOrCreateTaskSpace('douyin data analysis')
await openOrReuseTab('https://creator.douyin.com/creator-micro/home', { wait: true, timeout: 30 })
await wait(2)
const snapshot = await snapshotText()
const body = String(await js("document.body.innerText || ''"))
const loginPage = /扫码登录|验证码登录|密码登录|账号密码登录|创作者登录/.test(body + snapshot)
const needVerify = /需在手机上进行确认|请输入验证码|验证码已发送|短信验证码|安全验证|滑动验证|图形验证/.test(body + snapshot)
const dashboard = /数据概览|数据看板|数据中心|作品数据|粉丝分析|播放量|互动数据/.test(body + snapshot)
if (loginPage || needVerify) {
  const screenshot = await captureScreenshot()
  const handoff = await handOffTaskSpace(task.id)
  cliLog(JSON.stringify({ status: 'user_action_required', taskId: task.id, screenshot, handoff }))
} else {
  cliLog(JSON.stringify({ status: dashboard ? 'logged_in' : 'page_loading', taskId: task.id }))
}
EOF
```

需要用户扫码时，立即把 `screenshot` 返回的绝对路径展示给用户，只提示必要的扫码或验证动作。不要关闭任务空间，也不要创建新任务空间。

### 二维码过期或页面需要刷新

这是同一个页面任务的下一轮操作，不需要恢复脚本。用户确认继续后直接接管并刷新：

```bash
ego-browser nodejs <<'EOF'
const task = await takeOverTaskSpace(123)
await gotoAndWait('https://creator.douyin.com/creator-micro/home', { timeout: 30, settle: 2 })
await wait(2)
const screenshot = await captureScreenshot()
const handoff = await handOffTaskSpace(task.id)
cliLog(JSON.stringify({ status: 'qr_refreshed', screenshot, handoff }))
EOF
```

不要用 `restore_douyin_login.sh`、profile、cookie 文件、daemon 或切换 headed 模式处理这个流程；这些都绕开了 ego-browser 自己保存的任务状态。

## 首页数据读取

登录成功后，在同一个任务空间直接重新导航首页并监听页面请求。`Network.enable` 必须在导航前打开；先消费旧事件，再导航，避免把上一轮页面请求混进本轮结果：

```bash
ego-browser nodejs <<'EOF'
const fs = await import('node:fs/promises')
const task = await useOrCreateTaskSpace(123)
const outDir = '/absolute/path/to/douyin_analysis_YYYYMMDD_HHMMSS'
await fs.mkdir(outDir, { recursive: true })

await cdp('Network.enable', {})
await drainEvents()
await gotoAndWait('https://creator.douyin.com/creator-micro/home', { timeout: 30, settle: 2 })
await wait(6)

const snapshot = await snapshotText()
const body = String(await js("document.body.innerText || ''"))
if (/扫码登录|验证码登录|密码登录|创作者登录/.test(body + snapshot)) {
  cliLog(JSON.stringify({ status: 'login_required', taskId: task.id }))
} else {
  const events = await drainEvents()
  const responses = events
    .filter(event => event.method === 'Network.responseReceived' && event.params?.response?.url)
    .map(event => ({
      requestId: event.params.requestId,
      url: event.params.response.url,
      status: event.params.response.status,
      timestamp: event.params.timestamp || 0,
    }))

  const latest = (pattern) => responses
    .filter(row => pattern.test(row.url) && row.status >= 200 && row.status < 400)
    .sort((a, b) => b.timestamp - a.timestamp)

  const read = async (rows) => {
    for (const row of rows) {
      try {
        const result = await cdp('Network.getResponseBody', { requestId: row.requestId })
        if (result && result.body) return { ...row, responseBody: result.body, base64Encoded: Boolean(result.base64Encoded) }
      } catch (_) {}
    }
    return null
  }

  const overview = await read(latest(/(?:overview\/all|data\/overview\/dashboard|data\/overview\/all)/i))
  const items = await read(latest(/(?:item\/list|creator\/pc\/work_list)/i))
  if (!overview || !items) {
    cliLog(JSON.stringify({ status: 'missing_response', taskId: task.id, overview: Boolean(overview), items: Boolean(items) }))
  } else {
    await fs.writeFile(`${outDir}/overview.json`, JSON.stringify({ data: { responseBody: overview.responseBody } }, null, 2))
    await fs.writeFile(`${outDir}/items.json`, JSON.stringify({ data: { responseBody: items.responseBody } }, null, 2))
    cliLog(JSON.stringify({ status: 'raw_data_saved', taskId: task.id, outDir, overviewUrl: overview.url, itemsUrl: items.url }))
  }
}
EOF
```

`outDir` 是 AI agent 根据当前工作目录生成的绝对路径，直接替换示例中的占位值。不要把接口 URL 复制出来再用 Node `fetch` 请求；只使用页面自身的请求和 CDP 响应体。

然后运行离线归一化：

```bash
RAW_DIR=/absolute/path/to/douyin_analysis_YYYYMMDD_HHMMSS \
  bash scripts/analyze_douyin.sh
```

该脚本只读取 `overview.json` 和 `items.json`，生成同目录的 `douyin_data.json`，并写入 `douyin_archive/` 历史存档。

## 评论读取

评论页面也复用当前任务空间；如果它是同一个用户任务，可以继续使用 `123`，否则创建一个短名称如 `douyin comments analysis`：

```bash
ego-browser nodejs <<'EOF'
const fs = await import('node:fs/promises')
const task = await useOrCreateTaskSpace('douyin comments analysis')
const pageUrl = 'https://creator.douyin.com/creator-micro/interactive/comment?item_id=7672002224478918574&enter_from=content_manage_v2'
const outDir = '/absolute/path/to/douyin_comments_YYYYMMDD_HHMMSS'
await fs.mkdir(`${outDir}/raw`, { recursive: true })

await cdp('Network.enable', {})
await drainEvents()
await gotoAndWait(pageUrl, { timeout: 30, settle: 2 })
await wait(2)
const snapshot = await snapshotText()
const body = String(await js("document.body.innerText || ''"))
if (/扫码登录|验证码登录|密码登录|创作者登录/.test(body + snapshot)) {
  const screenshot = await captureScreenshot()
  const handoff = await handOffTaskSpace(task.id)
  cliLog(JSON.stringify({ status: 'login_required', taskId: task.id, screenshot, handoff }))
} else {
  let events = await drainEvents()
  let idleRounds = 0
  let lastCommentRequestCount = -1
  const maxScrolls = 30
  for (let index = 0; index < maxScrolls; index += 1) {
    await js(String.raw`(() => {
      const candidates = Array.from(document.querySelectorAll('*'))
        .filter(element => element.scrollHeight > element.clientHeight + 80
          && getComputedStyle(element).overflowY !== 'visible')
        .sort((a, b) => (b.scrollHeight - b.clientHeight) - (a.scrollHeight - a.clientHeight))
      const target = candidates[0] || document.scrollingElement || document.documentElement
      target.scrollTop = target.scrollHeight
      window.scrollTo(0, document.documentElement.scrollHeight)
      return { scrollTop: target.scrollTop, scrollHeight: target.scrollHeight }
    })()`)
    await wait(0.8)
    events = events.concat(await drainEvents())
    const count = events.filter(event => event.method === 'Network.requestWillBeSent'
      && /comment/i.test(event.params?.request?.url || '')).length
    if (count === lastCommentRequestCount) idleRounds += 1
    else { idleRounds = 0; lastCommentRequestCount = count }
    if (idleRounds >= 3) break
  }
  events = events.concat(await drainEvents())
  const requests = events
    .filter(event => event.method === 'Network.requestWillBeSent' && /comment/i.test(event.params?.request?.url || ''))
    .map(event => ({ requestId: event.params.requestId, url: event.params.request.url, timestamp: event.params.timestamp || 0 }))
  const responseRows = events
    .filter(event => event.method === 'Network.responseReceived' && /comment/i.test(event.params?.response?.url || ''))
    .map(event => ({ requestId: event.params.requestId, url: event.params.response.url, status: event.params.response.status, timestamp: event.params.timestamp || 0 }))
  const seen = new Set()
  const responseBodies = []
  for (const row of responseRows.sort((a, b) => a.timestamp - b.timestamp)) {
    if (seen.has(row.requestId) || row.status < 200 || row.status >= 400) continue
    seen.add(row.requestId)
    try {
      const result = await cdp('Network.getResponseBody', { requestId: row.requestId })
      if (result && result.body) {
        const index = responseBodies.length
        await fs.writeFile(`${outDir}/raw/comment_response_${String(index).padStart(3, '0')}.json`, JSON.stringify({ data: { responseBody: result.body } }, null, 2))
        responseBodies.push({ requestId: row.requestId, url: row.url, status: row.status })
      }
    } catch (_) {}
  }
  await fs.writeFile(`${outDir}/comment_requests.json`, JSON.stringify({ data: { requests } }, null, 2))
  cliLog(JSON.stringify({ status: 'raw_comments_saved', taskId: task.id, outDir, responseCount: responseBodies.length }))
}
EOF
```

之后运行离线归一化，默认最多保留 200 条一级评论：

```bash
RAW_DIR=/absolute/path/to/douyin_comments_YYYYMMDD_HHMMSS \
  bash scripts/fetch_douyin_comments.sh \
  'https://creator.douyin.com/creator-micro/interactive/comment?item_id=7672002224478918574&enter_from=content_manage_v2' \
  200
```

评论响应不足、页面提前停止或字段缺失时，保留实际数量和 `null`，不要把缺失字段当成零值。

## AI 分析与输出

读取 `douyin_data.json` 生成报告；评论任务读取 `comments.json`。报告应包括：

1. 概览、播放/点赞/评论/分享/粉丝总量/净增粉丝及环比。
2. `overview.play.daily` 播放趋势。
3. 按播放量排序的近期作品 TOP5、明细表和逐视频点评。
4. 基于标题、完播率、跳出率、互动率的内容共性。
5. 数据驱动的优化建议；评论任务还要归纳需求、异议、问题、建议和高频主题，不输出评论者个人资料。

参考阈值：5 秒完播率低于 35% 时检查前三秒钩子；2 秒跳出率高于 40% 时检查封面与开场预期；点赞率低于 3%、评论率低于 0.5%、分享率低于 0.2% 时分别补充价值、讨论点和可收藏性。必须结合样本量和作品类型解释。

任务完成后，用独立最终 heredoc `completeTaskSpace(taskId, { keep: false })` 结束任务空间。用户要求保留页面时才使用 `{ keep: true }`。

## 输出字段

`douyin_data.json` 的 `overview[]` 包含 `key`、`label`、`current`、`last_period_incr`，播放项额外包含 `daily[]`；`videos[]` 包含 `title`、`create_time`、`create_date` 和 `metrics`：

`view_count`、`like_count`、`comment_count`、`share_count`、`favorite_count`、`completion_rate_5s`、`completion_rate`、`bounce_rate_2s`、`avg_view_second`、`like_rate`、`comment_rate`、`share_rate`、`cover_click_rate`、`fan_view_proportion`。

原始比率通常是小数，展示百分比时乘以 100。`fans.current_count` 可能不是页面当前粉丝口径，归一化脚本优先使用 `fans.option_list` 末日累计值。

`comments.json` 包含 `meta.item_id`、`meta.returned_count`、`meta.limit` 和 `comments[]`；评论项包含 `comment_id`、`text`、`create_time`、`like_count`、`reply_count`、`user.id`、`user.nickname`。

## 约束与排错

- `Unknown ref`：重新调用 `snapshotText()`，不要复用旧 ref。
- `w: 0` 或 `h: 0`：先切回真实页面标签、等待或刷新，再截图/坐标操作。
- 网络响应没有出现：确认 `Network.enable` 在导航前调用，并先 `drainEvents()` 清掉旧事件。
- 接口返回“用户未登录”：先看刷新后的 DOM；只有页面真的回到登录页才要求用户重新扫码。
- 任务空间显示用户正在控制：停止并等待用户明确确认，不能自动重试或接管。
- 不要在技能中增加 profile、cookie 导出、daemon、headed 切换或“恢复登录”脚本；ego-browser task space 已经提供持久化登录上下文。
