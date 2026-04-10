#!/usr/bin/env bash
#
# install-docker.sh
# =================
# 通过 Docker 官方 apt 软件源，在 Debian / Ubuntu 上安装
# Docker Engine 和 Compose v2。安装流程参考以下官方文档：
#   https://docs.docker.com/engine/install/debian/
#   https://docs.docker.com/engine/install/ubuntu/
#
# 用法：
#   curl -fsSL <raw-url> | sudo bash
#   wget -qO- <raw-url> | sudo bash
#   # 或先下载到本地后执行：
#   sudo bash install-docker.sh
#
# 环境变量：
#   DRY_RUN=1   仅打印将要执行的命令，不真正执行。
#
# 本脚本执行的内容（共 7 步）：
#   1. 移除可能冲突的旧版软件包（docker.io、podman-docker 等）
#   2. 清理遗留的 Docker apt 软件源和 GPG 密钥
#   3. 更新 apt 软件包索引
#   4. 安装前置依赖（ca-certificates、curl）
#   5. 将 Docker 官方 GPG 密钥导入 /etc/apt/keyrings/
#   6. 添加 Docker apt 软件源（Deb822 .sources 格式）
#   7. 安装 docker-ce、docker-ce-cli、containerd.io、
#      docker-buildx-plugin 和 docker-compose-plugin
#
# 安装完成后，脚本会通过 systemd 启用并启动 Docker 守护进程
# （如果系统支持），并输出已安装组件的版本信息。
#
# 支持的发行版：Debian 11+、Ubuntu 20.04+
# 所需权限：      root（或通过 sudo 执行）
# 许可证：        MIT

set -euo pipefail

# ---------------------------------------------------------------------------
# 日志辅助函数：当 stdout 连接终端时使用彩色输出，否则使用普通文本。
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && command -v tput &>/dev/null \
  && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
  RED=$(tput setaf 1)  GREEN=$(tput setaf 2)  YELLOW=$(tput setaf 3)
  CYAN=$(tput setaf 6) BOLD=$(tput bold)       RESET=$(tput sgr0)
else
  RED=""  GREEN=""  YELLOW=""  CYAN=""  BOLD=""  RESET=""
fi

info() { echo "${CYAN}${BOLD}[INFO]${RESET}  $*"; }
ok()   { echo "${GREEN}${BOLD}[ OK ]${RESET}  $*"; }
warn() { echo "${YELLOW}${BOLD}[WARN]${RESET}  $*" >&2; }
err()  { echo "${RED}${BOLD}[ERR ]${RESET}  $*" >&2; }
die()  { err "$@"; exit 1; }

# ---------------------------------------------------------------------------
# DRY_RUN 包装器：当 DRY_RUN=1 时，仅打印命令而不执行。
# ---------------------------------------------------------------------------
DRY_RUN="${DRY_RUN:-0}"

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "${YELLOW}[DRY_RUN]${RESET} $*"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# 预检查
# ---------------------------------------------------------------------------

# 1. 必须运行在受支持的发行版上。
[[ -f /etc/os-release ]] || die "Cannot find /etc/os-release — unable to detect distribution."
# shellcheck source=/dev/null
. /etc/os-release

if [[ "${ID:-}" != "debian" && "${ID:-}" != "ubuntu" ]]; then
  die "Unsupported distribution (ID=${ID:-unknown}). This script supports Debian and Ubuntu only."
fi

# 2. 必须以 root 身份运行。
[[ "${EUID}" -eq 0 ]] || die "This script must be run as root.  Example: sudo bash $0"

# 3. 检测 CPU 架构（用于生成 apt 软件源条目）。
ARCH=$(dpkg --print-architecture 2>/dev/null || true)
[[ -n "${ARCH}" ]] || die "Failed to detect system architecture (dpkg --print-architecture)."

# 4. 确定发行版代号（例如 bookworm、jammy）。
#    某些精简镜像中 VERSION_CODENAME 可能为空，因此回退到 lsb_release。
CODENAME="${VERSION_CODENAME:-}"
if [[ -z "${CODENAME}" ]]; then
  CODENAME=$(lsb_release -cs 2>/dev/null || true)
fi
[[ -n "${CODENAME}" ]] || die "Cannot determine distribution codename. Ensure /etc/os-release is complete."

# ---------------------------------------------------------------------------
# 如果系统中已安装 Docker，则给出提示
# ---------------------------------------------------------------------------
if command -v docker &>/dev/null; then
  warn "Docker is already installed: $(docker --version 2>/dev/null || echo 'unknown')"
  warn "Continuing will clean old sources and reinstall the latest version."
  if [[ -t 0 ]]; then
    read -r -t 10 -p "Press Enter to continue, or Ctrl+C to abort... " || true
    echo
  fi
fi

# ---------------------------------------------------------------------------
# 网络连通性检查
# ---------------------------------------------------------------------------
DOCKER_URL="https://download.docker.com"

info "Verifying network connectivity to ${DOCKER_URL} ..."
if ! curl -fsSL --connect-timeout 10 --max-time 15 "${DOCKER_URL}" \
     -o /dev/null 2>/dev/null; then
  die "Cannot reach ${DOCKER_URL}. Check your network connection and try again."
fi
ok "Network OK."

# ===========================================================================
# 安装步骤
# ===========================================================================
STEPS=7

# -- 第 1 步：移除冲突的软件包 ----------------------------------------------
info "[1/${STEPS}] Removing conflicting legacy packages ..."

# 这些是 Docker 官方文档列出的潜在冲突软件包。
LEGACY_PKGS="docker.io docker-compose docker-doc podman-docker containerd runc"
FOUND=$(dpkg --get-selections ${LEGACY_PKGS} 2>/dev/null | awk '{print $1}' || true)

if [[ -n "${FOUND}" ]]; then
  info "Removing: ${FOUND}"
  run apt-get remove -y ${FOUND} || true
else
  ok "No conflicting packages found."
fi

# -- 第 2 步：清理旧的 Docker 软件源和密钥 -----------------------------------
info "[2/${STEPS}] Purging stale Docker apt sources and GPG keys ..."

run rm -f /etc/apt/sources.list.d/docker.list \
         /etc/apt/sources.list.d/docker-ce.list \
         /etc/apt/sources.list.d/docker*.sources \
         2>/dev/null || true

# 同时移除主 sources.list 中残留的 Docker 条目，并保留备份。
if [[ -f /etc/apt/sources.list ]]; then
  run sed -i.bak '/download\.docker\.com/d' /etc/apt/sources.list 2>/dev/null || true
fi

run rm -f /etc/apt/keyrings/docker.gpg \
         /etc/apt/keyrings/docker.asc \
         2>/dev/null || true

ok "Old sources cleaned."

# -- 第 3 步：刷新软件包索引 ------------------------------------------------
info "[3/${STEPS}] Updating apt package index ..."
run apt-get update -qq

# -- 第 4 步：安装前置依赖 --------------------------------------------------
info "[4/${STEPS}] Installing prerequisites (ca-certificates, curl) ..."
run apt-get install -y -qq ca-certificates curl

# -- 第 5 步：导入 Docker 官方 GPG 密钥 -------------------------------------
info "[5/${STEPS}] Importing Docker GPG key ..."
run install -m 0755 -d /etc/apt/keyrings
run curl -fsSL "${DOCKER_URL}/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
run chmod a+r /etc/apt/keyrings/docker.asc
ok "GPG key imported: /etc/apt/keyrings/docker.asc"

# -- 第 6 步：添加 Docker apt 软件源（Deb822 格式） -------------------------
info "[6/${STEPS}] Writing Docker apt source (Deb822 format) ..."
if [[ "${DRY_RUN}" == "1" ]]; then
  echo "${YELLOW}[DRY_RUN]${RESET} write /etc/apt/sources.list.d/docker.sources"
else
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: ${DOCKER_URL}/linux/${ID}
Suites: ${CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF
fi
ok "Repository configured."

# -- 第 7 步：安装 Docker Engine --------------------------------------------
info "[7/${STEPS}] Installing Docker Engine, CLI, and plugins ..."
run apt-get update -qq
run apt-get install -y -qq \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

# ---------------------------------------------------------------------------
# 安装后操作：启用并启动 Docker 守护进程
# ---------------------------------------------------------------------------
if command -v systemctl &>/dev/null && [[ "${DRY_RUN}" != "1" ]]; then
  systemctl enable --now docker   &>/dev/null || true
  systemctl enable --now containerd &>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 结果摘要
# ---------------------------------------------------------------------------
echo
echo "════════════════════════════════════════════════════════════════"
ok "Docker installation complete!"
echo "────────────────────────────────────────────────────────────────"
info "Docker Engine : $(docker --version 2>/dev/null || echo 'N/A')"
info "Compose       : $(docker compose version 2>/dev/null || echo 'N/A')"
info "Buildx        : $(docker buildx version 2>/dev/null || echo 'N/A')"
echo "════════════════════════════════════════════════════════════════"
echo
echo "Tip: to allow a non-root user to run Docker without sudo:"
echo "  sudo usermod -aG docker \$USER"
echo "  # then log out and back in, or run:  newgrp docker"
echo
