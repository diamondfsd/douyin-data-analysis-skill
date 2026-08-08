#!/usr/bin/env bash
# ============================================================================
# restore_douyin_login.sh —— 抖音创作者中心登录态恢复（无扫码优先）
#
# 背景（实测踩坑）：agent-browser 的 `--session-name <name>` 在 close 时确实
# 会把 cookies 保存到 ~/.agent-browser/sessions/<name>-default.json，但重新
# open 时【不会把登录 cookie 注入浏览器】，导致每次打开仍是匿名态、必须
# 重新扫码。外部流传的 `--session <id> --restore` 写法在当前版本【不存在】
# （没有 --restore 这个 flag，且 --session 是隔离会话、不自动保存）。
#
# 本脚本解决方案：手动把已保存的登录 cookie 逐个注入当前浏览器，reload 后
# 即可恢复登录态，避免重复扫码。脚本幂等，可每次分析前调用。
#
# 退出码：
#   0  = 已登录（原本就登录，或注入 cookie 后登录成功）
#   2  = 无 session 文件，需用户首次扫码
#   3  = 有 session 文件但注入后仍无法登录，需用户重新扫码
#
# 用法： bash scripts/restore_douyin_login.sh
# ============================================================================

set -uo pipefail

SESSION="douyin"
SESSION_FILE="$HOME/.agent-browser/sessions/${SESSION}-default.json"
PYTHON_BIN="${PYTHON_BIN:-python3}"

# 判断是否已登录（DOM 文本法，不依赖 URL/title）
is_login() {
  local out
  out=$(agent-browser --session-name "$SESSION" eval "(() => {
    const t = document.body.innerText || '';
    const logged = /数据概览|数据看板|数据中心|作品数据|粉丝分析|账号全景/.test(t)
               && !/扫码登录|验证码登录|密码登录|账号密码登录/.test(t);
    return logged ? 'true' : 'false';
  })()" 2>/dev/null)
  [[ "$out" == *"true"* ]]
}

# 1) 确保浏览器已打开首页（复用 daemon，不新建）
agent-browser --session-name "$SESSION" open "https://creator.douyin.com/creator-micro/home" >/dev/null 2>&1 || true
agent-browser --session-name "$SESSION" wait --load networkidle >/dev/null 2>&1 || true

# 2) 已登录则直接返回（最常见：上次已注入且 cookie 未过期）
if is_login; then
  echo "ALREADY_LOGGED_IN"
  exit 0
fi

# 3) 没有 session 文件 → 需要首次扫码
if [ ! -f "$SESSION_FILE" ]; then
  echo "NEED_QR_SCAN"
  exit 2
fi

# 4) 从 session 文件把登录 cookie 注入当前浏览器
"$PYTHON_BIN" - "$SESSION_FILE" "$SESSION" <<'PY'
import json, subprocess, sys
F, SESS = sys.argv[1], sys.argv[2]
d = json.load(open(F))
cookies = d.get("cookies", [])
SAME = {"None":"None","no_restriction":"None","Lax":"Lax","Strict":"Strict",
        "none":"None","lax":"Lax","strict":"Strict"}
ok = fail = 0
for c in cookies:
    name = c.get("name"); value = c.get("value")
    if not name:
        continue
    args = ["agent-browser", "--session-name", SESS, "cookies", "set", name, str(value)]
    if c.get("domain"):
        args += ["--domain", c["domain"]]
    else:
        args += ["--url", "https://creator.douyin.com"]
    if c.get("path"):
        args += ["--path", c["path"]]
    if c.get("httpOnly"):
        args += ["--httpOnly"]
    if c.get("secure"):
        args += ["--secure"]
    s = c.get("sameSite")
    if s and str(s) in SAME:
        args += ["--sameSite", SAME[str(s)]]
    exp = c.get("expires")
    if exp and isinstance(exp, (int, float)) and exp > 0:
        args += ["--expires", str(int(exp))]
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode == 0:
        ok += 1
    else:
        fail += 1
print(f"INJECT_OK={ok} FAIL={fail}")
PY

# 5) reload 并再次验证登录
agent-browser --session-name "$SESSION" reload >/dev/null 2>&1 || true
agent-browser --session-name "$SESSION" wait --load networkidle >/dev/null 2>&1 || true

if is_login; then
  echo "RESTORED_LOGIN"
  exit 0
else
  echo "NEED_QR_SCAN"
  exit 3
fi
