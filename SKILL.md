---
name: douyin-data-analysis
description: 抖音数据分析与复盘工作流。通过 agent-browser 辅助登录抖音创作者中心，读取运营数据（播放量/粉丝/互动/作品）和指定作品的最近评论（默认 200 条），进行分析和报告生成。用户要求分析某作品评论、评论区反馈、评论主题，或提供 creator.douyin.com 的作品评论页链接时使用。全程通过创作者中心官方页面完成，仅读取用户本人已授权可见的数据。
---

# 抖音数据分析与复盘（实战版）

## Overview

基于 `agent-browser` CLI 的抖音数据读取工作流，分两个阶段、职责严格分离：

- **账号数据脚本 `analyze_douyin.sh`**：恢复登录 → 首页加载一次 → 抓 `overview/all` + `item/list` 原始接口 → 汇总成 `douyin_data.json`（含核心指标汇总 + 逐视频明细）。
- **评论脚本 `fetch_douyin_comments.sh`**：打开用户提供的作品评论页，滚动触发分页加载，从浏览器网络记录读取评论列表响应，默认汇总最近 200 条到 `comments.json`。两个脚本都不截图、不做分析、不生成 HTML。
- **阶段二（AI agent）只读取 `douyin_data.json`，生成完整 HTML 单页报告**：趋势解读、逐视频详细分析、数据驱动的建议和图表全部由 AI 完成（见 Step 5）。生成后直接交付，不做视觉验收。

全程走创作者中心官方页面，只读取用户本人已授权可见的数据。**登录态复用靠 `scripts/restore_douyin_login.sh` 把已保存的登录 cookie 注入浏览器（见下「登录态恢复（关键）」），一次扫码后基本可长期免扫码。**

核心教训来自实战：

- **登录态恢复用 `scripts/restore_douyin_login.sh`，别迷信 `--session-name` 的"自动恢复"**：`--session-name <name>` 在 `close` 时**确实**会把 cookies 存到 `~/.agent-browser/sessions/<name>-default.json`，但重新 `open` 时**不会把登录 cookie 注入浏览器**（实测：文件里有未过期的 `sid_tt`/`sessionid`，浏览器却仍是匿名态）。外部流传的 `agent-browser --session <id> --restore` 写法在当前版本**不存在**（`--restore` 不是有效 flag；`--session` 是隔离会话、不自动保存）。正确做法：跑 `bash scripts/restore_douyin_login.sh`——已登录就直接用；未登录就从 session 文件把 cookie 逐个 `cookies set` 注入、reload 即恢复，免去重复扫码。
- **无头 + 截图给用户扫码**：不需要开有头窗口。无头模式打开 → 截图 → **用 `present_files` 把二维码图真正展示给用户**（仅 `Read` 自己看没用，用户看不到）。用户扫完告诉我，我拿到数据后关掉即可，下次 `--session-name` 自动恢复。
- **后续操作复用 daemon**：同一次任务内不要 `close`，多个页面间直接用 `open` 导航（会复用已有浏览器）。**任务结束才 `close`**。
- **数据提取优先级：原始 JSON > 解析 DOM**。除登录二维码外不截图。首页同时触发两个核心接口，只加载一次并复用已签名的同源请求，详见 Step 4。
- **先执行、报错再处理（用户明确要求）**：不要每次都先用 `which` / `ls` 预先检测 `agent-browser` 是否安装、路径在哪。直接跑命令，只有命令真的报错（如 `command not found`、登录态失效）时才去排查或安装。这样能省掉一个永远多余的预检步骤。
- **唯一允许的截图是登录二维码**：仅在确实需要扫码时生成 `douyin_qrcode_<TS>.png`。数据后台和最终报告都不截图、不读图、不做桌面或移动端复核。

## 使用声明

本技能的所有数据读取均通过**抖音创作者中心官方页面**完成，用户需自行扫码登录、以本人身份访问自己账号的数据。技能本质是「代替用户手动翻看数据面板」的浏览器自动化辅助工具，不涉及任何接口破解、反爬绕过、或越权访问。仅读取已登录用户本人可见的运营数据。

最终产出为结构化的数据整理与文字分析，不提供全文复制、批量导出、或自动上传来历不明的图片/文件的能力。

## 交互与语言规范（必读红线）

> 🚨 **红线速记（每次开口前先过一遍）**：① 对用户说的每一句都必须是**简体中文**；② 你做的每一步（恢复登录、免扫码、抓数据、生成报告…）都是**内部动作，一个字都别告诉用户**；③ 用户唯一可能看到的「过程提示」只有一种——需要他扫码时，输出**且仅输出**一句「请用抖音 App 扫码登录，扫完告诉我」并 `present_files` 二维码；④ 除此之外，用户只看得到**最终分析报告**。多说一句废话（包括"报告已生成""登录已恢复"）都算违规。

- **❗ 面向用户的文字一律用中文（强制）**：用户是中文环境，所有给用户的解释、步骤、提醒、结论**必须全部用简体中文**。技能内部步骤 / 注释 / 字段名 / 代码可中英混排，但**对用户说的任何一句话都不能是英文**（踩坑 #13）。输出前自检：这条消息里有没有英文单词？有就改回中文。
- **❗ 严禁向用户输出任何"过程性状态"（最高红线）**：你执行的每个动作——恢复登录、注入 cookie、免扫码、抓接口、`analyze_douyin.sh` 取数、汇总成 `douyin_data.json`、脚本执行结果、生成报告、关闭浏览器——统统是**内部实现细节，用户一个字都不该看到**。绝对禁止对用户说「正在恢复登录」「无需扫码 / 不用扫描」「已抓取到 N 条数据」「登录态已保存，下次免扫码」「正在生成报告」等任何过程描述。这些只写在技能内部供你参考。
  - ✅ 用户唯一可能看到的「过程提示」只有一种情况：必须他本人扫码登录时，输出**且仅输出**一句中文——「请用抖音 App 扫码登录，扫完告诉我」——然后调用 `present_files` 把二维码给他。
  - ✅ 除此之外，用户应该**只看到最终的分析报告**（HTML 预览 + 结论文字）。
  - 🚫 连「分析报告已生成」「数据已分析完成」这种废话都不要说——把报告用 `present_files` 展示出来本身就是结果，不必再用文字复述一遍。
- **面向用户的文字必须极简**：给用户看的消息只允许「必要的最小指引 + 最终分析结果」。**严禁**把以下内容说给用户听——session 持久化、登录态复用、下次不用重新扫码、`--session-name`、接口路径/字段名、踩坑记录、`agent-browser` 工具名、CDP/daemon 等任何内部机制。这些只写在技能内部供你参考，绝不是给用户看的。用户只需要知道两件事：① 扫哪个码（仅当必须时）；② 分析结果出来了。多余一句都不要加。
- **截图必须真正"呈现"给用户**：本环境里把图片/文件展示给用户**唯一的途径是 `present_files` 工具**。截图后只 `Read` 自己看、或用文字描述"见上图"都**无效**——用户根本看不到。`screenshot` 落盘后，**紧接着必须调用 `present_files` 把该图片路径传出去**（踩坑 #12）。

## Prerequisites

- **不要预先检测工具是否可用**：直接执行 `agent-browser` 命令即可。若报 `command not found` 或类似「找不到命令」的错，再执行 `npm install -g agent-browser` 安装。避免「先用 `which` 检测、再执行」这类浪费步骤（见上方「先执行、报错再处理」原则）。
- 会话参数：统一用 `--session-name douyin`（所有命令都带，连接同一浏览器 daemon）。它的"自动保存"在 `close` 时有效（cookie 落盘到 `~/.agent-browser/sessions/douyin-default.json`），但"自动恢复"**不生效**——重开不注入 cookie。登录态恢复必须走 `scripts/restore_douyin_login.sh`（手动注入 cookie）。⚠️ 当前版本**没有 `--restore` 这个 flag**，也别用 `--session`（隔离会话）。
- 备选持久化：`--profile <path>`（完整 Chrome profile 目录，更重量级）；`--auto-connect`（连到用户已有的 Chrome 实例）

## Workflow

### Step 0：尝试无扫码恢复登录（每次分析必跑，优先于扫码）

**核心修正（实测）**：别再依赖 `--session-name` 的"自动恢复"——它不会注入 cookie，每次都变匿名态、被迫重新扫码。改用脚本：

```bash
bash scripts/restore_douyin_login.sh
```

脚本行为（幂等、可重复）：
- 已登录 → 输出 `ALREADY_LOGGED_IN` 并退出 0，直接进入 Step 3 取数；
- 未登录但 session 文件存在 → 从 `~/.agent-browser/sessions/douyin-default.json` 注入全部 cookie → reload → 恢复登录（输出 `RESTORED_LOGIN`）；
- 无 session 文件 / 注入后仍失败 → 输出 `NEED_QR_SCAN`，才走 Step 1 截图扫码。

> **关键红线**：恢复登录时**千万不要 `close` 当前浏览器再重开**——当前若是匿名态，`close` 会把匿名状态覆盖进 session 文件、毁掉里面完好的登录 cookie。直接对"当前浏览器"注入 cookie 即可。

一键取数（恢复登录 + 单次加载首页 + 抓取 + 汇总）：`bash scripts/analyze_douyin.sh`（输出到 `$WS` 或当前目录的 `douyin_analysis_<TS>/`，产物为 `overview.json`、`items.json`、`douyin_data.json`）。**报告不是脚本生成的**——AI 拿到 `douyin_data.json` 后按 Step 5 生成 HTML。

**自动存档（跨会话可用）**：每次取数后，脚本自动将 `douyin_data.json` + `items.json` 复制到 `$WS/douyin_archive/<TS>/` 并更新 `$WS/douyin_archive/index.json`。后续会话做分析时，AI 先读 `index.json` 即可发现所有历史快照，无需依赖上一次会话的 `douyin_analysis_*/` 目录。

```
$WS/douyin_archive/
├── index.json                  # 快照索引（ts / datetime / dir / files）
├── 20260808_101426/
│   ├── douyin_data.json        # 汇总数据（overview + videos + metrics）
│   └── items.json              # 原始接口响应（video_insight 等原始字段）
├── 20260808_134342/
│   └── ...
└── ...
```

**AI 做跨会话对比时的工作流**：读取 `index.json` → 取最近两次快照的 `douyin_data.json` → 逐视频做 diff → 生成变化报告。不再需要用户在同一会话里持续分析。

### Step 1：打开无头浏览器 + 截图给用户扫码（仅兜底）

**这是兜底路径，仅在 `restore_douyin_login.sh` 返回 `NEED_QR_SCAN` 时才用（首次使用或 cookie 已失效）。** 用 `--session-name douyin` 打开无头浏览器，截图给用户扫码。

```bash
# 打开（无头，用 session 名持久化）
agent-browser --session-name douyin open "https://creator.douyin.com/creator-micro/home"

# 短暂等待二维码渲染，不等待 networkidle
agent-browser wait 1000

# 截图给用户扫码（放到工作目录）
TS=$(date +%Y%m%d_%H%M%S)
agent-browser screenshot <workspace>/douyin_qrcode_${TS}.png
```

截图保存后，**必须立即调用 `present_files` 把该 PNG 展示给用户**（这是用户能看到二维码的唯一方式；只 `Read` 自己看或文字描述都无效）。展示后用中文提醒一句即可：「请用抖音 App 扫码登录，扫完告诉我」——**仅此一句，不要加任何补充说明**。

### Step 2：判断是否已登录（DOM 读取法，不用接口判定）

**关键教训（实测踩坑）**：`get url` / `get title` **不可靠**——登录页和后台都显示 `creator.douyin.com` 与标题「抖音创作者中心」，单看这两个字段会被骗（首次实战就因此误以为已登录、接口却空）。**判断是否登录唯一稳妥的办法是读页面 DOM 文本/结构**，看页面到底是登录页还是后台面板。**不要依赖接口或 URL 推断登录态。**

用户说「扫完了」后，用 `eval` 读 `document.body.innerText`，命中登录页特征字（「扫码登录 / 验证码登录 / 密码登录」）即为未登录，命中后台特征字（「数据概览 / 数据看板 / 作品数据 / 粉丝」等）即为已登录：

```bash
# 刷新，确保拿到最新登录态
agent-browser --session-name douyin reload
agent-browser wait 1000

# 读 DOM：判断是登录页还是后台（核心判断逻辑）
agent-browser --session-name douyin eval "(() => {
  const t = document.body.innerText;
  const isLoginPage = /扫码登录|验证码登录|密码登录|账号密码登录|打开「?抖音APP」?点击左上角/.test(t);
  const hasDashboard = /数据概览|数据看板|数据中心|作品数据|粉丝分析|近7日|播放量|互动数据/.test(t);
  return JSON.stringify({
    isLoginPage,
    hasDashboard,
    title: document.title,
    url: location.href,
    bodyLen: t.length
  });
})()"
```

判断规则：
- `isLoginPage === true` → 仍在登录页（二维码过期 / 没扫到）。重新 Step 1 截图给用户，并提醒重新扫。
- `hasDashboard === true` → 已进入后台，继续 Step 3 取数。
- 两者都为 false（如 loading 中）→ 再 `wait` 几秒或 `reload` 一次重试；仍不行再用 `snapshot -i` 看具体 DOM。

（可选）确认登录页二维码 canvas 是否渲染正常：
```bash
agent-browser --session-name douyin eval "!!document.querySelector('canvas, [class*=qrcode], [class*=login]')"
```

### Step 3：导航到目标页面取数

**所有命令统一带 `--session-name douyin`**，agent-browser 自动连接同名 session 的浏览器。

常用目标页面：
| 页面 | URL |
|------|-----|
| 首页/账号概览 | `https://creator.douyin.com/creator-micro/home` |
| 数据中心 | `https://creator.douyin.com/creator-micro/data-center/operation` |
| 内容管理 | `https://creator.douyin.com/creator-micro/content/manage` |
| 收入变现 | `https://creator.douyin.com/creator-micro/revenue/center` |

```bash
# 直接导航（复用已有浏览器，不新建窗口）
agent-browser --session-name douyin open "https://creator.douyin.com/creator-micro/data-center/operation"
agent-browser wait 1000

# 或用左侧菜单点击（先 snapshot 拿 ref）
agent-browser --session-name douyin snapshot -i
agent-browser --session-name douyin click <menuitem_ref>
```

### Step 4：提取数据（P0：拿原始 JSON）

> **优先级铁律**：数据提取 **第一选择永远是「抓接口原始 JSON」**（路 A）。DOM 解析（路 B）是接口拿不到时的兜底。除登录二维码外，不生成任何截图。

**性能规则**：首页会同时触发 `overview/all` 和 `item/list`。调用 `scripts/analyze_douyin.sh` 时只加载一次首页；脚本短轮询资源列表，接口出现后立即抓取，不为每个接口重复 `open`，也不使用固定 5 秒等待。

#### 路 A：获取接口返回的原始 JSON（P0 首选，最干净、自带每日趋势、最适合分析）

抖音创作者中心的运营数据通过官方接口返回（即页面上你正常看到的那些数字的来源），直接从浏览器网络请求中拿到原始响应体，比任何 DOM 解析都省事且完整。

```bash
# 1) 先清日志，再触发/刷新目标页，确保拿到干净请求
agent-browser --session-name douyin network requests --clear
agent-browser --session-name douyin open <目标页URL>        # 或 reload
sleep 4

# 2) 列出 xhr/fetch 请求，定位数据接口
agent-browser --session-name douyin network requests --type xhr,fetch --json \
  | grep -oE '"url":"https://creator.douyin.com/[^"]*"' | sed 's/"url":"//; s/"$//' | sed 's/?.*//' | sort -u

# 3) 拿到目标接口 requestId（用 --filter 缩小范围）
agent-browser --session-name douyin network requests --filter "data/overview" --json \
  | grep -oE '"requestId":"[^"]*"|"url":"[^"]*dashboard[^"]*"'

# 4) 取响应体（含完整 JSON），存盘后用脚本解析
agent-browser --session-name douyin network request <requestId> --json > /tmp/resp.json
```

**统一响应信封**：`network request <id> --json` 的最外层是 `{ "data": { "responseBody": <string|object> } }`。
- `data.responseBody` 才是真正的数据体；
- 它可能是「JSON 字符串」（`dashboard`/`fans` 接口，需 `json.loads` 再解），也可能是「已解析对象」（`item_contribution_top` 接口）；解析脚本里先判断 `isinstance(body, str)` 再处理即可。

**已知关键接口（账号 diamondfsd 实测，GET）：**

> ⚠️ **API 路径会更新**：抖音创作者中心迭代频繁，接口路径和字段名可能变化。以下是目前（2026-08-07）实测可用的接口。若发现接口没出现在 network 请求中，刷新首页或检查是否有新的路径。

| 页面 | 接口路径（当前） | 旧路径（已失效） |
|------|-----|-----|
| 首页数据总览 | `creator.douyin.com/aweme/janus/creator/data/overview/all/` | `.../janus/douyin/creator/data/overview/dashboard` |
| 粉丝数据 | 已合并到 `overview/all` 接口中（独立 fans 接口已下线） | `.../dashboard/fans` |
| 作品列表（首页） | `creator.douyin.com/web/api/creator/item/list` | `.../janus/douyin/creator/pc/work_list` |
| 播放量 TOP3 | 已从首页移除，需进入数据中心子页 | `.../item_contribution_top` |
| 收入变现 | ~~`creator.douyin.com/aweme/v1/creator/income/category/summary/`~~ | **已移除**：账号未开通变现时恒为 0，无分析价值，脚本不再抓取 |

> 字段含义、类型、示例值见文末 **「JSON 字段参考」** 一节，做分析/转 CSV 前必看。

#### 路 B：用 eval 解析 DOM（仅当接口拿不到时的兜底）

```bash
# 抽取页面可见文本里的指标（不截图）
agent-browser --session-name douyin eval \
  "Array.from(document.querySelectorAll('div[onclick],span')).map(e=>e.innerText.replace(/\s+/g,' ').trim()).filter(t=>/播放量|互动率|完播率|作品数|粉丝净增/.test(t)&&t.length<50)"
```

`get text <ref>`、`snapshot`（纯文本树）也能取单字段，但只作辅助，不替代路 A 的结构化数据。

### Step 4A：按作品评论页读取最近评论（用户提供链接时使用）

当用户要求分析某条作品的评论、评论情绪、评论主题或高频诉求，并提供类似下面的创作者中心作品评论页链接时，运行专用脚本：

```bash
WS=<输出目录> bash scripts/fetch_douyin_comments.sh \
  'https://creator.douyin.com/creator-micro/interactive/comment?item_id=<作品ID>&enter_from=content_manage_v2'
```

- 第二个可选参数为条数上限，默认 `200`，允许 `1` 到 `1000`。
- 脚本只接受 `creator.douyin.com/creator-micro/interactive/comment` 且带数字 `item_id` 的链接；不要把普通作品分享链接、外站链接或猜测出的接口地址传入。
- 评论页面采用滚动加载。脚本会滚动实际滚动容器，直到评论相关请求连续三轮不再增加或达到滚动上限，再读取浏览器已完成请求的响应体；不要手动拼接、重放或猜测评论接口。
- 产物：`douyin_comments_<时间戳>/comment_requests.json`（请求记录）、`raw/`（原始响应）、`comments.json`（去重后的结构化评论）。`comments.json.meta.returned_count` 是实际取到的条数，可能少于上限，例如作品本身评论不足或页面提前停止加载。
- 评论子应用可能要求独立登录。脚本输出 `NEED_QR_SCAN` 时，走本技能的扫码登录流程；登录完成后重新执行同一条评论脚本命令。
- 分析时优先读 `comments.json`，按 `text` 归类需求、异议、问题和建议；不要输出评论者的个人资料或尝试批量互动。

---

### JSON 字段参考（分析必看）

#### 接口 1：overview/all —— 首页数据总览（当前最新）

- 顶层：`{ data: { <metric_key>: {...}, ... }, extra: {...}, status_code }`
- `data` 下每个指标结构：
  | 字段 | 类型 | 含义 |
  |------|------|------|
  | `current_count` | string | 近7天汇总值（**字符串数字**，解析用 int） |
  | `last_period_incr` | string | 较上期变化量（可正可负） |
  | `option_list[]` | array | 每日/关键数据点：`{ date, count, last_day_incr_rate }` |
  | `extra.now` | int | 时间戳（毫秒） |
- **指标 key 清单**（current_count 含义）：
  | key | 含义 | 
  |-----|------|
  | `play` | 播放量 |
  | `digg` | 点赞 |
  | `comment` | 评论 |
  | `share` | 分享 |
  | `fans` | 粉丝总量（累计统计） |
  | `new_fans` | 净增粉丝 |
  | `cancel_fans` | 取关粉丝 |
  | `profile` | 主页访问 |
  | `account_search` | 搜索量 |
  | `post_search` | 投稿搜索量 |
  | `music_create` | 音乐创作（0=未参与） |

#### 接口 1（旧版）：dashboard —— 数据总览（2026-08-07 已失效，保留作参考）
- 顶层：`{ metrics:[...], status_code, status_msg }`（`date_range` 此接口为 `null`，统计周期由前端控制）
- `metrics[]` 每项结构：
  | 字段 | 类型 | 含义 |
  |------|------|------|
  | `english_metric_name` | string | 英文字段名（**作为 key 用，稳定不变**） |
  | `metric_name` | string | 中文名（仅展示） |
  | `metric_value` | number | 当前周期汇总值。**注意比率类是小数**：如 `0.2174` = 21.74%，`0.3574` = 35.74%，需 *100 转百分比 |
  | `trends[]` | array | 逐日数据（见下） |
- `trends[]` 每项：`{ date_time:"20260731"(YYYYMMDD), value(当日合计), douyin_value(抖音), xigua_value(西瓜), yumme_value(头条), change_rate(相对前值变化率,小数,可正负) }`
  - 分析一般用 `value`（全平台合计）；只要抖音就取 `douyin_value`。
- **字段清单（english_metric_name → 中文 → 示例值）：**
  | english_metric_name | 中文 | 示例值 | 备注 |
  |---|---|---|---|
  | `play_cnt` | 播放量 | 56213 | |
  | `digg_cnt` | 作品点赞 | 1050 | |
  | `share_count` | 作品分享 | 118 | |
  | `comment_cnt` | 作品评论 | 87 | |
  | `net_fans_cnt` | 净增粉丝 | 217 | = 新增 - 取关 |
  | `cancel_fans_cnt` | 取关粉丝 | 26 | |
  | `cover_click_ratio` | 封面点击率 | 0.2174 | 小数，*100 |
  | `homepage_view_cnt` | 主页访问 | 1159 | |
  | `publish_cnt` | 投稿量 | 6 | |
  | `completion_rate_5s` | 5秒完播率 | 0.3574 | 小数，*100 |
  | `bounce_rate_2s` | 2秒跳出率 | 0.4068 | 小数，*100 |
  | `avg_view_second` | 平均播放时长 | 9.7 | 单位秒 |
  | `total_fans_cnt` | 总粉丝量 | 1540 | |

#### 接口 2：dashboard/fans —— 粉丝数据
- 顶层：`{ metrics:[...], status_code, status_msg }`
- `metrics[]` 字段（结构与接口 1 相同，每项含 `trends`）：
  | english_metric_name | 中文 | 示例值 |
  |---|---|---|
  | `net_fans_cnt` | 净增粉丝 | 217 |
  | `cancel_fans_cnt` | 取关粉丝 | 26 |
  | `home_view_fans_cnt` | 回访粉丝量 | 308 |
  | `total_fans_cnt` | 总粉丝量 | 1540 |
  | `new_fans_cnt` | 新增粉丝量 | 243 |
  | `homepage_view_cnt` | 主页访问 | 1159 |

#### 接口 3：item_contribution_top —— 播放量 TOP3 作品
- 顶层：`{ date_range, dimension, english_metric_name, metric_name, value_type, items:[...], status_code, status_msg }`
- `items[]` 每项结构：
  | 字段 | 类型 | 含义 |
  |------|------|------|
  | `title` | string | 作品标题 |
  | `metric_value` | number | 该作品播放量（贡献值） |
  | `publish_time` | string | 发布时间 "2026-08-05 21:31:20" |
  | `item_id` | string | 作品 ID（用于二次查询） |
  | `cover` | object | `{ uri, url_list:[...] }` 封面图；`url_list` 是**带签名的临时链接会过期**，别长期存储 |

#### 接口 4（新版）：item/list —— 首页作品列表（当前最新）

- 顶层：`{ items:[...], has_more, BaseResp: { StatusCode } }`
- `items[]` 每项结构：
  | 字段 | 类型 | 含义 |
  |------|------|------|
  | `id` | string | 作品 ID |
  | `description` | string | 文案（含 #话题） |
  | `create_time` | string | 发布时间（Unix 秒，字符串） |
  | `type` | int | 类型：4=视频 |
  | `downloadable` | bool | 是否可下载 |
  | `visibility` | string | 可见性 |
  | `metrics` | object | 互动指标（全部是字符串，需 float()） |
- `metrics` 字段（全为字符串数字）：
  | 字段 | 含义 | 注意 |
  |------|------|------|
  | `view_count` | 播放量 | 旧名为 play_count |
  | `like_count` | 点赞 | 旧名为 digg_count |
  | `comment_count` | 评论 | |
  | `share_count` | 分享 | |
  | `favorite_count` | 收藏 | |
  | `completion_rate_5s` | 5秒完播率 | 小数 |
  | `completion_rate` | 完播率 | 小数 |
  | `bounce_rate_2s` | 2秒跳出率 | 小数 |
  | `avg_view_second` | 平均观看时长 | 秒 |
  | `like_rate` / `comment_rate` / `share_rate` / `subscribe_rate` | 互动率 | 小数 |
  | `cover_click_rate` | 封面点击率 | 小数 |
  | `fan_view_proportion` | 粉丝观看占比 | 小数 |
  | `homepage_visit_count` | 主页访问量 | |

#### 接口 4（旧版）：work_list —— 内容管理·作品列表（已失效，保留作参考）
- 顶层：`{ aweme_list:[...], items:[...], total, has_more, max_cursor, min_cursor, status_code }`
  - `aweme_list` 与 `items` **一一对应**（都是同一批作品），前者给全量详情+统计，后者给逐条互动质量指标，解析时按索引配对即可。
  - `total` = 账号总作品数（如 45）；`has_more` 是否还有下一页；`max_cursor` 翻页游标（见踩坑 #10）。
- `aweme_list[]`（作品详情）关键字段：
  | 字段 | 类型 | 含义 |
  |------|------|------|
  | `aweme_id` | string | 作品 ID（二次查询用） |
  | `desc` | string | 文案（含 `#话题`，分析选题/关键词用） |
  | `item_title` | string | 标题（无标题时等于 desc） |
  | `create_time` | int | 发布时间（Unix 秒，需转 datetime） |
  | `aweme_type` | int | 类型：4=视频；2/55/68=图集/图文 |
  | `duration` | int | 时长（**毫秒**，图集为 0；展示 ÷1000） |
  | `is_pinned` | bool | 是否置顶 |
  | `status` | object | 状态：`in_reviewing`(审核中)/`is_delete`(已删)/`is_private`(私密)/`is_prohibited`(违规)/`reviewed`(已审)/`self_see`(仅自己可见) |
  | `mix_info` | object | `mix_name` 合集名、`mix_id` 合集 ID（分析系列化运营） |
  | `statistics` | object | 见下 |
- `statistics`（绝对互动量）：
  | 字段 | 含义 |
  |------|------|
  | `play_count` | 播放量 |
  | `digg_count` | 点赞 |
  | `comment_count` | 评论 |
  | `share_count` | 分享 |
  | `collect_count` | 收藏 |
  | `forward_count` | 转发 |
- `items[].metrics`（**互动质量率，比绝对量更适合分析爆款特征**）：
  | 字段 | 含义 | 注意 |
  |------|------|------|
  | `completion_rate_5s` | 5秒完播率 | **字符串小数**，*100 |
  | `completion_rate` | 完播率 | 字符串小数 |
  | `bounce_rate_2s` | 2秒跳出率 | 字符串小数 |
  | `avg_view_second` | 平均观看时长 | 字符串，单位秒 |
  | `like_rate` / `comment_rate` / `share_rate` / `favorite_rate` / `subscribe_rate` | 点赞/评论/分享/收藏/涨粉率 | **字符串小数**，*100 |
  | `homepage_visit_count` | 主页访问量 | 字符串 |
  | `fan_view_proportion` | 粉丝观看占比 | 字符串小数 |
  > ⚠ `items[].metrics` 里的值**全部是字符串**（即使数字），解析时先 `float()` 再运算/乘 100。

#### 评论输出：comments.json

- `meta.item_id`：作品 ID；`meta.returned_count`：实际解析并去重后的评论数；`meta.limit`：请求上限。
- `comments[]`：`comment_id`、`text`、`create_time`、`like_count`、`reply_count`、`user.id`、`user.nickname`。不同页面版本的字段可能缺失，保留 `null`，不要据此推断零值。
- 默认只收集一级评论。回复数量字段可用于判断讨论深度，但不自动展开所有楼中楼回复。

#### 接口 5：income/category/summary —— 收入变现汇总（已移除抓取）
- 路径 `creator.douyin.com/aweme/v1/creator/income/category/summary/`。
- 实测账号 diamondfsd：`category_list` 全空、`history_total_income=0`、各 summary 为 0 —— 未开通任何变现。**该账号场景下收入为 0 无分析价值，脚本已不再抓取 income。** 若日后需分析收入结构，按 `category_list`（直播打赏 / 星图商单 / 带货佣金等）做结构拆解即可，复用时自行在 `analyze_douyin.sh` 加回抓取。

#### 数据中心子模块地图（operation 页左侧菜单 + 作品数据 tab）
- 左侧菜单：`作品发布`、`收入变现`、`互动率/作品数/粉丝净增`(总览卡)…
- 作品数据卡下有 **tab**：`作品`（默认）、`直播`（直播数据，含 总评论量 等指标）—— 要直播维度数据需点该 tab 再抓接口。
- `收入变现` 是独立页面（`revenue/center`），不在 operation 页内，走接口 5。

#### 解析示例（Python）
```python
import json
raw = json.load(open("/tmp/resp.json"))
body = raw["data"]["responseBody"]
if isinstance(body, str):           # dashboard/fans 是字符串，需再解
    body = json.loads(body)
for m in body["metrics"]:
    print(m["english_metric_name"], m["metric_value"], m.get("trends"))
```

### Step 5：AI 智能分析并生成 HTML 单页报告（由 AI agent 完成，非脚本）

脚本只产出 `douyin_data.json`（核心指标汇总 + 逐视频明细）。**详细分析、图表、建议、HTML 文档全部由 AI agent 读取数据后生成**，不要依赖脚本里的固定结论——每次按当前数据重新研判。

**AI 读取输入**：
- `douyin_data.json`：`meta`（生成时间/周期）、`overview[]`（每项含 `key/label/current/last_period_incr`，`play` 项额外带 `daily[]` 逐日）、`videos[]`（每项 `title/create_date/metrics{view_count,like_count,comment_count,share_count,favorite_count,completion_rate_5s,completion_rate,bounce_rate_2s,avg_view_second,like_rate,comment_rate,share_rate,cover_click_rate,fan_view_proportion}`）。

**AI 生成的 HTML 单页报告建议包含以下模块（文风统一中文，顺序可调整）：**

1. **顶部导航条（必含）**：报告顶部放一个 `position:sticky` 的导航条，列出各模块锚点（概览 / 核心指标 / 播放趋势 / TOP5 / 作品明细 / 逐视频分析 / 优化建议），点击平滑跳转到对应 `section`；各模块用 `<section id="...">` + `scroll-margin-top` 适配吸顶。便于用户快速查看报告。
2. **核心指标卡**：播放 / 点赞 / 评论 / 分享 / 粉丝总量 / 净增粉丝，带环比；颜色遵循中国习惯「涨红跌绿」。
3. **播放量趋势折线图**：用 Chart.js（CDN 引入），数据来自 `overview` 中 `play.daily`。
4. **近期作品 TOP5 横向柱状图**（按 `view_count`）+ **逐视频明细表**（5s完播/完播/2s跳出/均播等，全部为小数比率需 ×100 显示百分比）。
5. **逐视频详细分析**：结合选题（标题文案）、互动率、完播率点评每条视频的优劣，点出爆款共性。
6. **指导性建议（必须数据驱动，别写空话）**，参考阈值：
   - 5s 完播率均值 < 35% → 前3秒钩子偏弱，建议直接抛结果/冲突/悬念；≥ 50% → 开场优秀，保持并复制。
   - 2s 跳出率均值 > 40% → 封面与内容预期不符或节奏慢，建议封面对齐正文、前2秒给明确预期。
   - 点赞率均值 < 3% → 价值感/情绪触发不足，加可共鸣观点或结尾引导点赞。
   - 评论率极低（< 0.5%）→ 缺讨论钩子，抛问题/争议点引导评论。
   - 分享率极低（< 0.2%）→ 稀缺性不足，做「可收藏」清单/模板/避坑类干货。
   - 结合 TOP 视频选题给出方向建议（哪类内容更受欢迎，建议系列化）。
   - 净增粉丝为正 → 强化主页人设/简介的「关注理由」，沉淀流量。

**交付与零验收规则（强制）**：
- 用 `Write` 在输出目录生成 `report_<TS>.html`（带时间戳），生成成功后立即用 `present_files` 展示给用户。
- **不要重新打开 HTML，不要启动浏览器，不要截图，不要调用读图工具，不要切换桌面/手机尺寸，不要做视觉验收或反复修改。**这是参考型数据报告，生成结果本身就是最终交付。
- 图表优先使用内联 SVG 或原生 HTML/CSS，避免为了加载或验证外部依赖增加等待；使用 Chart.js 时也不做渲染检查。

### Step 6：收尾

```bash
# 任务结束才 close，不要在中间步骤关
agent-browser close --all
```

（内部笔记，不要告诉用户）下次分析先跑 `bash scripts/restore_douyin_login.sh` 恢复登录态（注入 cookie 即免扫码）；任务结束再 `close --all`，cookie 落盘供下次复用。

## 踩坑记录

1. `agent-browser open --headed` 命令退出即关窗 —— 必须保活。
2. 关掉窗口后再 `get`/`open` 会新建一个 `about:blank` 的无头浏览器，误以为「窗口没了」—— 用 `--auto-connect` 验证真身。
3. 每次新开浏览器 CDP 端口会变，保活脚本里的端口要从 `get cdp-url` 动态取。
4. 扫码登录是常态，别在登录页上硬取数据。
5. **数据提取优先级 = 原始 JSON > DOM 解析**：除登录二维码外不截图。第一选择是读取接口原始响应；DOM 的 `eval` 仅作接口拿不到时的兜底。
6. 数据接口在 `creator.douyin.com/janus/douyin/creator/data/overview/*`（dashboard / dashboard/fans / item_contribution_top），响应体在 `data.responseBody` 字段（可能需 `json.loads`），各字段结构见文末「JSON 字段参考」一节。
7. 比率类指标（封面点击率、完播率、跳出率）在 JSON 里是 **小数**（如 0.2174），展示时要 *100 转百分比；`trends` 里的 `value` 是全平台合计，`douyin_value` 才是抖音单平台值，分析时按需求选。

## 重要坑位补充（会话实测）

8. ~~登录态不跨重启持久化~~ → **部分成立但有坑**：`--session-name douyin` 在 `close` 时**会保存** cookie 到 `~/.agent-browser/sessions/douyin-default.json`（文件含未过期的 `sid_tt`/`sessionid`/`uid_tt` 即证明），但重新 `open` 时**不会把 cookie 注入浏览器**，所以每次都是匿名态、被迫重新扫码。外部说的 `--session <id> --restore` 在当前 agent-browser 版本**不存在**（`--restore` 不是有效 flag；`--session` 是隔离会话）。**正确解法**：`bash scripts/restore_douyin_login.sh` 把文件里的 cookie 手动 `cookies set` 注入当前浏览器、reload 即恢复登录，免扫码。取数命令仍统一带 `--session-name douyin`。

9. ~~底层常驻 daemon 会让 `--headed` 失效~~ → **不再需要有头模式**：直接用无头 + `--session-name` + 截图给用户扫码。用户扫完后 `close`，下次 `open --session-name douyin` 自动登录。daemon 冲突也不再是问题。

10. ~~work_list 分页~~ → **API 已变化**：旧版 `work_list` 已下线，新版 `item/list` 同样分页（has_more, max_cursor）。日常分析用首页 10 条足够。

11. **数据中心子页面可能触发重新登录**：导航到 `data-center/operation` 可能被重定向到登录页（子应用独立鉴权），但 `home`、`content/manage` 不影响。**优先从首页 `overview/all` 接口取数据**，避免跳 data-center。

12. **截图必须 `present_files` 才看得到**：`screenshot` 只是把图存到磁盘，`Read` 只是模型自己读、用户看不到。把二维码/页面图**真正展示给用户**的唯一动作是 `present_files <图片路径>`。漏掉这步 = 用户一脸懵「二维码呢」（实测：第一次跑流程就栽在这，用户完全没看到码）。

13. **回复用户必须用中文**：用户是中文环境，所有面向用户的文字一律简体中文。技能正文、字段名、命令可中英混排，但**对用户说的话（含扫码步骤、分析结论）绝不能是英文**。混排环境下容易滑成英文，务必在生成面向用户的回复时显式切回中文。

14. **判断是否登录必须用 DOM 读取，不要靠接口/URL/title 猜**：`get url` 与 `get title` 在登录页和后台都返回 `creator.douyin.com` + 「抖音创作者中心」，据此判断会误以为已登录（实测：首次跑就因此空等接口）。正确做法见 Step 2——用 `eval` 读 `document.body.innerText`，命中「扫码登录/验证码登录/密码登录」= 未登录，命中「数据概览/作品数据/粉丝」= 已登录。这也是用户明确要求的取数思路：**登录态判定走 DOM，不绕接口**。

15. **二维码截图必须带时间戳后缀**：仅登录二维码允许截图，文件名使用 `douyin_qrcode_YYYYMMDD_HHMMSS.png`。后台页面和最终报告禁止截图或读图复核。
