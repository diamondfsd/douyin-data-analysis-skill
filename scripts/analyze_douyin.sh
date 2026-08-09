#!/usr/bin/env bash
# ============================================================================
# analyze_douyin.sh —— 抖音数据一键取数 + 汇总（纯数据，不含分析/报告）
#
# 职责边界（重要）：
#   * 本脚本【只】做三件事：恢复登录 → 抓取原始接口 → 汇总成 douyin_data.json
#     + 后台截图。不做任何分析、不生成 HTML、不写死结论。
#   * 详细的趋势解读、逐视频分析、指导性建议、以及最终的 HTML 单页报告，
#     全部由【AI agent】读取 douyin_data.json + 截图后生成（见 SKILL.md Step 5）。
#
# 用法：
#   WS=/path/to/out bash scripts/analyze_douyin.sh
# 输出：<WS>/douyin_analysis_<TS>/
#        overview.json  items.json          （原始接口响应，留底）
#        dashboard_<TS>.png  content_<TS>.png （后台截图，供 AI 嵌入报告）
#        douyin_data.json                    （汇总 + 部分明细，AI 读取的主数据）
# ============================================================================

set -uo pipefail

SESSION="douyin"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WS="${WS:-$(pwd)}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
TS=$(date +%Y%m%d_%H%M%S)
OUT="$WS/douyin_analysis_${TS}"
mkdir -p "$OUT"

echo "==> [1/4] 恢复登录态（无扫码优先）"
bash "$SCRIPT_DIR/restore_douyin_login.sh" || { echo "登录失败，请先扫码登录。"; exit 1; }

# 抓取某个接口的原始响应体，存到 $2
grab() {
  local filter="$1" out="$2"
  agent-browser --session-name "$SESSION" network requests --clear >/dev/null 2>&1
  agent-browser --session-name "$SESSION" open "https://creator.douyin.com/creator-micro/home" >/dev/null 2>&1
  sleep 5
  local js rid
  js=$(agent-browser --session-name "$SESSION" network requests --filter "$filter" --json 2>/dev/null)
  rid=$(echo "$js" | grep -oE '"requestId":"[^"]*"' | head -1 | sed 's/"requestId":"//; s/"$//')
  if [ -n "$rid" ]; then
    agent-browser --session-name "$SESSION" network request "$rid" --json > "$out"
    echo "    抓取成功: $out"
  else
    echo "    [警告] 未找到接口: $filter"
  fi
}

echo "==> [2/4] 抓取 overview/all + item/list（收入接口已移除：账号未开通变现时为 0，无意义）"
grab "overview/all" "$OUT/overview.json"
grab "item/list"    "$OUT/items.json"

echo "==> [3/4] 后台截图（供 AI 生成报告时图文并茂）"
agent-browser --session-name "$SESSION" open "https://creator.douyin.com/creator-micro/home" >/dev/null 2>&1
sleep 4
agent-browser --session-name "$SESSION" screenshot "$OUT/dashboard_${TS}.png" 2>/dev/null \
  && echo "    截图: $OUT/dashboard_${TS}.png"
agent-browser --session-name "$SESSION" open "https://creator.douyin.com/creator-micro/content/manage" >/dev/null 2>&1
sleep 4
agent-browser --session-name "$SESSION" screenshot "$OUT/content_${TS}.png" 2>/dev/null \
  && echo "    截图: $OUT/content_${TS}.png"

echo "==> [4/4] 汇总原始数据 → douyin_data.json（仅数据，不含分析）"
DASH_PNG="dashboard_${TS}.png"
CONTENT_PNG="content_${TS}.png"
"$PYTHON_BIN" - "$OUT" "$DASH_PNG" "$CONTENT_PNG" <<'PY'
import json, sys, os
from datetime import datetime

OUT, DASH_PNG, CONTENT_PNG = sys.argv[1], sys.argv[2], sys.argv[3]

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
        "screenshots": {"dashboard": DASH_PNG, "content": CONTENT_PNG},
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
