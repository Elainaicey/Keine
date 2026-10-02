<div align="center">

# keine

**面向 Debian / Ubuntu VPS 的中文交互式运维控制台**

以清晰的信息架构组织系统、网络、安全、服务、软件、容器与配置恢复；操作目标可见、风险明确、变更可追踪。

[![Version](.github/assets/badges/version.svg)](VERSION)
[![Checks](https://github.com/Elainaicey/keine/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Elainaicey/keine/actions/workflows/ci.yml)
![Shell](.github/assets/badges/shell.svg)
![Platform](.github/assets/badges/platform.svg)
![Language](.github/assets/badges/language.svg)
[![License](.github/assets/badges/license.svg)](LICENSE)

[快速开始](#快速开始) · [功能矩阵](#功能矩阵) · [命令参考](#命令参考) · [安全模型](#安全模型) · [项目结构](#项目结构)

</div>

---

## 项目概览

keine 面向由单一 root 管理员维护的 Linux VPS，提供从状态观察、故障定位到常规配置变更的统一终端入口。

项目不追求无边界地收集脚本，而是遵循以下约束：

- **清晰分层**：系统能力优先于软件与应用，Docker 等独立应用归入应用中心。
- **状态驱动**：运维总览把当前异常与关注项关联到既有领域入口，不复制第二套实现。
- **单项安装**：软件中心一次安装、更新或移除一个条目，不提供套餐或全选；系统补丁更新使用独立的预览与确认流程。
- **直接安装**：选择软件后自动刷新来源并安装，不重复确认；移除、来源接管与高风险配置仍需明确确认。
- **完全按需**：命令退出后不保留项目进程，不创建 Cron、systemd Timer 或后台监控。
- **副作用透明**：软件安装不会自动开放端口、修改 SSH 或套用网络调优模板。
- **恢复优先**：每项资源仅保存首次修改前的状态；历史快照由用户手动创建，高风险配置先验证，再加载。
- **最小运行依赖**：核心控制台使用 Bash 与 Debian/Ubuntu 标准系统工具实现。

## 快速开始

### 一键安装

root 会话：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Elainaicey/keine/refs/heads/main/install.sh)
```

安装器将程序原子部署到 `/opt/keine`，并创建 `/usr/local/bin/keine`。下载或暂存目录会在流程结束后自动清理。

### 启动控制台

```bash
keine
```

控制台按管理领域分组，常用设置优先展示：

```text
主机管理     运维总览 · 系统管理 · 服务与日志
网络与安全   网络管理 · 安全中心
软件与应用   软件中心 · 应用与容器
项目与数据   备份与恢复 · 项目管理
```

终端与美化位于「系统管理 → 基础设置」，网络设置与诊断分别组织，配置快照、Docker 卷备份与项目变更撤销集中在「备份与恢复」。命令行快捷入口不受菜单层级影响。

## 功能矩阵

| 中心 | 能力 |
| --- | --- |
| **运维总览** | 响应式关键指标、内存/Swap/磁盘进度、服务与更新、TCP/Docker、UFW/Fail2ban/时间同步、恢复准备度和状态驱动的关注事项；可直接进入排障、更新、暴露面、服务与备份 |
| **系统管理** | 主机名、时区、时间同步与终端美化优先；当前发行版系统更新、事务预览、来源检查、故障排查、资源压力、进程、内核与重启状态、软件包健康、hold、依赖修复、存储与 Swap |
| **网络管理** | 系统 DNS、SOCKS5 出站配置、原生 WARP、可撤销内核参数和第三方调优适配；接口、路由、会话与监听集中管理，连通性、TCP/HTTP、链路与套接字诊断独立分组 |
| **安全中心** | 安全基线、公网暴露、登录活动、来源处置；UFW 生命周期、批量放行/拒绝与 TCP 连接限速；SSH 认证/端口、九项连接与转发策略、会话/密钥；Fail2ban 生命周期、Jail、封禁策略/白名单与恢复；TLS 证书检查 |
| **服务与日志** | failed/active 服务浏览、资源与退出结果、正反依赖、启动关键链、失败诊断、经验证的 service 生命周期，以及 Journal 条件查询、完整性验证、按时间/容量维护、内核警告和操作审计 |
| **软件中心** | 281 个单项软件、15 个用途分类；官方直装、原生安装识别、APT 事务预览、运行影响提示；包名搜索、关联软件指南、来源诊断、版本与完整性、安装与更新 |
| **应用与容器** | 11 类应用服务的分组资产视图、版本、运行健康、资源、PID、重启次数、关联监听、配置/数据资产、日志和详情页直接生命周期控制；支持官方配置检查、安全 reload 与单项软件更新；Docker 另提供容器、Compose、网络、安全清理和可校验卷备份 |
| **备份与恢复** | 手动备份托管配置、常用系统配置或指定 `/etc` 文件；每次独立快照、备注与保护、校验、差异、空间清理与恢复；Docker 卷归档；首次基线、冲突检测与项目变更撤销 |
| **项目管理** | 版本和安装信息、运行环境检查、自更新与三种卸载模式 |

系统组件精确映射一个 Debian/Ubuntu 软件包；Docker 与 Caddy 使用项目官方 APT 仓库，Oh My Zsh 与提示符使用经过验证的官方渠道。适合独立分发的 CLI 使用项目 GitHub Release，安装器只接受 `latest` 稳定版、精确架构资产和 GitHub API 提供的 SHA-256 digest。

## 命令参考

### 查询与导航

```bash
keine status                 # 一次性只读运维总览
keine doctor                 # 运行环境、项目文件和权限完整性检查
keine triage                 # 只读故障快速排查
keine updates                # 系统软件包更新清单
keine system-update          # 系统更新：刷新、预览、确认与验证
keine storage                # 只读存储概览
keine swap                   # Swap 状态与生命周期管理
keine process 1234           # 查看并管理指定 PID
keine software               # 进入分页软件中心
keine software jq            # 直接打开 jq 的管理详情
keine sources                # 按维护来源浏览软件
keine official-updates       # 检查已托管官方 Release 更新
keine exposure               # 分析公网监听、进程、容器与 UFW
keine ports                  # 监听端口
keine dns example.com        # DNS 解析器与记录诊断
keine dns-config             # 系统 DNS 配置、验证与恢复
keine proxy                  # 连接已有 SOCKS5 代理的配置中心
keine proxy-check https://example.com
                                # 显式使用代理的一次性连通验证
keine net-tuning             # 可撤销的网络参数、BBR 与地址优先级
keine tuning-adapters        # 第三方调优适配状态与持久参数来源
keine probe example.com 443  # DNS、路由与 TCP 握手探测
keine http https://example.com/health
                                # HTTP HEAD 状态、重定向、TLS 与请求阶段耗时
keine trace example.com      # mtr/traceroute 链路路径
keine interface ens3         # 单个网络接口详情
keine system                 # 系统管理中心
keine network                # 网络与端口中心
keine security               # 安全中心
keine auth-activity          # 最近 24 小时 SSH 登录活动
keine services               # 服务与日志中心
keine service nginx.service  # 直接管理一个 systemd 服务
keine service nginx.service restart
keine journal                # Journal 验证与空间维护
keine logs nginx.service     # 直接查看服务最近日志
keine apps                   # 应用与容器中心
keine app nginx              # Nginx 应用详情、健康、资产与安全 reload
keine compose my-project     # 管理现有 Compose 项目
keine backups                # 备份与恢复中心
keine backup-delete SNAPSHOT # 删除一个明确选择的项目快照
keine backup-cleanup         # 交互式清理历史配置快照
keine about                  # 版本和安装路径
keine version                # 版本号
keine --version              # 标准版本选项
keine self-update            # 检查并原子更新项目自身
keine uninstall              # 卸载程序或彻底清除项目数据
```

`keine http URL` 发起一次纯前台 HEAD 诊断请求，只接受不含凭据的 `http://` 或 `https://` URL。请求最多跟随 8 次 HTTP/HTTPS 重定向，连接超时为 5 秒、总超时为 20 秒；不会下载响应体、保存 Cookie 或创建后台任务，只展示经过终端字符清理的有限响应头。少数端点不支持 HEAD，返回 405/501 并不表示普通 GET 请求不可用。该命令用于即时定位 DNS、连接、TLS、首字节和应用状态问题，不是浏览器、内容下载器或持续可用性监控。

### 软件管理

软件按主要用途组织为系统基础、终端与编辑器、文件与存储、文本与搜索、网络诊断、远程连接与传输、性能与排障、安全与证书、备份与同步、Web 与代理、数据库与缓存、容器工具、语言与包管理、开发与构建、DNS 与消息。服务端与客户端放在同一领域，不再混入笼统的“基础”或“服务”分类；终端主题由「系统管理 → 终端与美化」管理，不混入软件下载分类。

目录覆盖 btop、Micro、Mosh、OpenVPN、NFS、Syncthing、PgBouncer、Podman Compose、Ansible、PHP 常用扩展等工具。条目可用性由当前发行版、架构与软件源决定；不会为了显示“可安装”而自动添加不明仓库。

```bash
keine list                   # 完整软件目录
keine list python            # 按关键词查询
keine software               # 分页浏览软件中心
keine software jq            # 直接打开软件详情
keine install jq             # 安装一个软件
keine update jq              # 更新一个已安装软件
keine remove jq              # 移除一个软件
keine terminal              # 独立终端外观中心，安装或一键切换
keine terminal-check        # 登录 Shell、提示符初始化与程序可用性诊断
keine warp                  # 原生 WARP / wgcf 管理
keine recovery              # 配置快照与变更撤销
keine changes               # 查看与撤销已记录修改
keine project               # 工具更新、诊断与卸载
keine install ripgrep        # 默认从上游官方下载稳定版
keine update ripgrep         # 检查并更新当前安装来源
```

`install`、`update` 与 `remove` 只接受一个软件 ID。交互式软件中心将搜索、分类、已安装、待更新与来源结果按 6 项一页展示，可用页内编号或软件 ID 进入详情；`list` 仍可输出完整目录用于终端查询。列表突出名称、状态与版本，详情仅列当前可用操作；`D` 打开安装信息，`G` 打开相关软件指南。软件列表会为当前页面一次性批量读取 dpkg、候选版本与更新状态，避免随着目录增长重复启动大量查询进程。选择安装或执行 `keine install ID` 后，直接刷新来源、检查依赖并安装，不再询问两次确认。APT 普通安装仍展示事务摘要并阻止意外移除；实际安装也使用 `--no-remove`。更新与移除保留事务预览和确认，执行后重新读取版本验证结果。

软件详情还会展示已声明的运行影响。Web、数据库、容器、安全与历史采集类软件可能由发行版安装脚本启动自身服务、Timer/Cron 或监听端口；这不代表 keine 创建了后台组件。未声明运行影响的条目也以 APT 最终事务为准，项目不会代替用户自动禁用上游服务或修改防火墙。

Docker 与 Caddy 在首次安装前不要求仓库已经存在：详情页会显示“待配置”，选择安装后按需创建官方签名和稳定仓库。Docker 迁移会先验证仓库及全部必需组件候选版本，移除冲突包仍需单独确认，避免上游不可用时先破坏现有运行时。来源诊断可按需检查软件源、签名密钥格式、系统代号、架构与候选版本；文件检查显示“结构完整”不代替 APT 的签名身份验证，安装或更新刷新索引时仍由 APT 完成信任校验。若上游轮换密钥导致刷新失败，可从详情页强制重新获取官方仓库文件。配置不完整时会保存首次基线再修复；检测到符号链接形式的仓库路径时会停止覆盖并要求人工核实。已有发行版 `docker.io` 安装仍沿用原来源更新，不会被静默迁移到 `docker-ce`。

### 应用服务管理

应用中心通过声明式 [`config/apps.tsv`](config/apps.tsv) 识别 Docker、Nginx、Caddy、Apache、HAProxy、Redis、Memcached、PostgreSQL、MariaDB、Mosquitto 与 3x-ui。清单按容器、Web、缓存、数据库、消息和代理领域分组；未安装且具有软件目录映射的条目只进入对应单项安装流程。

每个已安装应用都有独立详情页，汇总软件版本、候选版本、systemd 状态、资源、主进程、重启次数和执行结果，并提供进程关联监听、配置资产与数据占用的独立入口。启动、停止、重启和开机策略可直接执行，统一复用带确认与结果验证的 systemd 生命周期。

应用清单一次批量读取 systemd 属性与已安装包版本。菜单返回复用内存快照，`R` 显式刷新；生命周期和软件操作后快照失效，实际变更仍重新校验原生状态。容器详情合并为一次 `inspect`，Compose 概况合并为一次容器列表；端口、挂载、日志、资源与空间查询按需执行，只读查询设有短时超时。终端文本宽度也在本次进程内复用，避免返回菜单时重复启动外部测量命令。

Nginx、Caddy、Apache、HAProxy 与 Docker 可调用各自的官方只读配置检查；Nginx、Caddy、Apache 与 HAProxy 只有在配置检查通过且 systemd 声明 reload 能力后，才允许重新加载。运行健康页综合服务状态、应用响应、监听、最近错误、重启次数和资源快照，并给出明确结论。应用详情还可进入对应的软件条目检查候选版本和来源。3x-ui 没有声明可验证的安装来源，因此项目不会猜测下载地址或自动升级。

健康检查、日志查询和数据占用统计均由用户手动触发一次。整个 keine 都不会创建监控进程、Cron、systemd Timer，不会周期扫描目录，也不会隐式开放防火墙端口。配置资产页只列出路径和文件名，不输出配置内容；数据占用只在用户明确进入该页面时对声明路径运行一次 `du`。

### 软件来源策略

| 来源 | 适用范围 | 更新与完整性 |
| --- | --- | --- |
| Debian / Ubuntu 仓库 | 系统组件、库、内核相关工具与大多数服务 | 刷新 APT 索引，安装候选版本并回读 dpkg 状态 |
| 项目官方 APT 仓库 | Docker、Caddy 等长期运行服务 | 使用仓库签名、稳定通道与 systemd 状态验证 |
| 项目官方 GitHub Release | 更新频繁且提供独立二进制的 CLI | 查询 latest stable，匹配 amd64/arm64 资产并验证 SHA-256 digest |
| 项目官方 Git 仓库 | Oh My Zsh、Spaceship 等框架或主题 | 验证远端地址，只允许 fast-forward 或官方升级流程 |
| 项目官方安装渠道 | Starship、Oh My Posh 等专用安装器 | 固定官方 URL、独立状态标记和安装后版本验证 |

20 个官方 Release 条目覆盖 ripgrep、fd、bat、fzf、eza、zoxide、Fastfetch、bottom、dust、duf、hyperfine、just、Lazygit、Delta、Lazydocker、actionlint、GitHub CLI、ShellCheck、Micro 与 Go 版 yq。这些独立工具默认直接下载上游稳定版，发行版软件包只作为显式备选。Go 版 yq 不映射发行版中可能存在的同名 Python 工具。系统组件、共享库与未实现独立安装适配的服务继续使用系统或厂商签名渠道，不混用未经验证的源码安装。

候选版本来自本机索引，不代表已经联网确认。尚未刷新且没有候选版本的条目显示“待刷新确认”，不会直接判定仓库故障；安装时自动刷新并校验 APT 事务，无需额外确认。`R` 可在软件中心、列表和详情刷新索引；来源诊断只读取本地版本优先级与地址。官方 Release 的显式更新检查会重新查询上游，浏览菜单不会联网探测。

### Nginx 与 HTTPS 证书

Certbot、Nginx 插件与 Apache 插件位于“安全与证书”，也可搜索 `certbot`、`https` 或真实包名。Nginx 软件详情的 `G` 指南和应用详情的 HTTPS 入口可直达插件；关联软件由用户分别选择安装，不绑定下载。

```bash
keine software nginx
keine software certbot-nginx
```

Nginx 本身不包含 Certbot。安装 `certbot-nginx` 时，APT 会解析 `python3-certbot-nginx` 对证书客户端的依赖，不需要重复安装；安装不会自动签发证书或修改站点。使用前核实域名解析、站点与验证端口；详细步骤参见 [Certbot 官方 Nginx 指南](https://certbot.eff.org/instructions?ws=nginx&os=pip)。发行版 Certbot 可能启用自身续期 Timer，软件详情和安装摘要会单独提示；这不属于 keine 后台监控。

现有发行版包与外部命令会被识别。切换到官方版时保留底层系统包；同路径外部普通文件必须明确确认并保存首次基线后才接管，符号链接不覆盖。只观察或切换配置不意味着拥有外部软件，删除前仍验证来源与所有权。

每个官方二进制都会记录版本、仓库、资产名称、资产 digest、命令路径和二进制 SHA-256。更新或删除前会重新验证本机文件；检测到人为修改时自动操作会停止，可在详情页选择“修复官方安装”，核对变更记录后部署可信版本；如需保存当前版本，请先手动创建快照。

### 节点主机网络配置

`keine dns-config` 识别 systemd-resolved、resolvconf 或普通 `resolv.conf`，提供公共 DNS 和最多三个自定义 IPv4/IPv6 地址。配置通过原生后端加载，并使用系统解析器验证；应用失败时回退，恢复时保留外部修改冲突。不会破坏生成文件的符号链接、锁定 `resolv.conf` 或停用网络管理器。NetworkManager、Netplan 等未适配后端只提供诊断，不强行覆盖。系统 DNS 不等于 Xray、sing-box 等节点软件内部 DNS。[systemd-resolved 配置文档](https://manpages.debian.org/bookworm/systemd-resolved/resolved.conf.5.en.html)

`keine proxy` 管理连接已有 SOCKS5 代理的客户端配置，可选择本机解析目标域名或交给代理解析，并支持隐藏输入认证密码。配置保存到 root 专用的 `/etc/keine-socks.conf`，不写入全局代理变量、不修改路由、不开放监听，也不接管 SSH、APT 或节点软件的出站设置。显式使用方式：

```bash
keine proxy-check https://example.com
curl --config /etc/keine-socks.conf https://example.com
```

SOCKS 认证信息在该文件中以明文保存，权限为 `0600`；配置快照和原始记录也应视为敏感数据。SOCKS5 不是加密隧道，公网连接应使用可信的加密传输。验证只发送一次限时 HEAD 请求，HTTP 错误状态与代理连接失败分别处理。[curl 代理选项](https://curl.se/docs/manpage.html)

`keine net-tuning` 提供 TCP MTU 探测、Fast Open、Keepalive 和收发缓冲上限的逐项设置，另保留原生 BBR 与 IPv4 优先级入口。界面显示当前值、范围、单位与适用条件，不套用一键激进模板；Keepalive 和 Fast Open 仍取决于应用支持，缓冲上限不等于预分配内存。项目只应用自己的参数，并同时记录文件和首次修改前的运行值；撤销不猜测默认值，也不删除第三方配置。[Linux 内核网络参数](https://docs.kernel.org/networking/ip-sysctl.html)

`keine tuning-adapters` 为后续第三方调优提供注册入口与参数来源查询。当前没有选定上游，不下载或执行外部脚本；未知脚本的内核、路由和配置改动不在自动撤销承诺内。适配要求见 [网络调优适配契约](docs/NETWORK-ADAPTERS.md)。所有新增能力仍保持前台按需运行，没有定时监控或自动任务。

### 终端与原生集成

`keine terminal` 根据目标用户实际登录 Shell 配置提示符，而不是根据工具自身的 Bash 解释器判断。Starship 与 Oh My Posh 支持 Bash/Zsh，复用已安装引擎，无需为了修复配置重复下载。Oh My Zsh 与 Spaceship 需要 Zsh；切换登录 Shell 必须单独确认，并只在配置成功后执行。

配置目标以运行工具的有效用户为准，不使用 `SUDO_USER`、`USER` 或 `HOME` 推断身份。通过 `sudo -i`、`su -` 或 `sudo keine terminal` 以 root 运行时，安装与配置属于 root，主目录从系统账户记录读取；菜单明确展示配置用户。只复用该用户或标准系统路径内的提示符程序，不借用继承 PATH 中其他用户的私有引擎。依赖已齐全时不再输出笼统的“已经安装”；新安装先验证程序及版本，再登记所有权和配置，成功提示不代表当前父 Shell 已立即加载。

Bash 登录桥接按用户与 Shell 进程识别初始化状态；继承其他会话的标记不会阻止当前用户加载 `.bashrc`。云主机普通用户登录后，可先执行 `sudo -i`，再运行 `keine terminal` 为 root 应用美化；退出工具后新开 root 登录 Shell 生效，无需重启 VPS。升级工具不会自动覆盖普通用户的已有配置，也不会自动替 root 应用主题。

Bash 初始化写入 `.bashrc` 并补齐实际生效的登录入口，Zsh 写入 `.zshrc`；配置先进行语法检查，失败时回退。切换会整理可识别的初始化语句与 `ZSH_THEME`，保留其他自定义内容。首次修改前记录原始文件，恢复操作覆盖已记录的 Bash/Zsh 启动文件与登录 Shell，保留引擎。复杂自定义条件或函数初始化仍需人工检查。

菜单中的“已配置”不等于当前父 Shell 已加载。配置完成后退出工具并重新连接 SSH，无需重启 VPS；`keine terminal-check` 检查登录 Shell、启动配置与引擎可用性，但不会执行用户启动脚本。Nerd Font 应在本机 SSH 客户端设置，不向 VPS 下载字体包。

Oh My Zsh 使用官方 Git 仓库；Starship 与 Oh My Posh 使用官方安装器，Spaceship 使用官方 Git。外部已有的 Oh My Zsh 只复用配置，不自动升级或删除其仓库。移除随机字符画、彩虹文本、重复系统信息和已不维护主题等低价值目录条目，终端项目不再混入软件中心。

`keine warp` 不依赖项目安装标记，识别 `warp-cli` 与 `/etc/wireguard/` 下的 WARP/wgcf 配置。官方客户端提供连接、断开与服务管理；wgcf 使用原生 `wg-quick@` 生命周期。不会展示私钥、创建注册、切换协议、删除外部配置或接管未知第三方脚本。路由变更可能影响 SSH，操作前应保留服务商控制台。接口依据 [Cloudflare Linux 文档](https://developers.cloudflare.com/warp-client/get-started/linux/) 与 [WireGuard 原生单元](https://github.com/WireGuard/wireguard-tools/blob/master/src/systemd/wg-quick%40.service)。

相关上游：[Starship](https://github.com/starship/starship)、[Oh My Posh](https://github.com/JanDeDobbeleer/oh-my-posh)、[Spaceship Prompt](https://github.com/spaceship-prompt/spaceship-prompt)。Powerlevel10k 因上游已明确进入有限支持状态，暂不纳入正式托管目录。

### 操作预览

```bash
keine --dry-run
keine --dry-run install docker
keine --no-color status
keine --help
```

`--dry-run` 展示将执行的系统命令，不写入配置、不安装软件，也不创建审计记录。`--no-color` 用于日志采集或不支持 ANSI 色彩的终端；`-h` / `--help` 显示完整命令摘要。菜单键统一使用 `[1]`、`[R]` 格式；功能菜单中 `0` 返回上层，`H` 直达首页，`Q` 退出工具，首页 `0` 退出。操作结果页也支持 `H` 回首页与 `Q` 退出；跳转保留预览和无颜色模式，不叠加菜单进程。主机名、地址等普通配置输入不拦截导航键。

### 安全策略管理

SSH 提供认证与端口向导，以及认证尝试、认证宽限、复用会话、客户端存活探测、Agent/X11/TCP 转发和远程转发监听范围的逐项设置。写入前保存首次基线，检查 `sshd -t`、核对当前 root 连接上下文的有效值，再 reload；失败时补偿回退。存活探测不是交互空闲超时，SSH TCP 转发开关也不控制 Xray 等节点软件的监听。禁用密码或收紧 root 认证前，必须先在另一窗口验证公钥登录。

Fail2ban 的 SSH 策略独立管理封禁时间、观察窗口、失败次数及 IP/CIDR 白名单；保留回环和当前 SSH 来源。运行时验证配置与实际参数，并核对当前来源白名单；停止时仅保存配置，不自动启动服务。撤销只恢复项目配置，不删除其他 Jail。使用 systemd 日志后端，需要对应的 Python 支持；工具不自动安装该依赖，配置语法检查也不替代真实服务启动验证。

UFW 规则支持多个端口、范围、TCP/UDP 与来源 IP/CIDR；拒绝规则不能覆盖当前 SSH 端口。TCP 连接限速使用 UFW 原生 `limit` 并优先插入，针对连接尝试而非传输带宽；它同时放行所选来源，应先核实既有访问边界。规则顺序、IPv6、云防火墙和容器转发都可能影响最终结果，界面不会把“命令成功”当作已验证公网连通。

## 安全模型

| 边界 | 行为 |
| --- | --- |
| 定位 | 面向单一 root 管理员的 VPS，不提供多账户与提权工作流 |
| 运行方式 | 仅在前台按需执行；命令结束后无项目常驻进程、Cron、Timer 或后台监控 |
| 权限 | 查询不会修改系统；所有写操作仍在执行点验证 root 权限 |
| 确认 | 单项安装直接执行并保留依赖校验；移除、来源接管及高风险修改显示影响并确认，默认拒绝 |
| 配置备份 | 仅手动创建，写入 `/var/backups/keine/<snapshot>/` 并生成 manifest；修改和恢复不产生额外历史快照 |
| 撤销记录 | `/var/lib/keine/changes/` 每项资源保留一份首次原始状态和最后指纹；不随修改次数增长 |
| 备份清理 | 只删除格式和目录均可验证的项目快照；支持保留最近数量或按创建天数清理，当前操作和人工保护的快照始终跳过 |
| Docker 卷 | 手动创建归档并校验 SHA-256，恢复前拒绝运行中占用；恢复会覆盖原卷，不自动创建额外备份 |
| SSH | 独立 drop-in、语法与当前连接上下文有效值验证；收紧认证前确认 root 公钥可用，reload 或验证失败时补偿恢复；保留当前会话并在新窗口验证 |
| 进程 | PID、nice 和信号严格校验；PID 1、工具自身与父进程不可控制；SIGKILL 单独标记为危险操作 |
| 防火墙 | 启用 UFW 前保留当前 SSH 端口；其他端口必须显式添加 |
| 来源处置 | 只接受登录失败清单中的明确 IP；拒绝阻止当前 SSH 来源，UFW 持续拒绝与 Fail2ban 临时封禁分开展示 |
| 审计 | root 修改记录到 `/var/log/keine/actions.log` |
| 官方 Release | 校验上游、架构与 SHA-256；外部普通文件仅在明确确认并保存首次原始状态后接管，拒绝覆盖符号链接 |
| 安装升级 | 解压前检查源码归档路径、类型与体积，在同一父目录暂存并原子替换；失败时恢复上一安装目录 |
| 卸载 | 只删除能够确认属于项目的路径，不猜测性删除业务软件或系统设置 |

> [!WARNING]
> 修改 SSH、防火墙、路由或存储前，应保留 VPS 服务商控制台并创建实例快照。Docker 发布的容器端口可能绕过 UFW，需要结合云防火墙与 `DOCKER-USER` 链评估实际暴露面。

## 数据与路径

| 内容 | 默认位置 |
| --- | --- |
| 程序目录 | `/opt/keine` |
| 命令入口 | `/usr/local/bin/keine` |
| 配置快照 | `/var/backups/keine` |
| Docker 卷备份 | `/var/backups/keine-docker` |
| 操作审计 | `/var/log/keine/actions.log` |
| 项目状态 | `/var/lib/keine` |
| 官方 Release 状态 | `/var/lib/keine/software-releases` |
| 可撤销变更与初始状态 | `/var/lib/keine/changes` |

安装器会将实际安装路径写入 `config/installation.conf`，以确保自定义路径也能被正确升级和卸载。

## 项目结构

```text
keine/
├── .gitattributes               # 跨平台文本与 LF 换行规则
├── .github/                     # CI、发布流程、社区规范与徽章资源
├── .gitignore                   # Git 忽略规则
├── bin/
│   └── keine                   # CLI、参数解析与顶层导航
├── config/
│   ├── software.tsv             # 声明式单项软件目录
│   ├── navigation.tsv           # 顶层分组、顺序与动作注册
│   ├── terminal.tsv             # 独立终端框架与提示符
│   ├── integrations.tsv         # 原生适配器注册
│   ├── apps.tsv                 # 应用、systemd Unit、软件来源与类别映射
│   ├── software-effects.tsv     # 软件自身服务、调度与网络影响声明
│   ├── official-releases.tsv    # 官方 Release、架构资产与项目主页
│   └── software-guides.tsv      # 关联软件、使用边界与官方文档
├── docs/                        # 设计、变更记录与发布文档
├── scripts/
│   ├── install.sh               # 安装、原子升级与卸载
│   ├── check-repository.sh      # 全文件分类、格式与元数据验证
│   ├── check-shell.sh           # Bash 语法与逐文件 ShellCheck
│   ├── check-tests.sh           # 离线单元和 CLI 冒烟测试
│   └── release-check.sh         # 发布前聚合门禁
├── src/
│   ├── core/                    # 运行时、UI、平台、导航、备份与可逆变更
│   ├── integrations/            # 原生软件适配器；不依赖安装所有权
│   └── features/
│       ├── dashboard.sh         # 运维总览领域入口
│       ├── dashboard/           # 状态采集、关注事项、响应式视图与快捷导航
│       ├── apps/
│       │   ├── services.sh      # 应用服务领域入口
│       │   ├── services/        # 元数据、资产、健康、操作、总览、详情与菜单
│       │   ├── docker.sh        # Docker 领域入口
│       │   └── docker/          # 资产、Compose、容器、卷备份与菜单
│       ├── maintenance/         # 项目安装与文件完整性检查
│       ├── network.sh           # 网络领域入口
│       ├── network/             # 概览、HTTP/端点、接口、链路、套接字、调优与菜单
│       ├── security.sh          # 安全中心入口
│       ├── security/            # 基线、登录活动、暴露分析、Fail2ban、证书、防火墙与 SSH
│       ├── services.sh          # 服务中心入口
│       ├── services/            # 服务概览、Journal、Unit 与审计
│       ├── software/
│       │   ├── catalog.sh       # 软件目录模块入口
│       │   ├── catalog/         # 状态缓存、查询、事务预览、运行影响、分页浏览、写操作与页面
│       │   └── releases.sh      # GitHub Release 校验、安装、修复与来源管理
│       ├── terminal/            # Shell 启动适配、框架、提示符与切换界面
│       ├── recovery.sh          # 变更检查、恢复与冲突处理
│       ├── system/
│       │   ├── diagnostics.sh   # 单次资源压力与重启状态
│       │   ├── menu.sh          # root-only 系统管理导航
│       │   ├── packages.sh      # dpkg、APT 更新、hold、来源、修复与清理
│       │   ├── updates.sh       # 当前发行版系统更新、事务预览与结果验证
│       │   ├── storage.sh       # 分类占用、文件、挂载、fstab 与维护导航
│       │   ├── triage.sh        # 资源、服务、日志、网络、容器与恢复快速排查
│       │   ├── processes.sh     # 进程下钻、资源与安全控制
│       │   └── settings.sh      # 主机名、时区、Swap 与维护设置
│       └── *.sh                 # 系统、网络、安全、服务等功能中心
├── tests/                       # 离线单元测试与安全边界测试
├── install.sh                   # 稳定的一键安装引导入口
├── LICENSE                      # MIT 许可证
├── README.md                    # 项目主页
└── VERSION                      # 唯一版本来源
```

完整设计约束与扩展规范见 [`docs/DESIGN.md`](docs/DESIGN.md)，变更记录见 [`docs/CHANGELOG.md`](docs/CHANGELOG.md)，漏洞报告流程见 [`.github/SECURITY.md`](.github/SECURITY.md)，版本发布流程见 [`docs/RELEASE.md`](docs/RELEASE.md)。

## 支持范围

| 系统 | 版本 |
| --- | --- |
| Debian | 11 / 12 / 13 |
| Ubuntu | 22.04 LTS / 24.04 LTS |
| 架构 | amd64 / arm64 |
| Init | systemd |

当前不提供 RHEL 系、Alpine、非 systemd 系统或衍生发行版的兼容承诺。

## 更新

### 更新 keine

在控制台中进入“项目管理”更新工具，或直接运行：

```bash
keine self-update
```

也可以重新运行安装命令完成原子升级：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Elainaicey/keine/refs/heads/main/install.sh)
```

软件中心中的“更新”只更新当前选中的软件，不会升级整个系统。

### 更新 VPS 系统

通过“系统管理 → 系统更新”，或运行：

```bash
keine system-update
```

更新流程先检查 dpkg 与依赖状态，完整刷新 APT 索引，再检查官方系统源所属的发行版、展示升级与新增依赖清单，最后由用户再次确认。使用 `apt-get upgrade --with-new-pkgs --no-remove`，允许补齐必要依赖，但不自动删除软件包、解除 hold、迁移发行版、修改软件源或重启 VPS。该策略依据 [APT 官方手册](https://manpages.debian.org/bookworm/apt/apt-get.8.en.html)。

既有配置默认保留，needrestart 使用仅列出需求模式；软件包自身安装脚本仍可能重启 SSH、数据库等服务，应提前创建实例快照并保留服务商控制台。完成后验证软件包状态，展示剩余候选与系统提供的重启提示；没有重启标记不等于所有新内核和库已经生效。`--dry-run` 不下载新索引，只展示本地计划与修改命令。

更新覆盖当前配置的 APT 来源，不覆盖官方直装 CLI、手工编译的软件或容器内应用。发行版安全补丁经常回移到既有版本，不能仅按上游版本号判断漏洞是否修复；停止安全支持的系统需要另外规划迁移，普通软件包更新不能保证消除所有漏洞。参见 [Debian 安全说明](https://www.debian.org/security/faq) 与 [Ubuntu 安全公告](https://ubuntu.com/security/notices)。已有软件升级无法通过项目变更撤销，新增依赖则沿用首次变更记录机制。

## 卸载

```bash
keine uninstall
```

卸载模式：

1. **仅卸载程序**：删除程序目录和项目命令入口，保留日志与配置快照。
2. **彻底清除项目数据**：额外删除项目日志、配置快照、Docker 卷备份和状态目录。
3. **撤销已记录修改并卸载**：先恢复原始配置和原生设置、移除项目新增资源与软件包，通过后再清除项目；发现冲突或恢复失败则保留工具和记录。

前两种模式不撤销系统修改。第三种只对本版开始记录的变更生效：配置文件、官方命令、终端目录、主机名、时区、NTP、root Shell、BBR、受控服务状态、可识别的 WARP 连接，以及 APT 新增软件包。新增包撤销先模拟依赖事务，若会删除原有包或包后来被外部升级则停止；不运行自动清理。

不能保证任意主机“像从未安装过”：未记录的历史改动、原有软件升级或删除、数据库/容器业务数据、安装脚本未声明的副作用、网络活动和系统日志不自动逆转。外部修改过的资源会保留并报告冲突；可选择保留资源并解除对应记录。变更记录不是普通历史备份，删除恢复记录即失去对应原始状态。

## 开发

```bash
git clone https://github.com/Elainaicey/keine.git
cd keine
bash scripts/check.sh
```

开发检查需要 Bash 与 Python 3.8+；推荐安装 ShellCheck 和 yamllint，以获得与 CI 一致的完整结果。

检查流程分为 `repository-files`、`shell` 和 `tests` 三个独立任务。所有 Git 跟踪文件必须归入明确类别，并接受 UTF-8、LF、尾随空白和 Git 属性检查；Markdown、工作流 YAML、SVG、软件目录、许可证与版本元数据还会执行对应的专项验证。未归类的新文件会直接使 CI 失败。贡献要求见 [`.github/CONTRIBUTING.md`](.github/CONTRIBUTING.md)。

## 许可证

keine 依据 [MIT License](LICENSE) 开放源代码。你可以自由使用、修改与分发本项目，但必须保留原始版权声明和许可证文本。

---

<div align="center">
  <sub>keine 0.5.2 · Built for deliberate VPS operations</sub>
</div>
