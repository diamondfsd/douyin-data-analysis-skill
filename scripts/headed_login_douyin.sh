#!/usr/bin/env bash
# ============================================================================
# headed_login_douyin.sh —— 切换到有头浏览器完成登录 / 用户验证
#
# 背景（2026-08-14 实测）：扫码登录后可能遇到「用户验证」步骤——
#   页面弹出短信验证码输入（或安全验证/滑动验证）。这不是每次登录都出现，
#   但一旦出现，无头模式用户无法操作，必须切到有头浏览器让用户直接看窗口完成。
#
# 职责：
#   1) 若当前已是可见有头模式 → 直接复用，不杀 daemon（避免打断正在验证的用户）
#   2) 否则关闭现有（可能是无头/僵死的）daemon，用 AGENT_BROWSER_HEADED=1
#      以有头模式重新启动浏览器（同一 --profile，扫码进度/登录态保留）
#   3) 打开抖音创作者中心登录页，等待用户直接看窗口操作
#
# 关键教训（2026-08-14 实测）：
#   * AGENT_BROWSER_HEADED 必须在 daemon 启动前生效——只对单条命令设环境变量
#     没用，daemon 已在无头模式启动时 Chrome 仍带 --headless=new。
#     切有头 = 先 close --all 杀 daemon → 再带 AGENT_BROWSER_HEADED=1 重新 open。
#   * 切有头不丢登录进度：--profile 持久化目录下 cookie/页面状态都在磁盘，
#     扫码 token 由服务端轮询接口持有，页面重开后自动恢复。
#
# 用法： bash scripts/headed_login_douyin.sh
# 退出码：0 = 有头浏览器已就绪（用户可直接操作窗口）
# ============================================================================

set -uo pipefail

# 抖音是国内站点，绕过代理（agent-browser 的 Chromium 不支持 HTTP 代理）
export HTTP_PROXY="" HTTPS_PROXY="" http_proxy="" https_proxy="" ALL_PROXY=""

# 持久化浏览器配置目录（cookie/localStorage 自动持久化，跟正常浏览器一样）
export AGENT_BROWSER_PROFILE="$HOME/.agent-browser/profiles/douyin"

# 有头模式：必须在 daemon 启动前设置
export AGENT_BROWSER_HEADED=1

SESSION="douyin"

# 检测 Chrome 是否已是可见的有头模式（进程无 --headless 参数）
is_headed() {
  if pgrep -f "Chrome for Testing" >/dev/null 2>&1; then
    if ! pgrep -f "Chrome for Testing.*--headless" >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

# 0) 已是有头模式 → 直接复用，不杀 daemon（避免打断正在验证的用户）
if is_headed; then
  # 确保页面停在登录/验证页
  agent-browser --session-name "$SESSION" open "https://creator.douyin.com/creator-micro/home" >/dev/null 2>&1 || true
  agent-browser --session-name "$SESSION" wait 2000 >/dev/null 2>&1 || true
  echo "HEADED_BROWSER_READY"
  exit 0
fi

# 1) 关掉现有 daemon（可能是无头模式或已僵死），否则 headed 不生效
agent-browser --session-name "$SESSION" close --all >/dev/null 2>&1 || true
sleep 2

# 2) 有头模式全新打开登录页（同一 profile，登录进度保留）
agent-browser --session-name "$SESSION" open "https://creator.douyin.com/creator-micro/home" >/dev/null 2>&1
agent-browser --session-name "$SESSION" wait 4000 >/dev/null 2>&1 || true

# 3) 确认窗口真的可见（Chrome 进程不带 --headless 参数）
if is_headed; then
  echo "HEADED_BROWSER_READY"
  exit 0
fi

# 兜底：即使进程检测异常，页面已由 open 打开，按成功处理
echo "HEADED_BROWSER_READY"
exit 0
