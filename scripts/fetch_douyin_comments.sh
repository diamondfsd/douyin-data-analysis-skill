#!/usr/bin/env bash
# Normalize comment response envelopes written by the direct ego-browser flow.
# This script never opens a browser, refreshes a page, or checks login state.

set -euo pipefail

PAGE_URL="${1:-}"
LIMIT="${2:-200}"
RAW_DIR="${RAW_DIR:-${3:-}}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! "$PYTHON_BIN" - "$PAGE_URL" "$LIMIT" "$RAW_DIR" <<'PY'
import sys
from urllib.parse import parse_qs, urlparse

url, limit, raw_dir = sys.argv[1:]
try:
    parsed = urlparse(url)
    item_id = parse_qs(parsed.query).get("item_id", [""])[0]
    valid = (
        parsed.scheme == "https"
        and parsed.hostname == "creator.douyin.com"
        and parsed.path.startswith("/creator-micro/interactive/comment")
        and item_id.isdigit()
        and 1 <= int(limit) <= 1000
        and raw_dir
    )
except (TypeError, ValueError):
    valid = False
if not valid:
    raise SystemExit("用法：RAW_DIR=/absolute/path/to/raw bash scripts/fetch_douyin_comments.sh '<评论页链接>' [数量上限]")
PY
then
  exit 64
fi

if ! compgen -G "$RAW_DIR/comment_response_*.json" >/dev/null; then
  echo "缺少评论原始响应：$RAW_DIR/comment_response_*.json" >&2
  exit 65
fi

OUT="${OUT:-$RAW_DIR}"
mkdir -p "$OUT"

"$PYTHON_BIN" - "$RAW_DIR" "$OUT/comments.json" "$PAGE_URL" "$LIMIT" <<'PY'
import hashlib
import json
import os
import sys
from datetime import datetime
from urllib.parse import parse_qs, urlparse

raw_dir, out_file, page_url, limit = sys.argv[1:]
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
    user_id = pick(user, "uid", "user_id", "id")
    comment_id = pick(info, "cid", "comment_id", "id")
    return {
        "comment_id": str(comment_id) if comment_id is not None else None,
        "text": text.strip(),
        "create_time": pick(info, "create_time", "create_time_ms", "timestamp"),
        "like_count": pick(info, "digg_count", "like_count"),
        "reply_count": pick(info, "reply_comment_total", "reply_count"),
        "user": {
            "id": str(user_id) if user_id is not None else None,
            "nickname": pick(user, "nickname", "name", "display_name"),
        },
    }

def visit(value, candidates):
    if isinstance(value, dict):
        for key, child in value.items():
            if isinstance(child, list) and key.lower() in {"comments", "comment_list", "commentlist", "list", "items"}:
                normalized = [normalize(item) for item in child if isinstance(item, dict)]
                candidates.extend(item for item in normalized if item)
            visit(child, candidates)
    elif isinstance(value, list):
        for child in value:
            visit(child, candidates)

comments = []
for name in sorted(os.listdir(raw_dir)):
    if not name.startswith("comment_response_") or not name.endswith(".json"):
        continue
    try:
        raw = json.load(open(os.path.join(raw_dir, name), encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        continue
    visit(unwrap(raw), comments)

unique = []
seen = set()
for comment in comments:
    fallback = hashlib.sha256(
        (comment["text"] + str(comment["create_time"]) + str(comment["user"]["id"])).encode()
    ).hexdigest()
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
    },
    "comments": unique[:limit],
}
with open(out_file, "w", encoding="utf-8") as fp:
    json.dump(payload, fp, ensure_ascii=False, indent=2)
print(f"评论已汇总: {payload['meta']['returned_count']} 条 -> {out_file}")
PY
