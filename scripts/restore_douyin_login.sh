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

# 读取页面状态（DOM 文本法，不依赖 URL/title）：
#   logged     是否已登录
#   needVerify 是否处于「用户验证」步骤（短信验证码/安全验证）
page_state() {
  agent-browser --session-name "$SESSION" eval "(() => {
    const t = document.body.innerText || '';
    const logged = /数据概览|数据看板|数据中心|作品数据|粉丝分析|账号全景/.test(t)
               && !/扫码登录|验证码登录|密码登录|账号密码登录/.test(t);
    const needVerify = /需在手机上进行确认|请输入验证码|验证码已发送|短信验证码|验证码登录|安全验证|滑动验证|图形验证/.test(t);
    return JSON.stringify({logged, needVerify});
  })()" 2>/dev/null
}

# 判断是否已登录
is_login() {
  [[ "$(page_state)" == *'"logged":true'* ]]
}

# 判断是否处于用户验证步骤
is_verify_pending() {
  [[ "$(page_state)" == *'"needVerify":true'* ]]
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

# 3) 未登录但处于「用户验证」步骤（短信验证码/安全验证）→ 须切有头浏览器让用户完成
if is_verify_pending; then
  echo "NEED_USER_VERIFY"
  exit 3
fi

echo "NEED_QR_SCAN"
exit 2
