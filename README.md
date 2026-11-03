# install-docker.sh

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell: Bash](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnubash&logoColor=white)](install-docker.sh)
[![Platform](https://img.shields.io/badge/Platform-Debian%20|%20Ubuntu-A81D33?logo=debian&logoColor=white)](#运行要求)

一个用于在 **Debian / Ubuntu** 上安装或升级 **Docker Engine + Compose v2** 的一键脚本。

遵循官方 [Docker apt 仓库安装流程](https://docs.docker.com/engine/install/debian/)，自动完成仓库验签、冲突包替换、软件源配置、Docker 安装以及服务启动。脚本会自动识别当前环境，区分**首次安装**与**升级**两种场景：

默认安装 **stable 通道中的最新版本**。

| 场景 | 行为 |
|------|------|
| **首次安装** | 验证官方仓库后，预下载完整事务，再一次性替换冲突包并安装 Docker |
| **升级** | 检测到 `docker-ce` 已安装后，安全刷新密钥和软件源并升级 |

---

## 快速开始

```bash
curl -fsSLo install-docker.sh https://raw.githubusercontent.com/Unarmored7/install-docker/main/install-docker.sh && bash install-docker.sh
```

只有下载成功后才会执行；本地执行时，非 `root` 用户会自动尝试通过 `sudo` 提权。建议首次使用前先查看 `install-docker.sh`。

<details>
<summary>其他运行方式</summary>

使用 `wget` 下载后执行：

```bash
wget -qO install-docker.sh https://raw.githubusercontent.com/Unarmored7/install-docker/main/install-docker.sh && bash install-docker.sh
```

系统没有 `curl` 或 `wget` 时，先安装 `curl`：

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
```

检查脚本内容：

```bash
less install-docker.sh
```

</details>

---

## 运行要求

| 项目 | 要求 |
|------|------|
| **发行版** | Debian 11 / 12 / 13；Ubuntu 22.04 / 24.04 / 26.04 |
| **权限** | root（本地执行时可自动 sudo 提权） |
| **工具** | Bash、`apt-get`、`apt-cache`、`dpkg`、`dpkg-query`、`timeout`；缺少 `curl` / `wget` 时脚本会尝试安装 `curl` |
| **网络** | 能访问 GitHub Raw、`download.docker.com` 以及系统 apt 源中的依赖包 |

以上发行版列表来自脚本的检查规则。脚本也会校验发行版代号和 CPU 架构，并在安装前确认官方仓库提供全部目标包；不支持其他发行版或仅修改了发行版名称的兼容系统。

---

## 安装流程

在修改现有安装前，脚本会使用临时密钥和隔离的软件包索引验证 Docker 仓库的 `InRelease` 签名，并确认 5 个目标包都有候选版本。随后依次执行以下 8 个步骤：

| # | 操作 |
|---|------|
| 1 | 识别需要替换的冲突包（`docker.io`、`docker-compose-v2`、`docker-buildx` 等） |
| 2 | 备份并停用明确的旧 Docker apt 条目 |
| 3 | 原子安装已验证的 Docker 官方 GPG 密钥 |
| 4 | 原子写入 Docker apt 软件源（Deb822 `.sources` 格式） |
| 5 | 仅更新 Docker 官方软件包索引，不受无关第三方源网络故障影响 |
| 6 | 在修改现有运行时前预下载完整 apt 事务 |
| 7 | 在单次 apt 事务中替换冲突包并安装 Docker Engine、CLI、Compose 和 Buildx |
| 8 | 启动服务，并使用有界超时连接 Docker daemon |

如果密钥、软件源、索引下载、软件包安装或 daemon 健康检查失败，脚本会恢复原有 apt 配置。它只迁移明确的 `docker.list`、`docker-ce.list` 和官方 `docker.sources`，不会通配删除其他 `docker*.sources`。已经由 apt 完成的软件包变更不会自动降级。

安装完成后，脚本会启动 Docker 服务，并必须能连接 daemon 才会报告成功。默认检查 `unix:///var/run/docker.sock`；通过 `DOCKER_VERIFY_HOST` 指定自定义地址时，脚本会跳过本机 `docker.service` 启动，直接检查该 endpoint。

---

## 升级

重新下载并运行即可：

```bash
curl -fsSLo install-docker.sh https://raw.githubusercontent.com/Unarmored7/install-docker/main/install-docker.sh && bash install-docker.sh
```

脚本检测到 `docker-ce` 已安装后进入升级模式：保留 Docker 数据，刷新官方 GPG 密钥和 apt 源，再升级到最新版本。冲突包不会被提前卸载；如需替换，会与新包放在同一次 apt 事务中处理。

完成后会输出版本对比（`fresh install` / `upgraded` / `unchanged`），一目了然。

---

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `DRY_RUN` | `0` | 设为 `1` 时预览安装命令，跳过软件包、apt 配置和服务变更；仍执行系统与已安装版本的只读检查 |
| `DOCKER_VERIFY_HOST` | `unix:///var/run/docker.sock` | 安装后用于健康检查和版本读取的 daemon 地址；自定义时不启动本机服务 |

```bash
DRY_RUN=1 bash install-docker.sh
```

预览仍要求受支持的 Debian / Ubuntu、root（或可用的 `sudo`）及表中系统工具，不能在 macOS 或 Windows 原生环境中运行。预览不会实际下载密钥、验证仓库签名或确认候选包，也不能证明正式安装一定成功。

例如 daemon 使用自定义 Unix socket：

```bash
DOCKER_VERIFY_HOST=unix:///run/docker-custom.sock bash install-docker.sh
```

`DOCKER_VERIFY_HOST` 只改变 daemon 健康检查和服务端版本读取的目标。软件包和 apt 配置仍安装在执行脚本的当前机器；自定义目标时不启动本机 Docker 服务，需要该目标已可访问。

---

## 维护与验证

修改后先运行语法检查；该命令只解析脚本，不执行安装、联网或提权：

```bash
bash -n install-docker.sh
git diff --check
```

可在安装了 Bash 的 macOS / Linux 或 Windows Git Bash 中做上述检查。仓库目前没有自动化测试套件；语法通过不代表 apt 安装事务或 daemon 启动已验证。安装和升级流程的实测应在可还原的受支持 Debian / Ubuntu 测试机中进行。

正式升级前保存应用的 Compose 文件、私密配置、持久化数据及可恢复的主机备份，并记录现有 Docker / Compose 版本和业务状态。脚本自己的临时备份只用于当前运行中恢复 apt 源及密钥：正常完成或恢复成功后即清理，不是应用或 Docker 数据备份。

安装失败时先查看脚本错误、apt 状态和 Docker 日志；自动恢复不完整时，脚本会输出保留的备份目录。已完成的软件包变更不会自动回退，业务恢复需使用事先准备的备份，而不是把卸载步骤当作升级回退。

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

先停止相关业务并确认备份可恢复。以下命令卸载软件包，保留默认数据目录：

```bash
sudo apt-get purge -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras
sudo rm -f /etc/apt/sources.list.d/docker.sources /etc/apt/keyrings/docker.asc
```

只有确定要清空默认目录中的容器、镜像和卷数据时，才单独执行以下删除操作；自定义数据目录或外部挂载的应用数据需要按实际部署另行处理。

```bash
sudo rm -rf /var/lib/docker /var/lib/containerd
```

---

## 许可证

[MIT](LICENSE)
