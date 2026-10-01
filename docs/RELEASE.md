# 发布流程

keine 使用语义化版本号，并以 `v<版本>` 作为 Git 标签。`VERSION` 是运行时和发布流程的唯一版本来源，正式说明保存在 `docs/releases/<版本>.md`。

## 发布前检查

1. 确认 `VERSION`、`docs/CHANGELOG.md` 和对应正式发布说明使用同一版本。
2. 确认目标提交已合并到 `main`，工作区没有未提交修改。
3. 确认发行归档包含 MIT `LICENSE` 和版权声明。
4. 在 Debian 或 Ubuntu 测试机完成 SSH、UFW、Swap、systemd、软件安装和卸载的人工冒烟。
5. 执行发布检查：

```bash
version="$(tr -d '[:space:]' < VERSION)"
bash scripts/release-check.sh "v$version"
```

## 创建版本发布

```bash
git switch main
git pull --ff-only origin main
version="$(tr -d '[:space:]' < VERSION)"
git tag -a "v$version" -m "keine $version"
git push origin "v$version"
```

标签推送后，GitHub Actions 会再次运行仓库格式、Bash 语法、逐文件 ShellCheck、单元测试、CLI 冒烟和发布一致性检查，随后创建：

- `keine-<版本>.tar.gz`
- `keine-<版本>.tar.gz.sha256`
- 使用 `docs/releases/<版本>.md` 内容的 GitHub Release

如果工作流失败，应修复问题并使用新的版本号重新发布；不要移动已经公开使用的标签。

## 发布后验证

在一台全新的 Debian 或 Ubuntu VPS 上运行：

```bash
version="$(tr -d '[:space:]' < VERSION)"
bash <(curl -fsSL "https://raw.githubusercontent.com/Elainaicey/keine/refs/tags/v${version}/install.sh")
keine version
keine doctor
keine status
```

继续验证软件详情、官方单项安装与移除、原生 WARP/wgcf 识别、终端切换与恢复、服务生命周期、备份、自更新和三种卸载模式。涉及 SSH、防火墙、WARP 或 Swap 的测试必须保留服务商控制台，并优先使用可随时回滚的测试实例。
