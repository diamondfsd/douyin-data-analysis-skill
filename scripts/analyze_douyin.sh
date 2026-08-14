#!/usr/bin/env bash
# ============================================================================
# analyze_douyin.sh —— 抖音数据一键取数 + 汇总（纯数据，不含分析/报告）
#
# 职责边界（重要）：
#   * 本脚本【只】做三件事：恢复登录 → 抓取原始接口 → 汇总成 douyin_data.json。
#     不做截图、不做分析、不生成 HTML、不写死结论。
#   * 详细的趋势解读、逐视频分析、指导性建议、以及最终的 HTML 单页报告，
#     全部由【AI agent】读取 douyin_data.json 后生成（见 SKILL.md Step 5）。
#
# 用法：
#   WS=/path/to/out bash scripts/analyze_douyin.sh
# 输出：<WS>/douyin_analysis_<TS>/
#        overview.json  items.json          （原始接口响应，留底）
#        douyin_data.json                    （汇总 + 部分明细，AI 读取的主数据）
# ============================================================================

set -uo pipefail

# 抖音是国内站点，绕过代理（agent-browser 的 Chromium 不支持 HTTP 代理）
export HTTP_PROXY="" HTTPS_PROXY="" http_proxy="" https_proxy="" ALL_PROXY=""

# 持久化浏览器配置目录（cookie/localStorage 自动持久化，跟正常浏览器一样）
export AGENT_BROWSER_PROFILE="$HOME/.agent-browser/profiles/douyin"

SESSION="douyin"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WS="${WS:-$(pwd)}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
TS=$(date +%Y%m%d_%H%M%S)
OUT="$WS/douyin_analysis_${TS}"
mkdir -p "$OUT"

echo "==> [1/3] 恢复登录态（无扫码优先）"
if ! bash "$SCRIPT_DIR/restore_douyin_login.sh"; then
  rc=$?
  if [ "$rc" -eq 3 ]; then
    echo "NEED_USER_VERIFY：登录需用户验证（短信验证码等），请先运行 scripts/headed_login_douyin.sh 切有头浏览器让用户完成验证，再重跑本脚本。"
  else
    echo "登录失败，请先扫码登录。"
  fi
  exit 1
fi

# 取数方式（2026-08-14 重构）：不再 eval+fetch 重放接口（抖音风控会拦截裸 fetch，
# 返回 status_code:8 用户未登录），改为【抓包页面自身发出的请求响应】——
# reload 页面 → 页面自己带风控参数（msToken/a_bogus）请求数据接口 →
# 用 network requests 找 requestId → network request 取响应体。
# 只使用 agent-browser 原生 network 命令，不注入任何 eval 脚本。
#
# 注意：network request 输出的 JSON 结构与脚本解析兼容：
#   {"data": {"responseBody": "..."}}
ensure_home_loaded() {
  # 打开首页（已打开则幂等无副作用）；等待页面发出数据请求
  agent-browser --session-name "$SESSION" open "https://creator.douyin.com/creator-micro/home" >/dev/null 2>&1
  agent-browser --session-name "$SESSION" wait 3000
}

find_request_id() {
  # 从 network 日志中找最新一条匹配 filter 的请求 id
  local filter="$1"
  agent-browser --session-name "$SESSION" network requests --filter "$filter" --json 2>/dev/null | "$PYTHON_BIN" -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
items = data.get('requests') or data.get('items') or data.get('data') or []
if isinstance(items, dict):
    items = items.get('requests') or items.get('items') or []
if items:
    print(items[-1].get('requestId', ''))
"
}

grab() {
  local filter="$1" out="$2" rid="" i
  # 等待页面自身发出的请求出现在 network 日志
  for i in 1 2 3 4 5 6 7 8 9 10; do
    rid=$(find_request_id "$filter")
    [ -n "$rid" ] && break
    agent-browser --session-name "$SESSION" wait 1000
  done
  if [ -z "$rid" ]; then
    echo "    [警告] 未找到接口请求: $filter"
    return 1
  fi

  agent-browser --session-name "$SESSION" network request "$rid" --json > "$out" 2>/dev/null

  if "$PYTHON_BIN" - "$out" <<'PY'
import json, sys
raw = json.load(open(sys.argv[1]))
body = raw.get("data", {}).get("responseBody") if isinstance(raw, dict) else None
if not body:
    raise SystemExit(1)
json.loads(body) if isinstance(body, str) else body
PY
  then
    echo "    抓取成功: $out"
    return 0
  else
    echo "    [警告] 接口响应无有效数据: $filter"
    return 1
  fi
}

echo "==> [2/3] 抓取 overview/all + item/list（抓包页面自身请求）"
ensure_home_loaded
agent-browser --session-name "$SESSION" network requests --clear >/dev/null 2>&1
agent-browser --session-name "$SESSION" reload >/dev/null 2>&1
agent-browser --session-name "$SESSION" wait 8000
grab "overview/all" "$OUT/overview.json"
grab "item/list"    "$OUT/items.json"

echo "==> [3/3] 汇总原始数据 → douyin_data.json（仅数据，不含分析）"
"$PYTHON_BIN" - "$OUT" <<'PY'
import json, sys, os
from datetime import datetime

OUT = sys.argv[1]

def load(name):
    p = os.path.join(OUT, name)
    if not os.path.exists(p):
        return None
    try:
        raw = json.load(open(p))
    except Exception:
        return None
    body = raw.get("data", {}).get("responseBody") if isinstance(raw, dict) else None
    if isinstance(body, str):
        try:
            body = json.loads(body)
        except Exception:
            body = None
    return body

ov = load("overview.json")
items = load("items.json")

def ti(v):
    try: return int(float(v))
    except: return 0
def tf(v):
    try: return float(v)
    except: return None

label = {
    "play":"播放量","digg":"点赞","comment":"评论","share":"分享",
    "fans":"粉丝总量","new_fans":"净增粉丝","cancel_fans":"取关粉丝",
    "profile":"主页访问","account_search":"账号搜索量","post_search":"投稿搜索量",
}
overview = []
ovd = (ov or {}).get("data", {})
for k, zh in label.items():
    m = ovd.get(k)
    if not m:
        continue
    cur = ti(m.get("current_count"))
    incr = ti(m.get("last_period_incr"))
    # 粉丝总量修复：overview/all 的 fans.current_count 对本账号返回异常值（如 10014），
    # 真实总粉丝应从 option_list 末日「累计值」取（如 1352→1540，与用户真实粉丝量一致）。
    # 若 option_list 存在，一律改用其末日累计值 + 区间差值（正常账号两者一致，不会误伤）。
    if k == "fans" and m.get("option_list"):
        ol = m["option_list"]
        cur = ti(ol[-1].get("count"))
        if len(ol) >= 2:
            incr = ti(ol[-1].get("count")) - ti(ol[0].get("count"))
    entry = {"key":k, "label":zh,
             "current":cur,
             "last_period_incr":incr}
    if k == "play" and "option_list" in m:
        entry["daily"] = [{"date":d.get("date"), "count":ti(d.get("count"))}
                          for d in m["option_list"]]
    overview.append(entry)

videos = []
if items and "items" in items:
    for x in items["items"]:
        ct = x.get("create_time")
        try:
            cdate = datetime.fromtimestamp(int(ct)).strftime('%Y-%m-%d') if ct else None
        except Exception:
            cdate = None
        m = x.get("metrics", {})
        def g(key):
            v = m.get(key)
            return tf(v) if v is not None else None
        videos.append({
            "title": (x.get("description") or "").strip().replace("\n", " "),
            "create_time": ct,
            "create_date": cdate,
            "metrics": {
                "view_count": g("view_count"), "like_count": g("like_count"),
                "comment_count": g("comment_count"), "share_count": g("share_count"),
                "favorite_count": g("favorite_count"),
                "completion_rate_5s": g("completion_rate_5s"),
                "completion_rate": g("completion_rate"),
                "bounce_rate_2s": g("bounce_rate_2s"),
                "avg_view_second": g("avg_view_second"),
                "like_rate": g("like_rate"), "comment_rate": g("comment_rate"),
                "share_rate": g("share_rate"),
                "cover_click_rate": g("cover_click_rate"),
                "fan_view_proportion": g("fan_view_proportion"),
            },
        })

data = {
    "meta": {
        "generated_at": datetime.now().strftime('%Y-%m-%d %H:%M'),
        "period": "近7天",
    },
    "overview": overview,
    "videos": videos,
}
with open(os.path.join(OUT, "douyin_data.json"), "w") as fp:
    json.dump(data, fp, ensure_ascii=False, indent=2)
print(f"数据已汇总: overview {len(overview)} 项, 视频 {len(videos)} 条 -> douyin_data.json")
print("（本脚本仅输出数据；详细分析/图表/HTML 报告由 AI agent 读取 douyin_data.json 后生成）")
PY

echo "==> 完成。输出目录: $OUT"

# ============================================================================
# 存档：将 douyin_data.json + items.json 写入固定存档目录，方便跨会话分析
# ============================================================================
ARCHIVE_DIR="$WS/douyin_archive"
mkdir -p "$ARCHIVE_DIR"

ARCHIVE_SLOT="$ARCHIVE_DIR/$TS"
mkdir -p "$ARCHIVE_SLOT"
cp "$OUT/douyin_data.json" "$ARCHIVE_SLOT/douyin_data.json"
cp "$OUT/items.json"        "$ARCHIVE_SLOT/items.json"
echo "    已存档: $ARCHIVE_SLOT"

# 更新索引文件
INDEX="$ARCHIVE_DIR/index.json"
if [ -f "$INDEX" ]; then
  "$PYTHON_BIN" -c "
import json,sys
idx=json.load(open('$INDEX'))
idx['slots'].append({
  'ts':'$TS',
  'datetime':'$(date '+%Y-%m-%d %H:%M')',
  'dir':'$ARCHIVE_SLOT',
  'douyin_data':'$ARCHIVE_SLOT/douyin_data.json',
  'items':'$ARCHIVE_SLOT/items.json'
})
idx['slots']=sorted(idx['slots'], key=lambda x:x['ts'])
json.dump(idx,open('$INDEX','w'),ensure_ascii=False,indent=2)
" 2>/dev/null
else
  "$PYTHON_BIN" -c "
import json
json.dump({
  'created_at':'$(date '+%Y-%m-%d %H:%M')',
  'slots':[{
    'ts':'$TS',
    'datetime':'$(date '+%Y-%m-%d %H:%M')',
    'dir':'$ARCHIVE_SLOT',
    'douyin_data':'$ARCHIVE_SLOT/douyin_data.json',
    'items':'$ARCHIVE_SLOT/items.json'
  }]
},open('$INDEX','w'),ensure_ascii=False,indent=2)
"
fi
echo "    索引已更新: $INDEX ($(python3 -c "import json;print(len(json.load(open('$INDEX'))['slots']))") 个快照)"
