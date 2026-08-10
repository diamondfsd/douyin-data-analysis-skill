#!/usr/bin/env bash
# 从抖音创作者中心作品评论页读取最近评论。仅使用页面已发出的列表请求。
# 用法：WS=./output bash scripts/fetch_douyin_comments.sh '<评论页链接>' [数量上限]

set -euo pipefail

# 抖音是国内站点，绕过代理（agent-browser 的 Chromium 不支持 HTTP 代理）
export HTTP_PROXY="" HTTPS_PROXY="" http_proxy="" https_proxy="" ALL_PROXY=""

# 持久化浏览器配置目录（cookie/localStorage 自动持久化，跟正常浏览器一样）
export AGENT_BROWSER_PROFILE="$HOME/.agent-browser/profiles/douyin"

PAGE_URL="${1:-}"
LIMIT="${2:-200}"
SESSION="douyin"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WS="${WS:-$(pwd)}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! "$PYTHON_BIN" - "$PAGE_URL" "$LIMIT" <<'PY'
import sys
from urllib.parse import parse_qs, urlparse

url, limit = sys.argv[1:]
try:
    parsed = urlparse(url)
    item_id = parse_qs(parsed.query).get("item_id", [""])[0]
    valid = (
        parsed.scheme == "https"
        and parsed.hostname == "creator.douyin.com"
        and parsed.path.startswith("/creator-micro/interactive/comment")
        and item_id.isdigit()
        and 1 <= int(limit) <= 1000
    )
except (TypeError, ValueError):
    valid = False
if not valid:
    raise SystemExit("用法：脚本参数必须是含 item_id 的抖音创作者中心作品评论页链接；数量上限为 1 到 1000。")
PY
then
  exit 64
fi

TS=$(date +%Y%m%d_%H%M%S)
OUT="$WS/douyin_comments_${TS}"
RAW_DIR="$OUT/raw"
mkdir -p "$RAW_DIR"

# 首页与评论子应用的鉴权可能独立；先恢复通用登录态，再以评论页 DOM 为准校验。
bash "$SCRIPT_DIR/restore_douyin_login.sh" >/dev/null || {
  echo "NEED_QR_SCAN"
  exit 2
}

agent-browser --session-name "$SESSION" network requests --clear >/dev/null
agent-browser --session-name "$SESSION" open "$PAGE_URL" >/dev/null
agent-browser --session-name "$SESSION" wait 1000 >/dev/null

PAGE_STATE=$(agent-browser --session-name "$SESSION" eval "(() => {
  const t = document.body.innerText || '';
  return JSON.stringify({
    isLogin: /扫码登录|验证码登录|密码登录|账号密码登录/.test(t),
    hasCommentPage: /评论管理|全部评论|评论列表|评论/.test(t),
    url: location.href
  });
})()")

PAGE_FLAGS=$(printf '%s' "$PAGE_STATE" | "$PYTHON_BIN" -c '
import json, sys
value = json.load(sys.stdin)
if isinstance(value, str):
    value = json.loads(value)
print("{} {}".format(
    str(bool(value.get("isLogin"))).lower(),
    str(bool(value.get("hasCommentPage"))).lower(),
))
')

if [[ "$PAGE_FLAGS" == "true "* ]]; then
  echo "NEED_QR_SCAN"
  exit 2
fi

if [[ "$PAGE_FLAGS" != *" true" ]]; then
  echo "评论页未正常加载，未读取任何评论。"
  exit 3
fi

# 评论页为滚动加载。滚动真实容器并根据评论相关 XHR/fetch 数量判断是否还有新页。
MAX_SCROLLS=$(( (LIMIT + 19) / 20 + 12 ))
if (( MAX_SCROLLS > 60 )); then MAX_SCROLLS=60; fi
IDLE_ROUNDS=0
LAST_COUNT=-1

for ((i=1; i<=MAX_SCROLLS; i++)); do
  agent-browser --session-name "$SESSION" eval "(() => {
    const candidates = Array.from(document.querySelectorAll('*'))
      .filter(e => e.scrollHeight > e.clientHeight + 80 && getComputedStyle(e).overflowY !== 'visible')
      .sort((a, b) => (b.scrollHeight - b.clientHeight) - (a.scrollHeight - a.clientHeight));
    const target = candidates[0] || document.scrollingElement || document.documentElement;
    target.scrollTop = target.scrollHeight;
    window.scrollTo(0, document.documentElement.scrollHeight);
    return JSON.stringify({scrollTop: target.scrollTop, scrollHeight: target.scrollHeight});
  })()" >/dev/null
  agent-browser --session-name "$SESSION" wait 500 >/dev/null

  CURRENT_COUNT=$(agent-browser --session-name "$SESSION" network requests --type xhr,fetch --json \
    | "$PYTHON_BIN" -c 'import json,sys; raw=json.load(sys.stdin); rows=raw.get("data",{}).get("requests",[]); print(sum("comment" in str(x.get("url","")).lower() for x in rows))')
  if [[ "$CURRENT_COUNT" == "$LAST_COUNT" ]]; then
    IDLE_ROUNDS=$((IDLE_ROUNDS + 1))
  else
    IDLE_ROUNDS=0
    LAST_COUNT="$CURRENT_COUNT"
  fi
  if (( IDLE_ROUNDS >= 3 )); then break; fi
done

REQUESTS_JSON="$OUT/comment_requests.json"
agent-browser --session-name "$SESSION" network requests --type xhr,fetch --json > "$REQUESTS_JSON"

# network request 能读取浏览器已完成请求的响应体，因此不重放签名请求或绕过页面逻辑。
REQUEST_IDS=()
while IFS= read -r request_id; do
  [[ -n "$request_id" ]] && REQUEST_IDS+=("$request_id")
done < <("$PYTHON_BIN" - "$REQUESTS_JSON" <<'PY'
import json, sys
raw = json.load(open(sys.argv[1]))
rows = raw.get("data", {}).get("requests", [])
for row in sorted(rows, key=lambda x: x.get("timestamp", 0)):
    url = str(row.get("url", "")).lower()
    if "comment" in url and row.get("requestId"):
        print(row["requestId"])
PY
)

if (( ${#REQUEST_IDS[@]} == 0 )); then
  echo "未发现评论列表请求，未读取任何评论。"
  exit 4
fi

for index in "${!REQUEST_IDS[@]}"; do
  agent-browser --session-name "$SESSION" network request "${REQUEST_IDS[$index]}" --json \
    > "$RAW_DIR/comment_response_$(printf '%03d' "$index").json" || true
done

"$PYTHON_BIN" - "$RAW_DIR" "$OUT/comments.json" "$PAGE_URL" "$LIMIT" "$TS" <<'PY'
import hashlib
import json
import os
import sys
from datetime import datetime
from urllib.parse import parse_qs, urlparse

raw_dir, out_file, page_url, limit, ts = sys.argv[1:]
limit = int(limit)
item_id = parse_qs(urlparse(page_url).query)["item_id"][0]

def unwrap(value):
    if isinstance(value, dict):
        body = value.get("data", {}).get("responseBody")
        if isinstance(body, str):
            try:
                return json.loads(body)
            except json.JSONDecodeError:
                return value
        if body is not None:
            return body
    return value

def pick(obj, *keys):
    for key in keys:
        if isinstance(obj, dict) and obj.get(key) not in (None, ""):
            return obj[key]
    return None

def normalize(row):
    info = row.get("comment_info") if isinstance(row.get("comment_info"), dict) else row
    if not isinstance(info, dict):
        return None
    text = pick(info, "text", "comment_text", "content")
    if not isinstance(text, str) or not text.strip():
        return None
    user = pick(info, "user", "user_info", "author")
    user = user if isinstance(user, dict) else {}
    comment_id = pick(info, "cid", "comment_id", "id")
    return {
        "comment_id": str(comment_id) if comment_id is not None else None,
        "text": text.strip(),
        "create_time": pick(info, "create_time", "create_time_ms", "timestamp"),
        "like_count": pick(info, "digg_count", "like_count"),
        "reply_count": pick(info, "reply_comment_total", "reply_count"),
        "user": {
            "id": str(pick(user, "uid", "user_id", "id")) if pick(user, "uid", "user_id", "id") is not None else None,
            "nickname": pick(user, "nickname", "name", "display_name"),
        },
    }

def visit(value, candidates):
    if isinstance(value, dict):
        for key, child in value.items():
            # 仅把带有评论语义的数组或评论对象候选加入，避免采集页面无关列表。
            if isinstance(child, list) and key.lower() in {"comments", "comment_list", "commentlist", "list", "items"}:
                normalized = [normalize(x) for x in child if isinstance(x, dict)]
                if any(normalized):
                    candidates.extend(x for x in normalized if x)
            visit(child, candidates)
    elif isinstance(value, list):
        for child in value:
            visit(child, candidates)

comments = []
for name in sorted(os.listdir(raw_dir)):
    if not name.endswith(".json"):
        continue
    try:
        raw = json.load(open(os.path.join(raw_dir, name)))
    except (OSError, json.JSONDecodeError):
        continue
    visit(unwrap(raw), comments)

unique = []
seen = set()
for comment in comments:
    fallback = hashlib.sha256((comment["text"] + str(comment["create_time"]) + str(comment["user"]["id"])).encode()).hexdigest()
    key = comment["comment_id"] or fallback
    if key not in seen:
        seen.add(key)
        unique.append(comment)

payload = {
    "meta": {
        "generated_at": datetime.now().strftime("%Y-%m-%d %H:%M"),
        "item_id": item_id,
        "source_url": page_url,
        "limit": limit,
        "returned_count": min(len(unique), limit),
        "has_more_in_page": len(unique) > limit,
        "archive_slot": ts,
    },
    "comments": unique[:limit],
}
with open(out_file, "w") as fp:
    json.dump(payload, fp, ensure_ascii=False, indent=2)
print(f"评论已汇总: {payload['meta']['returned_count']} 条 -> {out_file}")
PY

echo "输出目录: $OUT"
