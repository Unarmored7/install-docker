# install-docker.sh

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell: Bash](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnubash&logoColor=white)](install-docker.sh)
[![Platform](https://img.shields.io/badge/Platform-Debian%20|%20Ubuntu-A81D33?logo=debian&logoColor=white)](#运行要求)

一个用于在 **Debian / Ubuntu** 上安装或升级 **Docker Engine + Compose v2** 的一键脚本。

遵循官方 [Docker apt 仓库安装流程](https://docs.docker.com/engine/install/debian/)，自动完成冲突包清理、GPG 密钥导入、软件源配置、Docker 安装以及服务启动。脚本会自动识别当前环境，区分**首次安装**与**升级**两种场景：

默认安装 **stable 通道中的最新版本**。

| 场景 | 行为 |
|------|------|
| **首次安装** | 执行完整 7 步流程：清理冲突包 → 配置官方源 → 安装 Docker |
| **升级** | 检测到官方源和密钥已就绪后，跳过前 6 步，仅 `apt-get update` + `apt-get install` |

---

## 快速开始

```bash
curl -fsSL https://raw.githubusercontent.com/Unarmored7/install-docker/main/install-docker.sh | bash
```

<details>
<summary>其他运行方式</summary>

使用 `curl`（未安装时会自动安装）：

```bash
command -v curl >/dev/null || apt-get install -y -qq curl
curl -fsSL https://raw.githubusercontent.com/Unarmored7/install-docker/main/install-docker.sh | bash
```

使用 `wget`：

```bash
wget -qO- https://raw.githubusercontent.com/Unarmored7/install-docker/main/install-docker.sh | bash
```

下载到本地后执行（非 root 时自动 sudo 提权）：

```bash
bash install-docker.sh
```

> **Note:** 非 root 用户通过管道执行时，请将 `bash` 替换为 `sudo bash`。

</details>

---

## 运行要求

| 项目 | 要求 |
|------|------|
| **发行版** | Debian 11+ / Ubuntu 20.04+ |
| **权限** | root（本地执行时可自动 sudo 提权） |
| **网络** | 能访问 `download.docker.com` |

---

## 安装流程

首次运行时，脚本依次执行以下 7 个步骤：

| # | 操作 |
|---|------|
| 1 | 移除冲突软件包（`docker.io`、`podman-docker` 等） |
| 2 | 清理遗留的 Docker apt 软件源和 GPG 密钥 |
| 3 | 更新 apt 软件包索引 |
| 4 | 安装前置依赖（`ca-certificates`、`curl`） |
| 5 | 导入 Docker 官方 GPG 密钥到 `/etc/apt/keyrings/` |
| 6 | 添加 Docker apt 软件源（Deb822 `.sources` 格式） |
| 7 | 安装 `docker-ce` `docker-ce-cli` `containerd.io` `docker-buildx-plugin` `docker-compose-plugin` |

安装完成后，脚本通过 systemd 启用并启动 Docker 守护进程，并输出版本摘要。

---

## 升级

直接重新运行即可：

```bash
curl -fsSL https://raw.githubusercontent.com/Unarmored7/install-docker/main/install-docker.sh | bash
```

脚本检测到 `/etc/apt/sources.list.d/docker.sources` 和 `/etc/apt/keyrings/docker.asc` 已就绪后，自动跳过步骤 1–6，仅执行 `apt-get update` + `apt-get install` 升级到最新版本。

完成后会输出版本对比（`fresh install` / `upgraded` / `unchanged`），一目了然。

---

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `DRY_RUN` | `0` | 设为 `1` 时仅打印将要执行的命令，不真正执行 |

```bash
DRY_RUN=1 bash install-docker.sh
```

---

## 安装后

允许普通用户免 `sudo` 使用 Docker：

```bash
sudo usermod -aG docker $USER
# 退出并重新登录，或执行：
newgrp docker
```

验证安装：

```bash
docker run hello-world
```

---

## 卸载

```bash
sudo apt-get purge -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras
sudo rm -rf /var/lib/docker /var/lib/containerd
sudo rm -f /etc/apt/sources.list.d/docker.sources /etc/apt/keyrings/docker.asc
```

---

## 许可证

[MIT](LICENSE)
