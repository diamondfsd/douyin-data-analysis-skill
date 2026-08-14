#!/usr/bin/env bash
# ============================================================================
# restore_douyin_login.sh —— 抖音创作者中心登录态恢复（无扫码优先）
#
# 核心方案：使用 --profile 持久化浏览器配置目录，cookie/localStorage 自动
# 保存在磁盘上（跟正常浏览器一样），无需手动导出/注入 cookie。
#
# 退出码：
#   0  = 已登录
#   2  = 未登录，需用户扫码
#   3  = 登录流程中，需用户验证（短信验证码/安全验证）——须切有头浏览器，
#        见 SKILL.md Step 2A 与 scripts/headed_login_douyin.sh
#
# 用法： bash scripts/restore_douyin_login.sh
# ============================================================================

set -uo pipefail

# 抖音是国内站点，绕过代理（agent-browser 的 Chromium 不支持 HTTP 代理）
export HTTP_PROXY="" HTTPS_PROXY="" http_proxy="" https_proxy="" ALL_PROXY=""

# 持久化浏览器配置目录（cookie/localStorage 自动持久化，跟正常浏览器一样）
export AGENT_BROWSER_PROFILE="$HOME/.agent-browser/profiles/douyin"
SESSION="douyin"

# 读取页面明文（DOM 文本法，不依赖 URL/title）。
# 注意：agent-browser eval 的返回值是【JSON 字符串（带转义）】，
# 例如输出形如 "{\"logged\":true}" —— 因此不要用 '"logged":true' 这种
# 无转义子串去匹配（永远匹配不上）。这里统一取 innerText 明文做 contains 匹配。
page_text() {
  agent-browser --session-name "$SESSION" eval "document.body.innerText || ''" 2>/dev/null
}

# 判断是否已登录：命中后台特征词，且无任何登录页特征词
is_login() {
  local t
  t=$(page_text)
  [[ "$t" == *"数据中心"* || "$t" == *"数据概览"* || "$t" == *"作品数据"* || "$t" == *"粉丝分析"* ]] \
    && [[ "$t" != *"扫码登录"* && "$t" != *"验证码登录"* && "$t" != *"密码登录"* && "$t" != *"账号密码登录"* ]]
}

# 判断是否处于用户验证步骤（短信验证码/安全验证）
is_verify_pending() {
  local t
  t=$(page_text)
  [[ "$t" == *"需在手机上进行确认"* || "$t" == *"请输入验证码"* || "$t" == *"验证码已发送"* \
     || "$t" == *"短信验证码"* || "$t" == *"安全验证"* || "$t" == *"滑动验证"* || "$t" == *"图形验证"* ]]
}

# 页面是否已渲染完成（readyState=complete 且 body 有内容）。
# eval 返回明文 "complete|<长度>"，避免 JSON 转义匹配问题。
page_ready() {
  agent-browser --session-name "$SESSION" eval \
    "document.readyState + '|' + (document.body.innerText || '').length" 2>/dev/null
}

# 等待页面渲染完成（最多 15 秒）
wait_page_ready() {
  local st bl
  for _ in $(seq 1 15); do
    st=$(page_ready)
    if [[ "$st" == *"complete"* ]] && [[ "$st" =~ \|([0-9]+) ]]; then
      bl=${BASH_REMATCH[1]}
      if [ "$bl" -ge 200 ]; then
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

# 轮询登录态（最多 20 秒）
wait_for_login() {
  for _ in $(seq 1 20); do
    if is_login; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# 1) 快速检查当前页面：若已登录直接成功（不导航、不打断正在进行的登录/验证流程）
for _ in 1 2 3; do
  if is_login; then
    echo "ALREADY_LOGGED_IN"
    exit 0
  fi
  if is_verify_pending; then
    echo "NEED_USER_VERIFY"
    exit 3
  fi
  sleep 1
done

# 2) 未登录：确保浏览器已打开首页（复用 daemon，不新建）
agent-browser --session-name "$SESSION" open "https://creator.douyin.com/creator-micro/home" >/dev/null 2>&1 || true

# 3) 等页面渲染完成后轮询登录态
#    （无头模式新开 daemon 时 SPA 加载较慢，必须等渲染完再判定，否则会误判未登录）
wait_page_ready
if wait_for_login; then
  echo "ALREADY_LOGGED_IN"
  exit 0
fi

# 4) 未登录但处于「用户验证」步骤（短信验证码/安全验证）→ 须切有头浏览器让用户完成
if is_verify_pending; then
  echo "NEED_USER_VERIFY"
  exit 3
fi

echo "NEED_QR_SCAN"
exit 2
