# 反向代理与 HTTPS

入口：**应用与容器 → 反向代理与 HTTPS**，或运行 `keine web`。
Nginx/Caddy 应用详情和证书中心提供相同功能入口。

## 创建反向代理

1. 在软件中心安装 Nginx 或 Caddy。Caddy 配置识别还需要 jq。
2. 选择反代引擎，进入「新建反向代理」。
3. 填写域名和上游，例如 `panel.example.com` 与 `http://127.0.0.1:2053`。
4. 选择 HTTP、申请 HTTPS 或已有证书，检查部署信息后应用。

上游支持 HTTP/HTTPS、域名、IPv4 和方括号 IPv6，必须包含端口。
当前模板代理整个站点，支持 WebSocket；路径改写、多上游和自定义路由继续由原生配置管理。
HTTPS 上游验证证书，不自动跳过身份或信任链检查。

站点详情支持修改目标、证书、响应超时和上传上限，以及启用、停用、访问检查和删除。
配置通过原生检查后重载运行中的服务；未启动的服务只保存配置，可从详情进入应用服务管理启动。
配置写入或加载失败时恢复本次操作前的文件。外部手动修改会阻止自动覆盖。

## 已有配置

「识别已有配置」通过 `nginx -T` 展开 include，通过 `caddy adapt` 展开 Caddyfile/import。
原生 systemd 服务的显式主配置路径会被识别；已有站点和证书不要求重新创建。
识别页面只读，复杂配置不转换为模板。自动编辑仅适用于有恢复记录、内容未被外部改动的托管站点。

托管文件默认位于：

| 引擎 | 配置 |
| --- | --- |
| Nginx | `/etc/nginx/conf.d/keine-域名.conf` |
| Caddy | `/etc/caddy/keine.d/keine-域名.caddy` |
| HTTP 验证目录 | `/var/lib/keine-acme` |

Nginx 主配置的 `http` 中必须包含对应的 `conf.d/*.conf`；未加载站点时应用会失败并回退。
Caddy 首次创建时向原有 Caddyfile 追加 import，并保存首次基线；最后一个托管站点删除后，在没有其他文件或外部修改时恢复原 Caddyfile。

自定义目录可通过 `KEINE_NGINX_CONFIG`、`KEINE_NGINX_SITES`、`KEINE_CADDY_CONFIG`、`KEINE_CADDY_SITES` 和 `KEINE_ACME_ROOT` 指定。
修改前必须确认主配置与 systemd 服务实际使用的路径一致；容器、Caddy API/`--resume` 模式、Nginx 自定义 prefix 不自动改写。
后续管理应使用相同的目录设置。

## 申请与部署证书

### Nginx 与 Certbot

新建 Nginx 站点时可选择「申请并部署 HTTPS 证书」。流程先建立 HTTP 验证路径，使用 Certbot Webroot 获取证书，再校验证书和私钥、部署 HTTPS，并保留 HTTP 验证路径。
签发失败时 HTTP 站点保留，可以从站点详情重试或绑定已有证书。
此流程只需要 Certbot 客户端，不依赖 Certbot Nginx 插件，不让插件改写已有站点。

证书中心也支持独立申请：

- **HTTP 验证**：填写已经对外提供文件的 Webroot。域名应解析到对应服务器，公网 80 端口可达。
- **手动 DNS 验证**：按 Certbot 提示添加 TXT 记录，支持 `*.example.com`。需要交互式终端，后续续期同样需要手动完成验证。

多个域名用逗号分隔，最多 10 个。申请前确认联系邮箱及 Let's Encrypt 服务条款。
现有同名证书不被首次签发覆盖，应从原证书详情执行续期。
HTTP 自检从 VPS 发起，无法代替所有公网线路的可达性验证；云平台安全组需要在云控制台单独配置。

### Caddy

选择「Caddy 自动 HTTPS」后，证书申请和续期由运行中的 Caddy 原生负责，keine 不创建额外任务。
配置加载成功不等于公网证书已经签发；可使用站点的「检查访问」或查看 Caddy 日志确认。
Certbot 列表不包含 Caddy 自身管理的证书。

Caddy 也可绑定已有 PEM 和私钥，文件必须对服务运行用户可读。
`/etc/letsencrypt` 的默认私钥权限通常不允许 Caddy 用户读取；工具不会放宽整个证书目录的权限，应优先使用 Caddy 自动 HTTPS，或自行提供权限合适的独立证书文件。

## 续期、删除与恢复

keine 不新增 Cron、Timer 或自动续期钩子；软件包原有的续期任务保持原状。
通过 keine 手动续期后，证书发生变化时会检查并重载引用该证书的托管站点。
在其他工具中更新证书后，应由对应工具完成重载，或在应用详情手动检查并重载服务。

删除站点保留证书和上游应用。删除 Certbot 证书前检查托管站点（包括停用站点）及可读取的 Nginx/Caddy 原生配置；面板、容器和其他应用的引用需要管理员确认。
证书删除通过 Certbot 执行，不可由 keine 撤销。

「备份与恢复 → 项目变更记录」可恢复 Web 配置首次修改前的状态，并验证、重载对应服务。
已签发的证书、ACME 账户和原生工具数据作为用户资产保留，不因卸载 keine 自动清除。

参考：[Nginx WebSocket](https://nginx.org/en/docs/http/websocket.html)、[Caddy 自动 HTTPS](https://caddyserver.com/docs/automatic-https)、[Certbot 用户指南](https://eff-certbot.readthedocs.io/en/stable/using.html)。
