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
#
# 用法： bash scripts/restore_douyin_login.sh
# ============================================================================

set -uo pipefail

# 抖音是国内站点，绕过代理（agent-browser 的 Chromium 不支持 HTTP 代理）
export HTTP_PROXY="" HTTPS_PROXY="" http_proxy="" https_proxy="" ALL_PROXY=""

# 持久化浏览器配置目录（cookie/localStorage 自动持久化，跟正常浏览器一样）
export AGENT_BROWSER_PROFILE="$HOME/.agent-browser/profiles/douyin"
SESSION="douyin"

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

# 页面可能仍在渲染；短轮询 DOM
wait_for_login() {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if is_login; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

# 1) 确保浏览器已打开首页（复用 daemon，不新建）
agent-browser --session-name "$SESSION" open "https://creator.douyin.com/creator-micro/home" >/dev/null 2>&1 || true

# 2) 检查是否已登录（profile 持久化 cookie，通常直接就是登录态）
if wait_for_login; then
  echo "ALREADY_LOGGED_IN"
  exit 0
fi

echo "NEED_QR_SCAN"
exit 2
