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
#   curl -fsSL <raw-url> -o install-docker.sh && bash install-docker.sh
#   # 本地执行时，非 root 用户会自动尝试通过 sudo 提权。
#
# 环境变量：
#   DRY_RUN=1            仅打印将要执行的命令，不真正执行。
#   DOCKER_VERIFY_HOST   安装后用于健康检查的 daemon 地址；
#                        默认 unix:///var/run/docker.sock。
#
# 首次安装流程（共 8 步）：
#   1. 识别需要替换的冲突软件包（docker.io、podman-docker 等）
#   2. 备份并停用明确的旧 Docker apt 软件源
#   3. 原子安装已验证的 Docker GPG 密钥
#   4. 原子写入 Docker apt 软件源（Deb822 .sources 格式）
#   5. 仅刷新 Docker 官方软件包索引
#   6. 在修改现有运行时前下载完整安装事务
#   7. 在单次 apt 事务中替换冲突包并安装 Docker
#   8. 启动并验证 Docker daemon
#
# 升级流程（自动检测到 docker-ce 已安装时）：
#   脚本不会提前卸载冲突包；安全刷新官方密钥和软件源后，
#   在单次 apt 事务中将 Docker 相关包升级到最新版本。
#
# 安装完成后，脚本会通过 systemd 启用并启动 Docker 守护进程
# （如果系统支持），并输出安装前后的版本对比信息（全新安装 /
# 版本升级 / 版本未变）。
#
# 支持的发行版：Debian 11/12/13、Ubuntu 22.04/24.04/26.04
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
DOCKER_URL="https://download.docker.com"
OFFICIAL_SOURCE="/etc/apt/sources.list.d/docker.sources"
OFFICIAL_KEY="/etc/apt/keyrings/docker.asc"
LEGACY_DOCKER_LIST="/etc/apt/sources.list.d/docker.list"
LEGACY_DOCKER_CE_LIST="/etc/apt/sources.list.d/docker-ce.list"
MAIN_SOURCES_LIST="/etc/apt/sources.list"
DOCKER_VERIFY_HOST="${DOCKER_VERIFY_HOST:-unix:///var/run/docker.sock}"
DOCKER_KEY_TEMP=""
DOCKER_KEY_TARGET_TEMP=""
DOCKER_SOURCE_TEMP=""
SOURCE_FILTER_TEMP=""
APT_PREFLIGHT_DIR=""
APT_ARCHIVE_DIR=""
APT_ARCHIVE_DISPLAY=""
REPO_BACKUP_DIR=""
REPO_TRANSACTION_ACTIVE=0
OFFICIAL_KEY_EXISTED=0
OFFICIAL_SOURCE_EXISTED=0
LEGACY_DOCKER_LIST_BACKED_UP=0
LEGACY_DOCKER_CE_LIST_BACKED_UP=0
MAIN_SOURCES_BACKED_UP=0

DOCKER_PACKAGES=(
  docker-ce
  docker-ce-cli
  containerd.io
  docker-buildx-plugin
  docker-compose-plugin
)
DOCKER_PACKAGE_SPECS=()

CONFLICT_PACKAGES=(
  docker.io
  docker-compose
  docker-compose-v2
  docker-doc
  docker-buildx
  podman-docker
  containerd
  runc
)

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "${YELLOW}[DRY_RUN]${RESET} $*"
  else
    "$@"
  fi
}

ensure_download_tool() {
  local context="$1"

  if command -v curl &>/dev/null || command -v wget &>/dev/null; then
    return 0
  fi

  info "[${context}] 未找到 curl/wget，正在安装 curl..."
  run apt-get update -qq
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl

  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi

  command -v curl &>/dev/null || command -v wget &>/dev/null \
    || die "[${context}] 无法找到 curl/wget，也未能自动安装 curl。"
}

download_to_file() {
  local url="$1" output="$2"

  if command -v curl &>/dev/null; then
    run curl -fsSL "${url}" -o "${output}"
  elif command -v wget &>/dev/null; then
    run wget -qO "${output}" "${url}"
  elif [[ "${DRY_RUN}" == "1" ]]; then
    echo "${YELLOW}[DRY_RUN]${RESET} download ${url} to ${output}"
  else
    return 127
  fi
}

cleanup_temp_files() {
  if [[ -n "${DOCKER_KEY_TEMP}" && -e "${DOCKER_KEY_TEMP}" ]]; then
    rm -f -- "${DOCKER_KEY_TEMP}"
  fi
  if [[ -n "${DOCKER_KEY_TARGET_TEMP}" && -e "${DOCKER_KEY_TARGET_TEMP}" ]]; then
    rm -f -- "${DOCKER_KEY_TARGET_TEMP}"
  fi
  if [[ -n "${DOCKER_SOURCE_TEMP}" && -e "${DOCKER_SOURCE_TEMP}" ]]; then
    rm -f -- "${DOCKER_SOURCE_TEMP}"
  fi
  if [[ -n "${SOURCE_FILTER_TEMP}" && -e "${SOURCE_FILTER_TEMP}" ]]; then
    rm -f -- "${SOURCE_FILTER_TEMP}"
  fi
  if [[ "${DRY_RUN}" != "1" && -n "${APT_PREFLIGHT_DIR}" \
        && "${APT_PREFLIGHT_DIR}" == /tmp/install-docker-preflight.* ]]; then
    rm -rf -- "${APT_PREFLIGHT_DIR}"
  fi
  if [[ "${DRY_RUN}" != "1" && -n "${APT_ARCHIVE_DIR}" \
        && "${APT_ARCHIVE_DIR}" == /var/cache/apt/install-docker.* ]]; then
    rm -rf -- "${APT_ARCHIVE_DIR}"
  fi
  if [[ "${DRY_RUN}" != "1" && -n "${REPO_BACKUP_DIR}" \
        && "${REPO_BACKUP_DIR}" == /var/tmp/install-docker-repo.* ]]; then
    rm -rf -- "${REPO_BACKUP_DIR}"
  fi
}

restore_backup() {
  local backup_name="$1" target="$2" existed="$3"

  if [[ "${existed}" -eq 1 ]]; then
    mv -f -- "${REPO_BACKUP_DIR}/${backup_name}" "${target}"
  else
    rm -f -- "${target}"
  fi
}

rollback_repository_changes() {
  local rollback_failed=0

  [[ "${REPO_TRANSACTION_ACTIVE}" -eq 1 ]] || return 0

  warn "安装未完成，正在恢复原有 Docker apt 配置..."
  restore_backup official-key "${OFFICIAL_KEY}" "${OFFICIAL_KEY_EXISTED}" \
    || rollback_failed=1
  restore_backup official-source "${OFFICIAL_SOURCE}" "${OFFICIAL_SOURCE_EXISTED}" \
    || rollback_failed=1

  if [[ "${LEGACY_DOCKER_LIST_BACKED_UP}" -eq 1 ]]; then
    mv -f -- "${REPO_BACKUP_DIR}/docker.list" \
      "${LEGACY_DOCKER_LIST}" || rollback_failed=1
  fi
  if [[ "${LEGACY_DOCKER_CE_LIST_BACKED_UP}" -eq 1 ]]; then
    mv -f -- "${REPO_BACKUP_DIR}/docker-ce.list" \
      "${LEGACY_DOCKER_CE_LIST}" || rollback_failed=1
  fi
  if [[ "${MAIN_SOURCES_BACKED_UP}" -eq 1 ]]; then
    mv -f -- "${REPO_BACKUP_DIR}/sources.list" "${MAIN_SOURCES_LIST}" \
      || rollback_failed=1
  fi

  REPO_TRANSACTION_ACTIVE=0
  if [[ "${rollback_failed}" -eq 0 ]]; then
    ok "原有 Docker apt 配置已恢复。"
  else
    warn "自动恢复不完整；备份保留在 ${REPO_BACKUP_DIR}，请手动检查。"
    REPO_BACKUP_DIR=""
    return 1
  fi
}

on_exit() {
  local exit_status=$?

  trap - EXIT
  set +e
  if [[ "${REPO_TRANSACTION_ACTIVE}" -eq 1 ]]; then
    [[ "${exit_status}" -ne 0 ]] || exit_status=1
    rollback_repository_changes
  fi
  cleanup_temp_files
  exit "${exit_status}"
}

trap on_exit EXIT

package_is_installed() {
  local package="$1"
  local status

  status=$(dpkg-query -W -f='${db:Status-Abbrev}' "${package}" 2>/dev/null || true)
  [[ "${status}" == ii* ]]
}

validate_platform() {
  local platform="${ID}:${VERSION_ID:-}:${CODENAME}"
  local supported_arches

  case "${platform}" in
    debian:11:bullseye|debian:12:bookworm|debian:13:trixie)
      supported_arches="amd64 armhf arm64 ppc64el"
      ;;
    ubuntu:22.04:jammy|ubuntu:24.04:noble|ubuntu:26.04:resolute)
      supported_arches="amd64 armhf arm64 ppc64el s390x"
      ;;
    *)
      die "不支持当前系统（${platform}）。支持 Debian 11/12/13 和 Ubuntu 22.04/24.04/26.04。"
      ;;
  esac

  case " ${supported_arches} " in
    *" ${ARCH} "*) ;;
    *) die "当前架构 ${ARCH} 不在 ${ID} ${VERSION_ID} 的 Docker 支持列表中。" ;;
  esac
}

prepare_docker_key() {
  local key_url="$1"
  local begin_count end_count first_line last_line

  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "${YELLOW}[DRY_RUN]${RESET} download ${key_url} and verify its repository signature"
    return 0
  fi

  DOCKER_KEY_TEMP=$(mktemp /tmp/install-docker-key.XXXXXX)
  download_to_file "${key_url}" "${DOCKER_KEY_TEMP}"
  [[ -s "${DOCKER_KEY_TEMP}" ]] \
    || die "Docker GPG 密钥下载结果为空。"
  chmod 0644 "${DOCKER_KEY_TEMP}"

  begin_count=$(grep -c '^-----BEGIN PGP PUBLIC KEY BLOCK-----$' \
    "${DOCKER_KEY_TEMP}" || true)
  end_count=$(grep -c '^-----END PGP PUBLIC KEY BLOCK-----$' \
    "${DOCKER_KEY_TEMP}" || true)
  first_line=$(awk 'NF { print; exit }' "${DOCKER_KEY_TEMP}")
  last_line=$(awk 'NF { line=$0 } END { print line }' "${DOCKER_KEY_TEMP}")

  [[ "${begin_count}" -eq 1 && "${end_count}" -eq 1 \
      && "${first_line}" == "-----BEGIN PGP PUBLIC KEY BLOCK-----" \
      && "${last_line}" == "-----END PGP PUBLIC KEY BLOCK-----" ]] \
    || die "Docker GPG 密钥的 ASCII Armor 格式无效。"
}

validate_docker_repository() {
  local preflight_source candidate package policy_output madison_output
  local apt_options

  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "${YELLOW}[DRY_RUN]${RESET} authenticate Docker InRelease and verify package candidates"
    DOCKER_PACKAGE_SPECS=("${DOCKER_PACKAGES[@]}")
    return 0
  fi

  APT_PREFLIGHT_DIR=$(mktemp -d /tmp/install-docker-preflight.XXXXXX)
  preflight_source="${APT_PREFLIGHT_DIR}/docker.sources"
  mkdir -p "${APT_PREFLIGHT_DIR}/lists/partial"
  chmod 0755 "${APT_PREFLIGHT_DIR}" \
    "${APT_PREFLIGHT_DIR}/lists" \
    "${APT_PREFLIGHT_DIR}/lists/partial"
  if id -u _apt &>/dev/null; then
    chown _apt "${APT_PREFLIGHT_DIR}/lists/partial"
    chmod 0700 "${APT_PREFLIGHT_DIR}/lists/partial"
  fi

  cat > "${preflight_source}" <<EOF
Types: deb
URIs: ${DOCKER_REPO_URL}
Suites: ${CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: ${DOCKER_KEY_TEMP}
EOF
  chmod 0644 "${preflight_source}"

  apt_options=(
    -o "Dir::Etc::sourcelist=${preflight_source}"
    -o "Dir::Etc::sourceparts=-"
    -o "Dir::State::lists=${APT_PREFLIGHT_DIR}/lists/"
    -o "Dir::Cache::pkgcache="
    -o "Dir::Cache::srcpkgcache="
    -o "APT::Get::List-Cleanup=0"
  )

  apt-get "${apt_options[@]}" update -qq \
    || die "Docker 仓库签名验证失败，未修改现有 Docker 安装。"

  DOCKER_PACKAGE_SPECS=()
  for package in "${DOCKER_PACKAGES[@]}"; do
    policy_output=$(LC_ALL=C apt-cache "${apt_options[@]}" policy "${package}")
    candidate=$(awk '/^[[:space:]]*Candidate:/ { print $2; exit }' \
      <<< "${policy_output}" || true)
    [[ -n "${candidate}" && "${candidate}" != "(none)" ]] \
      || die "Docker 仓库未提供 ${package}（${ID}/${CODENAME}/${ARCH}）。"
    madison_output=$(LC_ALL=C apt-cache "${apt_options[@]}" madison "${package}" \
      || true)
    awk -F '|' -v expected="${candidate}" -v repo="${DOCKER_REPO_URL}" '
      {
        version=$2
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", version)
        if (version == expected && index($3, repo)) found=1
      }
      END { exit(found ? 0 : 1) }
    ' <<< "${madison_output}" \
      || die "${package} 的候选版本并非来自 Docker 官方仓库。"
    DOCKER_PACKAGE_SPECS+=("${package}=${candidate}")
  done

  rm -rf -- "${APT_PREFLIGHT_DIR}"
  APT_PREFLIGHT_DIR=""
}

source_references_official_docker() {
  local source_file="$1"

  [[ -f "${source_file}" ]] \
    && grep -Eq 'download\.docker\.com/linux/(debian|ubuntu)' "${source_file}"
}

filter_official_docker_lines() {
  local source_file="$1"

  SOURCE_FILTER_TEMP=$(mktemp "${source_file}.install-docker.XXXXXX")
  cp -p -- "${source_file}" "${SOURCE_FILTER_TEMP}"
  sed '/download\.docker\.com\/linux\/\(debian\|ubuntu\)/d' \
    "${source_file}" > "${SOURCE_FILTER_TEMP}"
  mv -f -- "${SOURCE_FILTER_TEMP}" "${source_file}"
  SOURCE_FILTER_TEMP=""
}

begin_repository_transaction() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "${YELLOW}[DRY_RUN]${RESET} back up and disable explicit legacy Docker apt entries"
    return 0
  fi

  for target in "${OFFICIAL_KEY}" "${OFFICIAL_SOURCE}"; do
    if [[ -L "${target}" || ( -e "${target}" && ! -f "${target}" ) ]]; then
      die "${target} 不是普通文件，拒绝覆盖。"
    fi
  done
  for target in \
    "${LEGACY_DOCKER_LIST}" \
    "${LEGACY_DOCKER_CE_LIST}" \
    "${MAIN_SOURCES_LIST}"; do
    if [[ -L "${target}" ]]; then
      die "${target} 是符号链接，拒绝修改。"
    fi
  done

  REPO_BACKUP_DIR=$(mktemp -d /var/tmp/install-docker-repo.XXXXXX)
  chmod 0700 "${REPO_BACKUP_DIR}"

  if [[ -f "${OFFICIAL_KEY}" ]]; then
    cp -a -- "${OFFICIAL_KEY}" "${REPO_BACKUP_DIR}/official-key"
    OFFICIAL_KEY_EXISTED=1
  fi
  if [[ -f "${OFFICIAL_SOURCE}" ]]; then
    cp -a -- "${OFFICIAL_SOURCE}" "${REPO_BACKUP_DIR}/official-source"
    OFFICIAL_SOURCE_EXISTED=1
  fi
  if source_references_official_docker "${LEGACY_DOCKER_LIST}"; then
    cp -a -- "${LEGACY_DOCKER_LIST}" "${REPO_BACKUP_DIR}/docker.list"
    LEGACY_DOCKER_LIST_BACKED_UP=1
  fi
  if source_references_official_docker "${LEGACY_DOCKER_CE_LIST}"; then
    cp -a -- "${LEGACY_DOCKER_CE_LIST}" "${REPO_BACKUP_DIR}/docker-ce.list"
    LEGACY_DOCKER_CE_LIST_BACKED_UP=1
  fi
  if source_references_official_docker "${MAIN_SOURCES_LIST}"; then
    cp -a -- "${MAIN_SOURCES_LIST}" "${REPO_BACKUP_DIR}/sources.list"
    MAIN_SOURCES_BACKED_UP=1
  fi

  REPO_TRANSACTION_ACTIVE=1

  if [[ "${LEGACY_DOCKER_LIST_BACKED_UP}" -eq 1 ]]; then
    filter_official_docker_lines "${LEGACY_DOCKER_LIST}"
  fi
  if [[ "${LEGACY_DOCKER_CE_LIST_BACKED_UP}" -eq 1 ]]; then
    filter_official_docker_lines "${LEGACY_DOCKER_CE_LIST}"
  fi
  if [[ "${MAIN_SOURCES_BACKED_UP}" -eq 1 ]]; then
    filter_official_docker_lines "${MAIN_SOURCES_LIST}"
  fi
}

commit_repository_transaction() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi

  REPO_TRANSACTION_ACTIVE=0
  rm -rf -- "${REPO_BACKUP_DIR}"
  REPO_BACKUP_DIR=""
}

install_prepared_docker_key() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "${YELLOW}[DRY_RUN]${RESET} install validated Docker GPG key to ${OFFICIAL_KEY}"
    return 0
  fi

  DOCKER_KEY_TARGET_TEMP=$(mktemp "${OFFICIAL_KEY}.install-docker.XXXXXX")
  install -m 0644 "${DOCKER_KEY_TEMP}" "${DOCKER_KEY_TARGET_TEMP}"
  mv -f -- "${DOCKER_KEY_TARGET_TEMP}" "${OFFICIAL_KEY}"
  DOCKER_KEY_TARGET_TEMP=""
}

write_docker_source() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "${YELLOW}[DRY_RUN]${RESET} write ${OFFICIAL_SOURCE} for ${ID}/${CODENAME}/${ARCH}"
    return 0
  fi

  DOCKER_SOURCE_TEMP=$(mktemp "${OFFICIAL_SOURCE}.install-docker.XXXXXX")
  cat > "${DOCKER_SOURCE_TEMP}" <<EOF
Types: deb
URIs: ${DOCKER_URL}/linux/${ID}
Suites: ${CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: ${OFFICIAL_KEY}
EOF
  chmod 0644 "${DOCKER_SOURCE_TEMP}"
  mv -f -- "${DOCKER_SOURCE_TEMP}" "${OFFICIAL_SOURCE}"
  DOCKER_SOURCE_TEMP=""
}

update_docker_package_index() {
  run apt-get \
    -o "Dir::Etc::sourcelist=${OFFICIAL_SOURCE}" \
    -o "Dir::Etc::sourceparts=-" \
    -o "APT::Get::List-Cleanup=0" \
    update -qq
}

prepare_apt_archive_cache() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    APT_ARCHIVE_DISPLAY="/var/cache/apt/install-docker.<temporary>"
    echo "${YELLOW}[DRY_RUN]${RESET} create isolated apt archive cache"
    return 0
  fi

  APT_ARCHIVE_DIR=$(mktemp -d /var/cache/apt/install-docker.XXXXXX)
  APT_ARCHIVE_DISPLAY="${APT_ARCHIVE_DIR}"
  mkdir -p "${APT_ARCHIVE_DIR}/partial"
  chmod 0755 "${APT_ARCHIVE_DIR}"
  if id -u _apt &>/dev/null; then
    chown _apt "${APT_ARCHIVE_DIR}/partial"
    chmod 0700 "${APT_ARCHIVE_DIR}/partial"
  else
    chmod 0755 "${APT_ARCHIVE_DIR}/partial"
  fi
}

verify_docker_daemon() {
  local attempt

  for ((attempt = 1; attempt <= 10; attempt++)); do
    if timeout 3 docker --host "${DOCKER_VERIFY_HOST}" info &>/dev/null; then
      return 0
    fi
    sleep 1
  done

  return 1
}

start_and_verify_docker() {
  if [[ "${DOCKER_VERIFY_HOST}" != "unix:///var/run/docker.sock" ]]; then
    info "使用自定义 daemon 地址，跳过本机 docker.service 启动。"
  elif command -v systemctl &>/dev/null \
    && timeout 10 systemctl show docker.service &>/dev/null; then
    timeout 60 systemctl enable --now containerd.service docker.service \
      || die "Docker/containerd systemd 服务启动失败。"
    timeout 10 systemctl is-active --quiet docker.service \
      || die "docker.service 未进入 active 状态。"
  elif command -v service &>/dev/null; then
    timeout 60 service docker start || die "Docker 服务启动失败。"
  else
    warn "未找到可用的 systemd/SysV 服务管理器，将直接检查 Docker daemon。"
  fi

  verify_docker_daemon \
    || die "Docker 软件包已安装，但无法连接 daemon（${DOCKER_VERIFY_HOST}）。"
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
      exec sudo \
        DRY_RUN="${DRY_RUN}" \
        DOCKER_VERIFY_HOST="${DOCKER_VERIFY_HOST}" \
        bash "$0" "$@"
    else
      die "请先将脚本下载到本地，再使用 sudo bash install-docker.sh 执行。"
    fi
  else
    die "未找到 sudo；请先切换为 root 用户，再重新执行此脚本。"
  fi
fi

# 3. 检查后续预校验和安装所需的系统命令。
for required_command in apt-get apt-cache dpkg dpkg-query timeout; do
  command -v "${required_command}" &>/dev/null \
    || die "缺少必需命令：${required_command}。"
done

# 4. 检测 CPU 架构（用于生成 apt 软件源条目）。
ARCH=$(dpkg --print-architecture 2>/dev/null || true)
[[ -n "${ARCH}" ]] || die "无法识别系统架构（dpkg --print-architecture）。"

# 5. 确定发行版代号（例如 bookworm、jammy）。
#    Ubuntu 官方流程优先使用 UBUNTU_CODENAME。
if [[ "${ID}" == "ubuntu" ]]; then
  CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
else
  CODENAME="${VERSION_CODENAME:-}"
fi
if [[ -z "${CODENAME}" ]]; then
  CODENAME=$(lsb_release -cs 2>/dev/null || true)
fi
[[ -n "${CODENAME}" ]] || die "无法确定发行版代号，请确认 /etc/os-release 信息完整。"

# 6. 在任何卸载或源修改前，校验版本、代号和架构。
validate_platform

# ---------------------------------------------------------------------------
# 记录安装前的版本信息（用于安装后对比）
# ---------------------------------------------------------------------------
PRE_DOCKER=""
PRE_COMPOSE=""
PRE_BUILDX=""

if command -v docker &>/dev/null; then
  PRE_DOCKER=$(timeout 3 docker --host "${DOCKER_VERIFY_HOST}" version \
                 --format '{{.Server.Version}}' 2>/dev/null || \
               timeout 3 docker --version 2>/dev/null \
                 | grep -oP '\d+\.\d+\.\d+' || true)
  PRE_COMPOSE=$(timeout 3 docker compose version --short 2>/dev/null || true)
  PRE_BUILDX=$(timeout 3 docker buildx version 2>/dev/null \
    | grep -oP 'v[\d.]+' || true)
fi

# ---------------------------------------------------------------------------
# 升级模式只根据 docker-ce 是否已安装判定。
# apt 源和密钥无论首次安装还是升级都会重新刷新，
# 避免将注释、禁用或已损坏的源误判为“已就绪”。
# ---------------------------------------------------------------------------
UPGRADE_MODE=0

if package_is_installed docker-ce; then
  UPGRADE_MODE=1
  info "检测到已安装 docker-ce，进入升级模式。"
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
# 在任何 apt 配置或软件包变更前验证仓库签名和候选包
# ---------------------------------------------------------------------------
ensure_download_tool "预检查"
DOCKER_REPO_URL="${DOCKER_URL}/linux/${ID}"
DOCKER_KEY_URL="${DOCKER_REPO_URL}/gpg"

info "正在预检查 ${ID}/${CODENAME}/${ARCH} 的 Docker 官方仓库..."
prepare_docker_key "${DOCKER_KEY_URL}"
validate_docker_repository
ok "Docker 官方仓库和 GPG 密钥预检查通过。"

# ===========================================================================
# 安装步骤
# ===========================================================================
STEPS=8
STEP=0
FOUND_CONFLICTS=()
APT_TRANSACTION_ARGS=(ca-certificates curl "${DOCKER_PACKAGE_SPECS[@]}")

# -- 第 1 步：识别需要在最终 apt 事务中替换的冲突软件包 ----------------------
STEP=$((STEP + 1))
info "[${STEP}/${STEPS}] 正在检查其他安装来源的冲突软件包..."

for package in "${CONFLICT_PACKAGES[@]}"; do
  if package_is_installed "${package}"; then
    FOUND_CONFLICTS+=("${package}")
    APT_TRANSACTION_ARGS+=("${package}-")
  fi
done

if (( ${#FOUND_CONFLICTS[@]} > 0 )); then
  info "将在最终 apt 事务中替换：${FOUND_CONFLICTS[*]}"
else
  ok "未发现冲突软件包。"
fi

# -- 第 2 步：备份并停用明确的旧 Docker 软件源 ------------------------------
STEP=$((STEP + 1))
info "[${STEP}/${STEPS}] 正在备份并停用明确的旧 Docker apt 条目..."
run install -m 0755 -d /etc/apt/keyrings /etc/apt/sources.list.d
begin_repository_transaction
ok "旧配置已备份；若安装失败将自动恢复。"

# -- 第 3 步：安装已通过仓库签名验证的 Docker GPG 密钥 -----------------------
STEP=$((STEP + 1))
info "[${STEP}/${STEPS}] 正在原子安装 Docker GPG 密钥..."
install_prepared_docker_key
ok "GPG 密钥已安装：${OFFICIAL_KEY}"

# -- 第 4 步：写入 Docker apt 软件源（Deb822 格式） --------------------------
STEP=$((STEP + 1))
info "[${STEP}/${STEPS}] 正在原子写入 Docker apt 软件源..."
write_docker_source
ok "软件源已配置完成。"

# -- 第 5 步：仅更新 Docker 官方软件包索引 -----------------------------------
STEP=$((STEP + 1))
info "[${STEP}/${STEPS}] 正在更新 Docker apt 软件包索引..."
update_docker_package_index

# -- 第 6 步：先下载完整 apt 事务，避免下载失败后旧运行时已被移除 ------------
STEP=$((STEP + 1))
info "[${STEP}/${STEPS}] 正在预下载完整安装事务..."
prepare_apt_archive_cache
run env DEBIAN_FRONTEND=noninteractive apt-get \
  -o "Dir::Cache::archives=${APT_ARCHIVE_DISPLAY}/" \
  --download-only install -y -qq "${APT_TRANSACTION_ARGS[@]}"

# -- 第 7 步：在单次 apt 事务中替换冲突包并安装 Docker -----------------------
STEP=$((STEP + 1))
info "[${STEP}/${STEPS}] 正在安装或升级 Docker Engine、CLI 和插件..."
run env DEBIAN_FRONTEND=noninteractive apt-get \
  -o "Dir::Cache::archives=${APT_ARCHIVE_DISPLAY}/" \
  --no-download install -y -qq "${APT_TRANSACTION_ARGS[@]}"

# ---------------------------------------------------------------------------
# 安装后操作：启用并启动 Docker 守护进程
# ---------------------------------------------------------------------------
STEP=$((STEP + 1))
info "[${STEP}/${STEPS}] 正在启动并验证 Docker daemon..."

if [[ "${DRY_RUN}" == "1" ]]; then
  echo
  echo "════════════════════════════════════════════════════════════════"
  ok "Docker 安装预览完成"
  warn "当前为 DRY_RUN 模式，未修改系统，也未启动 Docker daemon。"
  echo "════════════════════════════════════════════════════════════════"
  exit 0
fi

start_and_verify_docker
commit_repository_transaction

# ---------------------------------------------------------------------------
# 获取安装后的版本信息
# ---------------------------------------------------------------------------
POST_DOCKER=$(timeout 5 docker --host "${DOCKER_VERIFY_HOST}" version \
  --format '{{.Server.Version}}')
POST_COMPOSE=$(timeout 3 docker compose version --short 2>/dev/null || echo 'N/A')
POST_BUILDX=$(timeout 3 docker buildx version 2>/dev/null \
  | grep -oP 'v[\d.]+' || echo 'N/A')

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
