#!/usr/bin/env bash
# Normalize raw response envelopes written by the direct ego-browser workflow.
# This script never opens a browser or checks login state.

set -euo pipefail

RAW_DIR="${RAW_DIR:-${1:-}}"
if [[ -z "$RAW_DIR" || ! -d "$RAW_DIR" ]]; then
  echo "用法：RAW_DIR=/absolute/path/to/raw bash scripts/analyze_douyin.sh" >&2
  exit 64
fi

OUT="${OUT:-$RAW_DIR}"
WS="${WS:-$(cd "$OUT/.." && pwd)}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
mkdir -p "$OUT"

for required in overview.json items.json; do
  if [[ ! -f "$RAW_DIR/$required" ]]; then
    echo "缺少原始响应：$RAW_DIR/$required" >&2
    exit 65
  fi
done

"$PYTHON_BIN" - "$OUT" <<'PY'
import json
import os
import sys
from datetime import datetime

out_dir = sys.argv[1]

def load(name):
    path = os.path.join(out_dir, name)
    try:
        raw = json.load(open(path, encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    body = raw.get("data", {}).get("responseBody") if isinstance(raw, dict) else None
    if isinstance(body, str):
        try:
            body = json.loads(body)
        except json.JSONDecodeError:
            body = None
    return body

ov = load("overview.json")
items = load("items.json")

def ti(value):
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return 0

def tf(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None

labels = {
    "play": "播放量", "digg": "点赞", "comment": "评论", "share": "分享",
    "fans": "粉丝总量", "new_fans": "净增粉丝", "cancel_fans": "取关粉丝",
    "profile": "主页访问", "account_search": "账号搜索量", "post_search": "投稿搜索量",
}
overview = []
overview_data = (ov or {}).get("data", {})
for key, label in labels.items():
    metric = overview_data.get(key)
    if not metric:
        continue
    current = ti(metric.get("current_count"))
    increment = ti(metric.get("last_period_incr"))
    if key == "fans" and metric.get("option_list"):
        options = metric["option_list"]
        current = ti(options[-1].get("count"))
        if len(options) >= 2:
            increment = ti(options[-1].get("count")) - ti(options[0].get("count"))
    entry = {"key": key, "label": label, "current": current, "last_period_incr": increment}
    if key == "play" and "option_list" in metric:
        entry["daily"] = [
            {"date": item.get("date"), "count": ti(item.get("count"))}
            for item in metric["option_list"]
        ]
    overview.append(entry)

videos = []
item_data = items or {}
for item in item_data.get("items", []):
    create_time = item.get("create_time")
    try:
        create_date = datetime.fromtimestamp(int(create_time)).strftime("%Y-%m-%d") if create_time else None
    except (TypeError, ValueError, OSError):
        create_date = None
    metrics = item.get("metrics") or {}
    videos.append({
        "title": (item.get("description") or "").strip().replace("\n", " "),
        "create_time": create_time,
        "create_date": create_date,
        "metrics": {
            "view_count": tf(metrics.get("view_count")),
            "like_count": tf(metrics.get("like_count")),
            "comment_count": tf(metrics.get("comment_count")),
            "share_count": tf(metrics.get("share_count")),
            "favorite_count": tf(metrics.get("favorite_count")),
            "completion_rate_5s": tf(metrics.get("completion_rate_5s")),
            "completion_rate": tf(metrics.get("completion_rate")),
            "bounce_rate_2s": tf(metrics.get("bounce_rate_2s")),
            "avg_view_second": tf(metrics.get("avg_view_second")),
            "like_rate": tf(metrics.get("like_rate")),
            "comment_rate": tf(metrics.get("comment_rate")),
            "share_rate": tf(metrics.get("share_rate")),
            "cover_click_rate": tf(metrics.get("cover_click_rate")),
            "fan_view_proportion": tf(metrics.get("fan_view_proportion")),
        },
    })

payload = {
    "meta": {"generated_at": datetime.now().strftime("%Y-%m-%d %H:%M"), "period": "近7天"},
    "overview": overview,
    "videos": videos,
}
with open(os.path.join(out_dir, "douyin_data.json"), "w", encoding="utf-8") as fp:
    json.dump(payload, fp, ensure_ascii=False, indent=2)
print(f"数据已汇总: overview {len(overview)} 项, 视频 {len(videos)} 条 -> {out_dir}/douyin_data.json")
PY

TS="${ARCHIVE_TS:-$(date +%Y%m%d_%H%M%S)}"
ARCHIVE_DIR="$WS/douyin_archive"
ARCHIVE_SLOT="$ARCHIVE_DIR/$TS"
mkdir -p "$ARCHIVE_SLOT"
cp "$OUT/douyin_data.json" "$ARCHIVE_SLOT/douyin_data.json"
cp "$OUT/items.json" "$ARCHIVE_SLOT/items.json"

INDEX="$ARCHIVE_DIR/index.json"
"$PYTHON_BIN" - "$INDEX" "$TS" "$ARCHIVE_SLOT" <<'PY'
import json
import os
import sys
from datetime import datetime

index_path, timestamp, archive_slot = sys.argv[1:]
try:
    index = json.load(open(index_path, encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    index = {"created_at": datetime.now().strftime("%Y-%m-%d %H:%M"), "slots": []}
slots = [slot for slot in index.get("slots", []) if slot.get("ts") != timestamp]
slots.append({
    "ts": timestamp,
    "datetime": datetime.now().strftime("%Y-%m-%d %H:%M"),
    "dir": archive_slot,
    "douyin_data": os.path.join(archive_slot, "douyin_data.json"),
    "items": os.path.join(archive_slot, "items.json"),
})
index["slots"] = sorted(slots, key=lambda slot: slot.get("ts", ""))
with open(index_path, "w", encoding="utf-8") as fp:
    json.dump(index, fp, ensure_ascii=False, indent=2)
PY

echo "归一化完成: $OUT/douyin_data.json"
echo "历史存档: $ARCHIVE_SLOT"
