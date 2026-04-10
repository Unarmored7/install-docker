#!/usr/bin/env bash
#
# install-docker.sh
# =================
# 通过 Docker 官方 apt 软件源，在 Debian / Ubuntu 上安装
# Docker Engine 和 Compose v2。重复运行本脚本时，会保留官方
# docker-ce 系列包，并将其升级到仓库中的最新版本。
# 安装流程参考以下官方文档：
#   https://docs.docker.com/engine/install/debian/
#   https://docs.docker.com/engine/install/ubuntu/
#
# 用法：
#   curl -fsSL <raw-url> | bash
#   # 或先下载到本地后执行（非 root 时自动 sudo 提权）：
#   bash install-docker.sh
#
# 环境变量：
#   DRY_RUN=1   仅打印将要执行的命令，不真正执行。
#
# 首次安装流程（共 7 步）：
#   1. 移除其他安装渠道带来的冲突软件包（docker.io、podman-docker 等）
#   2. 清理遗留的 Docker apt 软件源和 GPG 密钥
#   3. 更新 apt 软件包索引
#   4. 安装前置依赖（ca-certificates、curl）
#   5. 将 Docker 官方 GPG 密钥导入 /etc/apt/keyrings/
#   6. 添加 Docker apt 软件源（Deb822 .sources 格式）
#   7. 安装 docker-ce、docker-ce-cli、containerd.io、
#      docker-buildx-plugin 和 docker-compose-plugin
#
# 升级流程（自动检测到官方 Docker 源已就绪时）：
#   脚本会跳过步骤 1–6，仅执行 apt-get update 和
#   apt-get install 来将已安装的包升级到最新版本。
#
# 安装完成后，脚本会通过 systemd 启用并启动 Docker 守护进程
# （如果系统支持），并输出安装前后的版本对比信息（全新安装 /
# 版本升级 / 版本未变）。
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
[[ -f /etc/os-release ]] || die "找不到 /etc/os-release，无法识别当前发行版。"
# shellcheck source=/dev/null
. /etc/os-release

if [[ "${ID:-}" != "debian" && "${ID:-}" != "ubuntu" ]]; then
  die "不支持当前发行版（ID=${ID:-unknown}），本脚本仅支持 Debian 和 Ubuntu。"
fi

# 2. 必须以 root 身份运行；若非 root 则尝试自动通过 sudo 提权。
if [[ "${EUID}" -ne 0 ]]; then
  if command -v sudo &>/dev/null; then
    if [[ "$0" != "bash" && "$0" != "-bash" && "$0" != "sh" && "$0" != "-sh" && -f "$0" ]]; then
      warn "当前非 root 用户，正在通过 sudo 重新执行 ..."
      exec sudo -E bash "$0" "$@"
    else
      die "通过管道执行时请使用：curl ... | sudo bash"
    fi
  elif command -v su &>/dev/null; then
    if [[ "$0" != "bash" && "$0" != "-bash" && "$0" != "sh" && "$0" != "-sh" && -f "$0" ]]; then
      warn "当前非 root 用户，正在通过 su 重新执行 ..."
      exec su -c "bash '$0'"
    else
      die "通过管道执行时请使用：curl ... | sudo bash"
    fi
  else
    die "请以 root 身份运行此脚本，或确保系统中可用 sudo / su。"
  fi
fi

# 3. 检测 CPU 架构（用于生成 apt 软件源条目）。
ARCH=$(dpkg --print-architecture 2>/dev/null || true)
[[ -n "${ARCH}" ]] || die "无法识别系统架构（dpkg --print-architecture）。"

# 4. 确定发行版代号（例如 bookworm、jammy）。
#    某些精简镜像中 VERSION_CODENAME 可能为空，因此回退到 lsb_release。
CODENAME="${VERSION_CODENAME:-}"
if [[ -z "${CODENAME}" ]]; then
  CODENAME=$(lsb_release -cs 2>/dev/null || true)
fi
[[ -n "${CODENAME}" ]] || die "无法确定发行版代号，请确认 /etc/os-release 信息完整。"

# ---------------------------------------------------------------------------
# 记录安装前的版本信息（用于安装后对比）
# ---------------------------------------------------------------------------
PRE_DOCKER=""
PRE_COMPOSE=""
PRE_BUILDX=""

if command -v docker &>/dev/null; then
  PRE_DOCKER=$(docker version --format '{{.Server.Version}}' 2>/dev/null || \
               docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || true)
  PRE_COMPOSE=$(docker compose version --short 2>/dev/null || true)
  PRE_BUILDX=$(docker buildx version 2>/dev/null | grep -oP 'v[\d.]+' || true)
fi

# ---------------------------------------------------------------------------
# 检测官方 Docker apt 软件源是否已就绪（由本脚本或按官方文档配置）。
# 条件：docker.sources 文件存在且指向 download.docker.com，
#       同时 GPG 密钥文件存在。满足时自动跳过源配置，直接升级。
# ---------------------------------------------------------------------------
DOCKER_URL="https://download.docker.com"
OFFICIAL_SOURCE="/etc/apt/sources.list.d/docker.sources"
OFFICIAL_KEY="/etc/apt/keyrings/docker.asc"
UPGRADE_MODE=0

if [[ -f "${OFFICIAL_SOURCE}" ]] \
   && grep -q 'download\.docker\.com' "${OFFICIAL_SOURCE}" 2>/dev/null \
   && [[ -f "${OFFICIAL_KEY}" ]]; then
  UPGRADE_MODE=1
  info "检测到官方 Docker apt 软件源，进入升级模式。"
fi

# ---------------------------------------------------------------------------
# 如果系统中已安装 Docker，则给出提示
# ---------------------------------------------------------------------------
if [[ -n "${PRE_DOCKER}" ]]; then
  warn "检测到已安装 Docker：${PRE_DOCKER}"
  if [[ "${UPGRADE_MODE}" -eq 1 ]]; then
    warn "将升级 Docker 相关软件包到当前仓库中的最新版本。"
  else
    warn "继续执行将重新配置 apt 软件源，并升级到当前仓库中的最新版本。"
  fi
  if [[ -t 0 ]]; then
    read -r -t 10 -p "按回车继续，或按 Ctrl+C 取消... " || true
    echo
  fi
fi

info "将安装 stable 通道中的最新版本。"

# ---------------------------------------------------------------------------
# 网络连通性检查
# ---------------------------------------------------------------------------
info "正在检查到 ${DOCKER_URL} 的网络连通性..."
if ! curl -fsSL --connect-timeout 10 --max-time 15 "${DOCKER_URL}" \
     -o /dev/null 2>/dev/null; then
  die "无法访问 ${DOCKER_URL}，请检查网络连接后重试。"
fi
ok "网络连通性正常。"

# ===========================================================================
# 安装步骤
# ===========================================================================
if [[ "${UPGRADE_MODE}" -eq 1 ]]; then
  STEPS=2
else
  STEPS=7
fi

STEP=0

if [[ "${UPGRADE_MODE}" -eq 0 ]]; then
  # -- 第 1 步：移除其他来源的冲突软件包 ------------------------------------
  STEP=$((STEP + 1))
  info "[${STEP}/${STEPS}] 正在移除其他安装来源的冲突软件包..."

  # 这些是 Docker 官方文档列出的潜在冲突软件包。
  # 不包含 docker-ce、docker-ce-cli、docker-compose-plugin 等官方仓库软件包，
  # 因此可重复运行本脚本用于升级。
  CONFLICT_PKGS="docker.io docker-compose docker-doc podman-docker containerd runc"
  FOUND=$(dpkg --get-selections ${CONFLICT_PKGS} 2>/dev/null | awk '{print $1}' || true)

  if [[ -n "${FOUND}" ]]; then
    info "将移除：${FOUND}"
    run apt-get remove -y ${FOUND} || true
  else
    ok "未发现冲突软件包。"
  fi

  # -- 第 2 步：清理旧的 Docker 软件源和密钥 ---------------------------------
  STEP=$((STEP + 1))
  info "[${STEP}/${STEPS}] 正在清理旧的 Docker 软件源和 GPG 密钥..."

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

  ok "旧的软件源已清理。"

  # -- 第 3 步：刷新软件包索引 ----------------------------------------------
  STEP=$((STEP + 1))
  info "[${STEP}/${STEPS}] 正在更新 apt 软件包索引..."
  run apt-get update -qq

  # -- 第 4 步：安装前置依赖 ------------------------------------------------
  STEP=$((STEP + 1))
  info "[${STEP}/${STEPS}] 正在安装前置依赖（ca-certificates、curl）..."
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl

  # -- 第 5 步：导入 Docker 官方 GPG 密钥 -----------------------------------
  STEP=$((STEP + 1))
  info "[${STEP}/${STEPS}] 正在导入 Docker GPG 密钥..."
  run install -m 0755 -d /etc/apt/keyrings
  run curl -fsSL "${DOCKER_URL}/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
  run chmod a+r /etc/apt/keyrings/docker.asc
  ok "GPG 密钥已导入：/etc/apt/keyrings/docker.asc"

  # -- 第 6 步：添加 Docker apt 软件源（Deb822 格式） -----------------------
  STEP=$((STEP + 1))
  info "[${STEP}/${STEPS}] 正在写入 Docker apt 软件源（Deb822 格式）..."
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
  ok "软件源已配置完成。"
fi

# -- 更新并安装 Docker Engine -----------------------------------------------
STEP=$((STEP + 1))
info "[${STEP}/${STEPS}] 正在更新 apt 软件包索引..."
run apt-get update -qq

STEP=$((STEP + 1))
info "[${STEP}/${STEPS}] 正在安装或升级 Docker Engine、CLI 和插件..."
run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
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
# 获取安装后的版本信息
# ---------------------------------------------------------------------------
POST_DOCKER=$(docker version --format '{{.Server.Version}}' 2>/dev/null || \
              docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo 'N/A')
POST_COMPOSE=$(docker compose version --short 2>/dev/null || echo 'N/A')
POST_BUILDX=$(docker buildx version 2>/dev/null | grep -oP 'v[\d.]+' || echo 'N/A')

# ---------------------------------------------------------------------------
# 版本变化描述辅助函数
# ---------------------------------------------------------------------------
version_diff() {
  local name="$1" pre="$2" post="$3"
  if [[ -z "${pre}" ]]; then
    printf '%-14s : %s（全新安装）\n' "${name}" "${post}"
  elif [[ "${pre}" == "${post}" ]]; then
    printf '%-14s : %s（版本未变）\n' "${name}" "${post}"
  else
    printf '%-14s : %s → %s（已升级）\n' "${name}" "${pre}" "${post}"
  fi
}

# ---------------------------------------------------------------------------
# 结果摘要
# ---------------------------------------------------------------------------
echo
echo "════════════════════════════════════════════════════════════════"
ok "Docker 安装完成！"
echo "────────────────────────────────────────────────────────────────"
info "$(version_diff 'Docker Engine' "${PRE_DOCKER}" "${POST_DOCKER}")"
info "$(version_diff 'Compose'       "${PRE_COMPOSE}" "${POST_COMPOSE}")"
info "$(version_diff 'Buildx'        "${PRE_BUILDX}"  "${POST_BUILDX}")"
echo "════════════════════════════════════════════════════════════════"
echo
echo "提示：如果希望普通用户无需 sudo 即可使用 Docker："
echo "  sudo usermod -aG docker \$USER"
echo "  # 然后退出并重新登录，或执行：newgrp docker"
echo
