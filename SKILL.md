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

全程走创作者中心官方页面，只读取用户本人已授权可见的数据。**登录态复用靠 `--profile` 持久化浏览器目录（`~/.agent-browser/profiles/douyin`），cookie/localStorage 自动保存在磁盘上，跟正常浏览器一样。一次扫码后只要 cookie 没过期就不用再扫。**

核心教训来自实战：

- **登录态持久化用 `--profile`，别用 `--session-name`**：`--session-name <name>` 是"临时上下文 + 手动存取 cookie"方案，有两个致命 bug：① `close` 时 Chromium 上下文已销毁，cookie 导出到 session 文件变成空壳（实测：13KB → 36 字节 `{"cookies":[],"origins":[]}`）；② `open` 时不会把 session 文件里的 cookie 注入回浏览器。等于存了白存。**正确做法**：用 `--profile <path>` 指定持久化浏览器目录（`~/.agent-browser/profiles/douyin`），cookie/localStorage 自动实时写入磁盘，跟正常 Chrome 一样。所有脚本通过环境变量 `AGENT_BROWSER_PROFILE` 统一设置。
- **代理冲突必须绕过**：用户环境可能有 `HTTP_PROXY=http://127.0.0.1:7890/`，agent-browser 的 Chromium 不支持 HTTP 代理，直接 `ERR_NO_SUPPORTED_PROXIES` 打不开页面。所有脚本开头必须 `export HTTP_PROXY="" HTTPS_PROXY="" http_proxy="" https_proxy="" ALL_PROXY=""`。抖音是国内站点，绕过代理不影响访问。
- **无头 + 截图给用户扫码**：不需要开有头窗口。无头模式打开 → 截图 → **用 `present_files` 把二维码图真正展示给用户**（仅 `Read` 自己看没用，用户看不到）。用户扫完告诉我，我拿到数据后关掉即可，下次 `--profile` 自动恢复登录态。
- **扫码后可能要求「用户验证」（短信验证码），非必现但必须兼容**：2026-08-14 实测——用户扫码并在手机确认后，页面仍可能弹出短信验证码输入（或安全验证/滑块）。无头模式用户无法操作，**检测到验证特征就切有头浏览器**：`bash scripts/headed_login_douyin.sh`，让用户直接看窗口完成验证（详见 Step 2A）。切有头不丢登录进度（`--profile` 持久化，扫码 token 在服务端）。
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
- **❗ 严禁向用户输出任何"过程性状态"（最高红线）**：你执行的每个动作——恢复登录、持久化 profile、免扫码、抓接口、`analyze_douyin.sh` 取数、汇总成 `douyin_data.json`、脚本执行结果、生成报告、关闭浏览器——统统是**内部实现细节，用户一个字都不该看到**。绝对禁止对用户说「正在恢复登录」「无需扫码 / 不用扫描」「已抓取到 N 条数据」「登录态已保存，下次免扫码」「正在生成报告」等任何过程描述。这些只写在技能内部供你参考。
  - ✅ 用户唯一可能看到的「过程提示」只有一种情况：必须他本人扫码登录时，输出**且仅输出**一句中文——「请用抖音 App 扫码登录，扫完告诉我」——然后调用 `present_files` 把二维码给他。
  - ✅ 除此之外，用户应该**只看到最终的分析报告**（HTML 预览 + 结论文字）。
  - 🚫 连「分析报告已生成」「数据已分析完成」这种废话都不要说——把报告用 `present_files` 展示出来本身就是结果，不必再用文字复述一遍。
- **面向用户的文字必须极简**：给用户看的消息只允许「必要的最小指引 + 最终分析结果」。**严禁**把以下内容说给用户听——session 持久化、登录态复用、下次不用重新扫码、`--session-name`、接口路径/字段名、踩坑记录、`agent-browser` 工具名、CDP/daemon 等任何内部机制。这些只写在技能内部供你参考，绝不是给用户看的。用户只需要知道两件事：① 扫哪个码（仅当必须时）；② 分析结果出来了。多余一句都不要加。
- **截图必须真正"呈现"给用户**：本环境里把图片/文件展示给用户**唯一的途径是 `present_files` 工具**。截图后只 `Read` 自己看、或用文字描述"见上图"都**无效**——用户根本看不到。`screenshot` 落盘后，**紧接着必须调用 `present_files` 把该图片路径传出去**（踩坑 #12）。

## Prerequisites

- **不要预先检测工具是否可用**：直接执行 `agent-browser` 命令即可。若报 `command not found` 或类似「找不到命令」的错，再执行 `npm install -g agent-browser` 安装。避免「先用 `which` 检测、再执行」这类浪费步骤（见上方「先执行、报错再处理」原则）。
- 会话参数：统一用 `--session-name douyin`（所有命令都带，连接同一浏览器 daemon）+ 环境变量 `AGENT_BROWSER_PROFILE="$HOME/.agent-browser/profiles/douyin"`（持久化浏览器目录，cookie/localStorage 自动保存在磁盘上，跟正常浏览器一样）。⚠️ **不要用 `--session-name` 的 cookie 存取机制**——它 `close` 时存不住、`open` 时读不回（详见踩坑 #16）。`--profile` 才是持久化正解。
- 代理豁免：所有脚本开头必须 `export HTTP_PROXY="" HTTPS_PROXY="" http_proxy="" https_proxy="" ALL_PROXY=""`，否则 agent-browser 的 Chromium 报 `ERR_NO_SUPPORTED_PROXIES` 打不开页面（详见踩坑 #17）。

## Workflow

### Step 0：尝试无扫码恢复登录（每次分析必跑，优先于扫码）

**核心方案**：使用 `--profile` 持久化浏览器目录（`~/.agent-browser/profiles/douyin`），cookie/localStorage 自动实时保存在磁盘上，跟正常 Chrome 一样。脚本 `restore_douyin_login.sh` 会用这个 profile 打开首页并检查 DOM 判断登录态：

```bash
bash scripts/restore_douyin_login.sh
```

脚本行为（幂等、可重复）：
- 已登录 → 输出 `ALREADY_LOGGED_IN` 并退出 0，直接进入 Step 3 取数；
- 未登录但处于「用户验证」步骤（短信验证码/安全验证）→ 输出 `NEED_USER_VERIFY`（退出码 3），走 Step 2A 切有头浏览器让用户完成验证；
- 未登录（cookie 过期或首次使用）→ 输出 `NEED_QR_SCAN`（退出码 2），走 Step 1 截图扫码。

> **为什么用 `--profile` 而不是 `--session-name`**：`--session-name` 的 cookie 存取有两个致命 bug——`close` 时 Chromium 上下文已销毁，cookie 导出到 JSON 文件变成空壳；`open` 时又不会把 JSON 里的 cookie 注入回浏览器。`--profile` 直接用 Chrome 的持久化用户目录，cookie 实时写入磁盘 SQLite，开关浏览器都不会丢（详见踩坑 #16）。

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

**这是兜底路径，仅在 `restore_douyin_login.sh` 返回 `NEED_QR_SCAN` 时才用（首次使用或 cookie 已失效）。** 用 `--profile` 持久化目录 + `--session-name douyin` 打开无头浏览器，截图给用户扫码。

```bash
# 设置环境变量（所有命令都需要）
export HTTP_PROXY="" HTTPS_PROXY="" http_proxy="" https_proxy="" ALL_PROXY=""
export AGENT_BROWSER_PROFILE="$HOME/.agent-browser/profiles/douyin"

# 打开（无头，用 profile 持久化）
agent-browser --session-name douyin open "https://creator.douyin.com/creator-micro/home"

# 短暂等待二维码渲染，不等待 networkidle
agent-browser --session-name douyin wait 1000

# 截图给用户扫码（放到工作目录）
TS=$(date +%Y%m%d_%H%M%S)
agent-browser --session-name douyin screenshot <workspace>/douyin_qrcode_${TS}.png
```

截图保存后，**必须立即调用 `present_files` 把该 PNG 展示给用户**（这是用户能看到二维码的唯一方式；只 `Read` 自己看或文字描述都无效）。展示后用中文提醒一句即可：「请用抖音 App 扫码登录，扫完告诉我」——**仅此一句，不要加任何补充说明**。

> **注意**：扫码后登录流程可能包含「用户验证」步骤（短信验证码等，非必现）。扫完码后进入 Step 2 检测页面状态，若命中验证特征（`需在手机上进行确认` / `验证码` / `安全验证`），按 Step 2A 切有头浏览器让用户完成，不要反复刷新重扫码。

### Step 2：判断是否已登录（DOM 读取法，不用接口判定）

**关键教训（实测踩坑）**：`get url` / `get title` **不可靠**——登录页和后台都显示 `creator.douyin.com` 与标题「抖音创作者中心」，单看这两个字段会被骗（首次实战就因此误以为已登录、接口却空）。**判断是否登录唯一稳妥的办法是读页面 DOM 文本/结构**，看页面到底是登录页还是后台面板。**不要依赖接口或 URL 推断登录态。**

用户说「扫完了」后，用 `eval` 读 `document.body.innerText`，命中登录页特征字（「扫码登录 / 验证码登录 / 密码登录」）即为未登录，命中后台特征字（「数据概览 / 数据看板 / 作品数据 / 粉丝」等）即为已登录。**同时检测「用户验证」特征**（`需在手机上进行确认` / `请输入验证码` / `验证码已发送` / `安全验证`）——扫码后可能走到这一步：

```bash
# 读取 DOM：判断是登录页 / 验证步骤 / 后台（核心判断逻辑）
agent-browser --session-name douyin eval "(() => {
  const t = document.body.innerText;
  const isLoginPage = /扫码登录|验证码登录|密码登录|账号密码登录|打开「?抖音APP」?点击左上角/.test(t);
  const needConfirm = /需在手机上进行确认/.test(t);
  const needVerify = /请输入验证码|验证码已发送|短信验证码|安全验证|滑动验证|图形验证/.test(t);
  const hasDashboard = /数据概览|数据看板|数据中心|作品数据|粉丝分析|近7日|播放量|互动数据/.test(t);
  return JSON.stringify({
    isLoginPage,
    needConfirm,
    needVerify,
    hasDashboard,
    title: document.title,
    url: location.href,
    bodyLen: t.length
  });
})()"
```

判断规则（按优先级）：
- `needConfirm === true` → 用户已扫码、等手机确认 → 提醒用户「请在手机上点确认登录」；确认后重新读 DOM。
- `needVerify === true` → 需要短信验证码等用户验证 → **切有头浏览器**，走 Step 2A。
- `isLoginPage === true` → 仍在登录页（二维码过期 / 没扫到）。重新 Step 1 截图给用户，并提醒重新扫。
- `hasDashboard === true` → 已进入后台，继续 Step 3 取数。
- 两者都为 false（如 loading 中）→ 再 `wait` 几秒或 `reload` 一次重试；仍不行再用 `snapshot -i` 看具体 DOM。

（可选）确认登录页二维码 canvas 是否渲染正常：
```bash
agent-browser --session-name douyin eval "!!document.querySelector('canvas, [class*=qrcode], [class*=login]')"
```

### Step 2A：用户验证兼容（短信验证码，非必现但必须处理）

**背景（2026-08-14 实测）**：扫码登录后，登录流程可能包含「用户验证」步骤——页面弹出短信验证码输入（或安全验证/滑块）。**这不是每次登录都出现**，但一旦出现，无头模式用户无法操作，必须切到有头浏览器让用户直接看窗口完成。**不要反复刷新重扫码**——验证步骤是扫码成功后的正常流程，刷新反而打断。

**检测特征词**（DOM 文本，见 Step 2 的 eval）：
- `需在手机上进行确认` —— 已扫码、等手机点「确认登录」
- `请输入验证码` / `验证码已发送` / `短信验证码` —— 短信验证码步骤
- `安全验证` / `滑动验证` / `图形验证` —— 其他风控验证

**处理流程**：
1. 检测到验证特征（`needConfirm` / `needVerify`）→ 调用切有头脚本（同一 `--profile`，登录进度不丢）：
```bash
bash scripts/headed_login_douyin.sh   # 输出 HEADED_BROWSER_READY = 窗口已就绪
```
2. 有头浏览器窗口弹出（用户屏幕上可见）→ 让用户直接看窗口操作：点「确认登录」、收短信、输入验证码。
3. 用户完成验证后，重新读 DOM（Step 2 的 eval）：`hasDashboard === true` 就继续 Step 3 取数；仍在验证步骤就再等几秒重读，**不要刷新页面**。

**给用户的话**（少数允许的引导，保持极简）：「请在刚弹出的浏览器窗口中完成验证码验证，完成后告诉我。」

**关键机制**（写死在 `headed_login_douyin.sh` 里）：
- `AGENT_BROWSER_HEADED=1` 必须在 daemon 启动前设置；切有头 = 先 `close --all` 杀旧 daemon → 再带环境变量重新 `open`（见踩坑 #20）。
- 若当前已是可见有头模式，脚本直接复用、不杀 daemon，避免打断正在验证的用户。
- 脚本自动用 `pgrep -f "Chrome for Testing"` 确认窗口真的可见（无 `--headless` 参数）。

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

> **取数方式铁律（2026-08-14 重构，用户明确要求）**：取数一律用**抓包页面自身请求**（network 命令），**禁止 eval 注入脚本、禁止 fetch 重放接口**。原因见踩坑 #23——抖音风控会拦截裸 fetch（`status_code:8 用户未登录`），只有 reload 让页面自己带着风控参数（`msToken`/`a_bogus`）发的同源请求才能取到数据；同时用户要求所有浏览器操作走 agent-browser 原生方法（snapshot/click/network），不用 eval 注入。操作顺序固定为：`network requests --clear` → `reload`（或 open 目标页）→ `network requests --filter` 找 requestId → `network request <rid> --json` 取响应体（`analyze_douyin.sh` 已实现，勿改回 eval+fetch）。

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

**已知关键接口（实测，GET）：**

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
  | `fans` | 粉丝总量（累计统计） | ⚠️ **`current_count` 是累计口径（实测 11587，不可用）**；真实粉丝数从 `option_list[]` 取末日 `count`（详见踩坑 #24） |
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
- 实测账号：`category_list` 全空、`history_total_income=0`、各 summary 为 0 —— 未开通任何变现。**该账号场景下收入为 0 无分析价值，脚本已不再抓取 income。** 若日后需分析收入结构，按 `category_list`（直播打赏 / 星图商单 / 带货佣金等）做结构拆解即可，复用时自行在 `analyze_douyin.sh` 加回抓取。

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
# --profile 持久化目录下，close 不会丢失 cookie（跟正常浏览器一样）
export HTTP_PROXY="" HTTPS_PROXY="" http_proxy="" https_proxy="" ALL_PROXY=""
export AGENT_BROWSER_PROFILE="$HOME/.agent-browser/profiles/douyin"
agent-browser --session-name douyin close --all
```

（内部笔记，不要告诉用户）`--profile` 目录下 cookie 已实时写入磁盘，`close` 不会丢失登录态。下次分析直接跑 `bash scripts/analyze_douyin.sh`，脚本用同一个 profile 打开浏览器，通常直接就是登录态、无需扫码。

## 踩坑记录

1. `agent-browser open --headed` 命令退出即关窗 —— 必须保活。
2. 关掉窗口后再 `get`/`open` 会新建一个 `about:blank` 的无头浏览器，误以为「窗口没了」—— 用 `--auto-connect` 验证真身。
3. 每次新开浏览器 CDP 端口会变，保活脚本里的端口要从 `get cdp-url` 动态取。
4. 扫码登录是常态，别在登录页上硬取数据。
5. **数据提取优先级 = 原始 JSON > DOM 解析**：除登录二维码外不截图。第一选择是读取接口原始响应；DOM 的 `eval` 仅作接口拿不到时的兜底。
6. 数据接口在 `creator.douyin.com/janus/douyin/creator/data/overview/*`（dashboard / dashboard/fans / item_contribution_top），响应体在 `data.responseBody` 字段（可能需 `json.loads`），各字段结构见文末「JSON 字段参考」一节。
7. 比率类指标（封面点击率、完播率、跳出率）在 JSON 里是 **小数**（如 0.2174），展示时要 *100 转百分比；`trends` 里的 `value` 是全平台合计，`douyin_value` 才是抖音单平台值，分析时按需求选。

## 重要坑位补充（会话实测）

8. ~~登录态不跨重启持久化~~ → **已彻底解决**：`--session-name` 的 cookie 存取有两个致命 bug（详见踩坑 #16），现已弃用。改用 `--profile` 持久化浏览器目录（`AGENT_BROWSER_PROFILE="$HOME/.agent-browser/profiles/douyin"`），cookie/localStorage 自动实时写入磁盘，开关浏览器都不丢。脚本 `restore_douyin_login.sh` 已改用此方案。

9. ~~底层常驻 daemon 会让 `--headed` 失效~~ → **不再需要有头模式**：直接用无头 + `--profile` + 截图给用户扫码。用户扫完后 `close`，下次 `open` 用同一个 `--profile` 自动恢复登录态。daemon 冲突也不再是问题。

10. ~~work_list 分页~~ → **API 已变化**：旧版 `work_list` 已下线，新版 `item/list` 同样分页（has_more, max_cursor）。日常分析用首页 10 条足够。

11. **数据中心子页面可能触发重新登录**：导航到 `data-center/operation` 可能被重定向到登录页（子应用独立鉴权），但 `home`、`content/manage` 不影响。**优先从首页 `overview/all` 接口取数据**，避免跳 data-center。

12. **截图必须 `present_files` 才看得到**：`screenshot` 只是把图存到磁盘，`Read` 只是模型自己读、用户看不到。把二维码/页面图**真正展示给用户**的唯一动作是 `present_files <图片路径>`。漏掉这步 = 用户一脸懵「二维码呢」（实测：第一次跑流程就栽在这，用户完全没看到码）。

13. **回复用户必须用中文**：用户是中文环境，所有面向用户的文字一律简体中文。技能正文、字段名、命令可中英混排，但**对用户说的话（含扫码步骤、分析结论）绝不能是英文**。混排环境下容易滑成英文，务必在生成面向用户的回复时显式切回中文。

14. **判断是否登录必须用 DOM 读取，不要靠接口/URL/title 猜**：`get url` 与 `get title` 在登录页和后台都返回 `creator.douyin.com` + 「抖音创作者中心」，据此判断会误以为已登录（实测：首次跑就因此空等接口）。正确做法见 Step 2——用 `eval` 读 `document.body.innerText`，命中「扫码登录/验证码登录/密码登录」= 未登录，命中「数据概览/作品数据/粉丝」= 已登录。这也是用户明确要求的取数思路：**登录态判定走 DOM，不绕接口**。

15. **二维码截图必须带时间戳后缀**：仅登录二维码允许截图，文件名使用 `douyin_qrcode_YYYYMMDD_HHMMSS.png`。后台页面和最终报告禁止截图或读图复核。

16. **`--session-name` 的 cookie 存取有致命 bug，已弃用**：实测发现两个问题叠加导致反复扫码：① **close 时 cookie 存不住**——`--session-name douyin` 在 `close` 时会把 cookie 导出到 `~/.agent-browser/sessions/douyin-default.json`，但 close 瞬间 Chromium 上下文已销毁，导出的是空壳（实测：13KB session 文件 → close 后变成 36 字节 `{"cookies":[],"origins":[]}`）。② **open 时 cookie 读不回**——即使 session 文件里有完整的 `sid_tt`/`sessionid`，`open --session-name douyin` 也不会把 cookie 注入新浏览器，每次都是匿名态。**解决方案**：改用 `--profile` 持久化浏览器目录（`AGENT_BROWSER_PROFILE="$HOME/.agent-browser/profiles/douyin"`），cookie 实时写入磁盘 SQLite，跟正常 Chrome 一样。

17. **代理冲突导致浏览器打不开**：用户环境可能有 `HTTP_PROXY=http://127.0.0.1:7890/`（Clash 等代理工具），agent-browser 的 Chromium 不支持 HTTP 代理，直接 `ERR_NO_SUPPORTED_PROXIES` 报错、页面打不开。脚本会误以为登录态失效、反复要求扫码。**解决方案**：所有脚本开头必须 `export HTTP_PROXY="" HTTPS_PROXY="" http_proxy="" https_proxy="" ALL_PROXY=""`。抖音是国内站点，绕过代理不影响访问。AI agent 手动执行 agent-browser 命令时也要带上这些环境变量。

18. **`--profile` 是持久化正解，`--session-name` 不是**：`agent-browser --help` 显示 `--profile <name|path>` 参数——指定一个 Chrome profile 目录，就是真正的持久化浏览器配置（cookie、localStorage、缓存全部自动保存在磁盘上）。`--session-name` 只是"临时上下文 + 手动存取 cookie"的方案，存取机制有 bug（见 #16）。所有脚本已统一改用 `AGENT_BROWSER_PROFILE` 环境变量 + `--session-name douyin`（后者仅用于连接同一 daemon，不再依赖其 cookie 存取）。

19. **扫码后可能需要「用户验证」（短信验证码），无头模式必须切有头**（2026-08-14 实测）：用户扫码并在手机点「确认」后，页面仍可能停在验证步骤——弹出短信验证码输入。**这不是必然出现，但必须兼容**：反复刷新/重扫码会打断流程（曾因此把已验证的流程打断，用户二次扫码仍不同步）。**正确做法**：检测到验证特征（`需在手机上进行确认` / `请输入验证码` / `验证码已发送` / `安全验证`）→ 调 `scripts/headed_login_douyin.sh` 切有头浏览器 → 用户直接看窗口完成验证。`--profile` 持久化保证切有头不丢登录进度。

20. **`AGENT_BROWSER_HEADED=1` 必须在 daemon 启动前设置，临时加环境变量无效**（2026-08-14 实测）：daemon 已在无头模式启动后，后续命令即使带 `AGENT_BROWSER_HEADED=1`，Chrome 进程仍是 `--headless=new`，窗口根本不出现。**切有头 = 先 `agent-browser close --all` 杀掉 daemon → 再带 `AGENT_BROWSER_HEADED=1` 重新 `open`**。验证是否真有头：`pgrep -fl "Chrome for Testing"` 看进程参数里有没有 `--headless`（有 = 无头，无 = 有头）。`headed_login_douyin.sh` 已封装此逻辑。

21. **浏览器 daemon 会僵死（CDP response channel closed），扫码期间必须保活**（2026-08-14 实测）：长时间运行的 daemon 可能内核失联——表现：页面标签变 `about:blank`、二维码轮询停止、扫码确认不同步（用户在手机上确认了，页面没反应）。**诊断**：`agent-browser doctor`，若 Launch test 报 `CDP response channel closed` 即僵死。**处理**：`close --all` 后重新 `open`。**预防**：扫码等待期间，后台守护轮询只是「检测」不是「保活」——daemon 挂了它不会自己重启；等待登录成功期间若长时间无动静，先 `agent-browser doctor` 检查 daemon 是否还活着，再决定是否重开，不要盲目刷新页面。

22. **`agent-browser eval` 的返回值是 JSON 字符串（带转义），shell 子串匹配会永远失败**（2026-08-14 实测，restore 脚本误判的根因）：eval 返回形如 `✓ Done\n"{\"logged\":true,\"needVerify\":false}"`——整个对象被包成**带反斜杠转义的字符串**，因此脚本里 `[[ "$out" == *'"logged":true'* ]]` 这种无转义子串**永远匹配不上**，导致「页面明明已登录却判定 NEED_QR_SCAN」。**正确做法**：eval 直接返回明文（如 `document.body.innerText`），shell 用 `*"数据中心"*` 这类纯文本 contains 匹配；或用 `document.readyState + '|' + length` 拼接明文再解析。配套：判定登录态前必须等页面渲染完成（`readyState=complete` 且 body≥200 字符），无头模式新开 daemon 时 SPA 加载慢，不等就判定会把「加载中」误判成「未登录」。

23. **不要用 eval+fetch 重放接口取数，抖音风控拦截裸 fetch**（2026-08-14 实测，取数全失败的根因）：旧版 `analyze_douyin.sh` 用 eval 从页面找接口 URL 后自己 `fetch()` 重放——即使页面已登录，抖音接口对裸 fetch 返回 `status_code:8 用户未登录`，取数全部失败。**根因**：抖音接口要求浏览器页面自身发出的、带风控参数（`msToken`/`a_bogus`/`X-Bogus`）的同源签名请求；脚本重放既无签名也不带风控上下文。**正确做法（当前实现）**：抓包页面自身请求——`network requests --clear` → `reload` 触发页面自己发请求 → `network requests --filter "overview/all|item/list"` 找 requestId → `network request <rid> --json` 取响应体。全程零 eval 注入、零 fetch 重放，只用 agent-browser 原生 network 命令。响应体信封固定为 `{"data":{"responseBody":...}}`（body 可能是 JSON 字符串或已解析对象，解析时先判 `isinstance(body, str)`）。

24. **`overview/all` 的 `fans.current_count` 是累计口径（不可用），真实粉丝数从 `fans.option_list` 取末日值**（2026-08-14 实测）：`fans.current_count` 返回的是账号历史累计关注数（实测 11587），与页面显示的粉丝数完全对不上；`fans.option_list[]` 才是逐日粉丝数（`{date, count, ...}`），取数组末日 `count` 即当前真实粉丝（实测 1763/1794 与页面一致）。脚本已内置该修正逻辑。**通用教训**：接口字段先跟页面核对口径再用于分析，别盲信 `current_count`。

25. **登录态判断一律以 DOM/snapshot 为准；接口返回「用户未登录」可能是风控误判**（2026-08-14 实测）：fetch 重放时代接口报 `status_code:8`，而 DOM 显示已登录——此时**不要**据此判断会话失效。判定会话是否真失效的唯一标准：reload 后页面是否回到登录页（SPA 内存态假象：snapshot 显示账号/粉丝数都在，但接口全拒，reload 后变登录页才是真失效）。所有取数与登录态判断都走 DOM/network 抓包，不碰裸 fetch。
