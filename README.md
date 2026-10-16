# VPS Config

一个面向 VPS 日常运维场景的 Bash 工具脚本集合，当前核心入口为
`vps_tools.sh`。

这个项目把常见的服务器初始化、SSH 加固、测速、防火墙管理、
端口转发等操作集中到一个交互式菜单里，适合在新机器初始化或日常维护时
快速执行。

## 功能总览

当前脚本提供以下菜单功能：

1. SSH 安全加固
2. 修改主机名
3. 系统更新
4. Snell 安装
5. 防火墙管理
6. 端口转发（nftables）
7. 服务器质量检测（NodeQuality）
8. Cloudflare 测速
9. SSH 客户端配置管理
10. Tailscale 安装与运维
11. 清理备份文件

其中大多数功能需要 `root` 权限，测速和部分只读检测功能可在普通用户下执行，
但为了减少权限相关的中断，建议使用 `sudo` 或 `root` 用户运行整个脚本。

## 环境要求

- 操作系统：面向常见 Linux 发行版，脚本内已兼容 `apt`、`yum`、`dnf`
  等包管理器
- Shell：`bash`
- 权限：涉及 SSH、主机名、防火墙、系统更新、nftables 等功能时需要
  `root`
- 常见依赖：`curl`、`awk`、`sed`、`grep`、`systemctl`
- 网络前提：Snell、Tailscale、NodeQuality、Cloudflare 测速等功能依赖外部
  网络访问

> 提示：如果目标系统没有启用 `systemd`、`ufw`、`firewalld` 或 `nftables`，
> 某些功能会跳过对应步骤或依赖脚本内的降级处理。

## 快速开始

### 1. 获取脚本

如果你已经在仓库目录中，可以直接使用现有文件：

```bash
chmod +x ./vps_tools.sh
```

### 2. 运行脚本

推荐使用 `sudo` 启动：

```bash
sudo ./vps_tools.sh
```

启动后会进入交互式菜单，按提示输入对应编号即可执行功能。

## 菜单功能说明

### 1. SSH 安全加固

- 写入或追加 SSH 公钥到 `authorized_keys`
- 备份并修改 `/etc/ssh/sshd_config`
- 关闭密码登录，调整 SSH 端口
- 在存在 `ssh.socket` 的系统上同步处理 socket 配置
- 可选安装并启用 `fail2ban` 防暴力破解

这是高风险操作。执行前请确保你已经准备好可用公钥，并确认新端口能从外部
访问，否则可能导致远程连接中断。
如果选择启用 `fail2ban`，脚本会按当前 SSH 新端口生成最小 jail 配置，并尝试启用服务。

### 2. 修改主机名

- 修改系统主机名
- 尝试同步更新 `/etc/hosts`

适合新机器初始化时统一命名。修改后建议重新登录一次，确认主机名已正确生效。

### 3. 系统更新

主菜单选择 `3`，进入系统更新菜单：

- `1` **更新系统软件包**：执行现有的发行版软件包更新流程
- `2` **Ubuntu 24.04 → 26.04 LTS 升级（含内核）**：进入分阶段的 Ubuntu 发行版升级菜单
- `0` **返回主菜单**

#### 更新系统软件包

- 根据发行版执行系统软件包更新
- Debian / Ubuntu 优先使用 `apt-get`，严格刷新索引后再升级；任一软件源刷新失败即停止，
  避免使用旧索引下载已经被替换的软件包
- 升级遇到 `.deb` 下载 `404 Not Found` 时，绕过 HTTP / HTTPS 缓存重新刷新索引，
  然后重试升级一次；保留现有软件源和签名校验
- 索引刷新失败、重试后仍有 404 或其他升级错误时明确报错，只有成功才显示“系统更新完成”

如果提示 `Release` 文件或源索引 404，请检查 `/etc/apt/sources.list` 和
`/etc/apt/sources.list.d/` 中的软件源地址、发行版代号及官方支持状态。
镜像同步不一致或发行版停止维护时，单纯重试可能无法修复，需要核对对应发行版的官方源或归档说明。

建议在业务低峰期执行，避免升级过程中影响正在运行的服务。

#### Ubuntu 24.04 → 26.04 LTS 升级（含内核）

这是 Ubuntu 官方发行版升级流程，系统软件包和内核随发行版一起升级。
升级通道是否可用以 `do-release-upgrade` 查询到的官方实时元数据为准。
脚本不会通过 `-d` 选择开发版本或绕过官方升级通道。

升级前请准备 VPS 快照或完整备份，并确认能够使用供应商控制台恢复访问。
脚本保存的本机配置快照不能代替完整系统备份。通过 SSH 操作时建议先进入
`tmux` 会话，避免终端断开影响升级交互。

子菜单提供以下阶段，按顺序执行：

| 编号 | 阶段 | 操作 |
| --- | --- | --- |
| `1` | `prepare` 准备 | 检查系统，输入 `PREPARE` 确认后备份关键配置与软件包清单、完整更新当前系统并安装官方升级工具 |
| `2` | `upgrade` 升级 | 输入 `UPGRADE` 确认后，启动官方 `do-release-upgrade` 交互式升级 |
| `3` | `cleanup` 清理 | 升级并重启后，输入 `HEALTHY` 确认业务正常，再完整更新系统、预览待删除内容；输入 `REMOVE` 后清理冗余软件包、旧内核及 APT 缓存 |
| `4` | `status` 状态 | 查看系统版本、内核、重启需求和阶段执行状态 |
| `0` | 返回 | 返回系统更新菜单 |

准备和升级阶段检查 Ubuntu 版本、宿主机环境、cgroup v2、磁盘空间和软件包健康状态。
空间预检要求 `/` 和 `/var` 各至少有 5 GiB 可用空间，`/boot` 至少有 300 MiB；
Ubuntu 官方升级工具仍会计算本次升级的实际空间需求。
容器内无法通过此功能升级宿主系统与内核；运行 Docker、Kubernetes 等服务时，
请先验证其 cgroup v2 兼容性。`prepare` 完成后如提示需要重启，请手动重启再继续升级。

`upgrade` 保留 Ubuntu 官方升级工具的交互提示，需要审核软件包变更、配置文件冲突
和服务重启。准备及清理阶段的 `apt-get full-upgrade` 也保留 APT 确认。
软件源的发行版切换和第三方源处理交由官方升级器完成，请审核它的提示；重启由用户确认。

正式升级完成后，先重启并确认能够正常登录，SSH、Docker、数据库等关键服务均正常，
再进入 `cleanup`。输入 `HEALTHY` 确认业务正常后，脚本会刷新索引并执行
`apt-get full-upgrade`；完整更新也可能移除软件包，需要审核 APT 显示的变更并确认。
随后运行 `apt-get -s autoremove --purge` 保存清理预览；输入 `REMOVE` 后，
才会执行实际的 `autoremove --purge`，同时保留 APT 自身的确认提示。
`REMOVE` 仅控制后续自动清理，不控制前面的完整更新。
请仔细审核待删除列表，特别是旧内核和相关配置文件。
如果官方升级器明确返回失败，即使系统版本已显示为 26.04，脚本也会阻止自动清理；
请先检查 `/var/log/dist-upgrade/` 并人工修复升级问题。

可参阅 Ubuntu 官方的[发行版升级说明](https://documentation.ubuntu.com/server/how-to/software/upgrade-your-release/)
和 [26.04 移除 cgroup v1 的发行说明](https://documentation.ubuntu.com/release-notes/26.04/changes-since-previous-interim/#cgroup-v1-removed)。

| 路径 | 内容 |
| --- | --- |
| `/var/log/ubuntu-lts-24-to-26.log` | 阶段执行记录与 APT 输出 |
| `/var/log/dist-upgrade/` | Ubuntu 官方发行版升级日志 |
| `/var/backups/ubuntu-lts-24-to-26/` | 关键配置快照与软件包清单 |
| `/var/lib/ubuntu-lts-24-to-26/` | 执行状态与清理预览 |

### 4. Snell 安装

- 使用 [jinqians/snell.sh](https://github.com/jinqians/snell.sh#使用方法)
  推荐的自动识别系统入口：`https://install.jinqians.com`
- 下载成功且内容非空后，以 `sh` 执行安装入口，并按上游交互提示继续
- 上游入口为 Debian / Ubuntu、CentOS / RHEL 选择对应脚本；当前 Alpine
  分支转到 `snell-docker.jinqians.com` 的 Docker 安装方案

上游推荐命令：

```bash
sh -c "$(curl -fsSL https://install.jinqians.com)"
```

该功能本质上依赖远程脚本，执行前请自行评估来源可信度和版本兼容性。

### 5. 防火墙管理

- 自动识别并处理常见防火墙场景
- 放行 SSH 当前端口，降低误封风险

如果机器存在公网暴露服务，调整策略前请先确认需要保留的端口列表。

### 6. 端口转发（nftables）

- 安装 `nftables`
- 添加、查看、删除、清空端口转发规则
- 诊断当前转发和防火墙状态

该功能会修改系统网络转发规则，建议在明确流量入口、目标地址和目标端口后
再操作。

### 7. 服务器质量检测（NodeQuality）

- 调用 NodeQuality 相关检测脚本

适合快速了解 VPS 的基础网络和运行质量。该功能通常不需要 `root`，但仍依赖
外部网络访问。

### 8. Cloudflare 测速

- 对 `speed.cloudflare.com` 进行下载、上传和延迟测试
- 输出终端结果
- 生成 HTML 报告，便于后续查看与分享

脚本内已针对下载和上传大小做过兼容性控制，适合用于快速评估 VPS 到
Cloudflare 的链路表现。

### 9. SSH 客户端配置管理

管理本机 `~/.ssh/config` 中的远端服务器连接条目，无需 `root` 权限。子菜单提供：

- **列出**所有由本工具管理的 Host（含 `IdentitiesOnly yes` 的条目）
- **添加 / 更新** Host：配置 HostName、User、Port，可选启用 SOCKS5 代理
  （`ProxyCommand nc -X 5 -x 127.0.0.1:6153`）；IdentityFile 支持三种方式：
  生成新密钥对（ed25519 / rsa-4096 / ecdsa-521）、提供已有私钥路径、粘贴私钥和公钥内容
- **删除** Host：精确匹配别名，操作前自动备份 `~/.ssh/config`

### 10. Tailscale 安装与运维

主菜单选择 `10`，进入独立的 Tailscale 管理菜单：

- **安装**：Linux 上下载并执行 [Tailscale 官方安装脚本](https://tailscale.com/install.sh)；
  Alpine 使用 `apk` 安装 `tailscale`，OpenRC 环境同时安装 `tailscale-openrc`
  （需要启用 community 仓库）。安装后启动服务并设置开机自启；已安装时跳过安装。
- **登录 / 连接**：运行 `tailscale up`，首次连接按终端链接在浏览器中授权；
  再次连接保留节点已有偏好。脚本不收集或保存认证密钥。
- **状态与 IP**：查看版本、服务状态、开机自启状态、节点列表和 Tailscale 地址。
- **服务与日志**：支持 systemd 的 `tailscaled` 和 OpenRC 的 `tailscale` 服务，
  提供启动、重启、停止、自启管理；systemd 显示最近 80 条日志，OpenRC 提示查看 syslog。
- **连接设置**：分别开关接受 Tailnet DNS、接受子网路由、Tailscale SSH；
  使用 `tailscale set` 只修改选中的偏好。接受子网路由不会让本机发布子网，
  Tailscale SSH 还需要 Tailnet 访问策略授权。
- **网络诊断**：运行 `tailscale netcheck`，可输入节点名或 IP 执行 `tailscale ping`。
- **升级**：检测软件包安装记录后使用对应包管理器升级 `tailscale`；其他安装方式尝试 `tailscale update`，
  其支持范围取决于当前版本和平台。
- **断开 / 注销 / 卸载**：断开保留登录，注销后需要重新授权；卸载使用系统包管理器，
  保留本地状态和软件源配置，管理控制台里的设备记录需自行处理。
  未识别到软件包记录时，需要按照原安装方式手动卸载。

安装、连接、设置、升级和卸载等操作需要 `root`；状态与网络诊断可由普通用户执行，
日志读取受系统权限限制。操作统一使用 `[y/N]` 确认：输入 `y` 或 `Y` 执行，回车或其他输入取消。

停止、重启、断开、注销、升级或卸载可能中断经 Tailscale 建立的 SSH 连接，
请先准备公网 SSH 或控制台。启用 Tailscale SSH 可能改变经 Tailscale 地址连接到
22 端口时的认证方式。

脚本让 Tailscale 自行维护网络规则，不自动修改防火墙、发布子网或启用出口节点。
检测到已安装 Tailscale 时，会阻止 nftables 菜单中的“安装并接管”操作；
已有端口转发规则仍可管理。现有端口转发使用公网地址进行 SNAT，
转发到 Tailnet 节点的场景需要单独配置与验证。

### 11. 清理备份文件

- 清理脚本执行过程中生成的 SSH 和 `ssh.socket` 备份文件

建议在确认当前配置稳定可用后再执行，避免误删仍需回滚的备份。

## 注意事项

- 本项目以单脚本形式集中管理功能，执行前建议先阅读脚本中与你目标功能相关
  的提示信息。
- 涉及 SSH、防火墙、主机名、端口转发的功能都会修改系统配置，务必在具备
  控制台或可恢复手段的前提下操作。
- 涉及外部脚本的功能依赖第三方来源，使用前请自行审查安全性和稳定性。
- Cloudflare 测速会在当前目录生成 HTML 报告文件，注意清理历史结果。

## 文件结构

当前仓库结构较精简，核心文件如下：

```text
.
├── README.md
├── vps_tools.sh
└── tests/
```

- `vps_tools.sh`：主脚本，包含所有菜单功能和实现逻辑
- `README.md`：项目说明与快速上手文档
- `tests/`：SSH 配置、系统更新、Ubuntu LTS 升级和 Tailscale 运维测试；更新与 Tailscale
  测试使用命令桩，Ubuntu LTS 升级测试不执行真实升级，不安装软件或修改网络

## 使用建议

如果你只是想快速完成新机初始化，建议优先按以下顺序使用：

1. 修改主机名
2. SSH 安全加固
3. 系统更新
4. 防火墙管理
5. 按需使用测速和端口转发功能

如果你后续希望把某个菜单项拆成独立脚本或补充更详细的运维说明，可以在
此 README 基础上继续扩展文档层次。
