# install-docker.sh

一个用于在 **Debian / Ubuntu** 上安装或升级 **Docker Engine + Compose v2** 的一键 Shell 脚本。

脚本遵循官方的 [Docker apt 仓库安装流程](https://docs.docker.com/engine/install/debian/)，自动完成 GPG 密钥导入、软件源配置、依赖安装以及 Docker 服务启动。若系统已经通过 Docker 官方 apt 仓库安装过 Docker，重复运行本脚本即可继续升级 Docker 和 Docker Compose。

脚本会自动区分两种场景：

| 场景 | 行为 |
|------|------|
| 首次安装 | 执行完整的 7 个步骤：清理冲突包、配置官方源、安装 Docker |
| 升级已有官方安装 | 检测到 `/etc/apt/sources.list.d/docker.sources` 和 `/etc/apt/keyrings/docker.asc` 后，跳过步骤 1-6，仅执行 `apt-get update` 和 `apt-get install` |

## 快速开始

以 root 身份直接运行：

```bash
curl -fsSL https://raw.githubusercontent.com/Unarmored7/install-docker/main/install-docker.sh | bash
```

以普通用户通过 `sudo` 运行：

```bash
curl -fsSL https://raw.githubusercontent.com/Unarmored7/install-docker/main/install-docker.sh | sudo bash
```

如果你已经先把脚本下载到本地，那么普通用户也可以直接执行：

```bash
bash install-docker.sh
```

脚本会检测当前不是 root 用户，并自动通过 `sudo` 重新执行。

## 运行要求

| 项目 | 要求 |
|------|------|
| 发行版 | Debian 11+ / Ubuntu 20.04+ |
| 权限 | root 或 `sudo` |
| 网络 | 能访问 `download.docker.com` |

## 首次安装会做什么

| 步骤 | 操作 |
|------|------|
| 1 | 移除其他安装渠道带来的冲突软件包，如 `docker.io`、`podman-docker` 等 |
| 2 | 清理遗留的 Docker apt 软件源和 GPG 密钥 |
| 3 | 更新 apt 软件包索引 |
| 4 | 安装前置依赖 `ca-certificates` 和 `curl` |
| 5 | 将 Docker 官方 GPG 密钥导入 `/etc/apt/keyrings/` |
| 6 | 添加 Docker apt 软件源（Deb822 `.sources` 格式） |
| 7 | 安装 `docker-ce`、`docker-ce-cli`、`containerd.io`、`docker-buildx-plugin`、`docker-compose-plugin` |

安装完成后，脚本会通过 systemd 启用并启动 Docker 守护进程，并输出 Docker Engine、Compose、Buildx 的版本结果。

## 升级说明

如果你的 Docker 原本就是通过本脚本或 Docker 官方 apt 仓库安装的，直接重新运行本脚本即可升级：

```bash
curl -fsSL https://raw.githubusercontent.com/Unarmored7/install-docker/main/install-docker.sh | bash
```

如果是普通用户通过管道执行，请改用：

```bash
curl -fsSL https://raw.githubusercontent.com/Unarmored7/install-docker/main/install-docker.sh | sudo bash
```

脚本会自动检测系统中是否已存在官方 Docker apt 软件源（`/etc/apt/sources.list.d/docker.sources`）和 GPG 密钥（`/etc/apt/keyrings/docker.asc`）。如果检测到，将自动跳过步骤 1-6，仅执行 `apt-get update` 和 `apt-get install` 来升级已安装的 Docker 包。

升级完成后，脚本会显示安装前后的版本对比，便于确认是全新安装、版本未变还是已经升级。

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `DRY_RUN` | `0` | 设为 `1` 时只打印命令，不真正执行 |

```bash
sudo DRY_RUN=1 bash install-docker.sh
```

## 安装后操作

如果你希望普通用户无需 `sudo` 即可运行 Docker：

```bash
sudo usermod -aG docker $USER
# 然后退出并重新登录，或者执行：
newgrp docker
```

验证安装是否成功：

```bash
docker run hello-world
```

## 卸载

```bash
sudo apt-get purge -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras
sudo rm -rf /var/lib/docker /var/lib/containerd
sudo rm -f /etc/apt/sources.list.d/docker.sources /etc/apt/keyrings/docker.asc
```

## 许可证

[MIT](LICENSE)
