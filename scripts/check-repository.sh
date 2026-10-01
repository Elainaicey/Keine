#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
cd "$ROOT_DIR"

mapfile -t repository_files < <(
  while IFS= read -r file; do
    [[ -e "$file" || -L "$file" ]] && printf '%s\n' "$file"
  done < <(git ls-files --cached --others --exclude-standard | LC_ALL=C sort -u)
)
(( ${#repository_files[@]} > 0 )) || {
  printf 'FAIL: 仓库中没有可检查文件\n' >&2
  exit 1
}

declare -A category_counts=()
classification_failed=0

printf '[repository] 文件分类与 Git 属性\n'
for file in "${repository_files[@]}"; do
  category=""
  case "$file" in
    install.sh|*.sh|bin/serverctl) category="shell" ;;
    *.md) category="markdown" ;;
    .github/workflows/*.yml) category="workflow" ;;
    .github/assets/badges/*.svg) category="svg" ;;
    *.tsv) category="catalog" ;;
    .gitattributes|.gitignore|LICENSE|VERSION) category="metadata" ;;
    *)
      printf 'FAIL: 未归类文件：%s\n' "$file" >&2
      classification_failed=1
      continue
      ;;
  esac

  if [[ ! -f "$file" || -L "$file" ]]; then
    printf 'FAIL: 文件必须是普通文件且不能是符号链接：%s\n' "$file" >&2
    classification_failed=1
    continue
  fi

  mode="$(git ls-files -s -- "$file" | awk 'NR==1 {print $1}')"
  if [[ -n "$mode" && "$mode" != "100644" ]]; then
    printf 'FAIL: 文件模式必须为 100644：%s (%s)\n' "$file" "$mode" >&2
    classification_failed=1
  fi

  eol="$(git check-attr eol -- "$file" | sed 's/^.*: //')"
  if [[ "$eol" != "lf" ]]; then
    printf 'FAIL: 文件没有声明 LF 换行：%s (%s)\n' "$file" "${eol:-unspecified}" >&2
    classification_failed=1
  fi

  category_counts["$category"]=$(( ${category_counts[$category]:-0} + 1 ))
done

(( classification_failed == 0 )) || exit 1

python_bin="$(command -v python3 || command -v python || true)"
[[ -n "$python_bin" ]] || {
  printf 'FAIL: 全文件验证需要 Python 3\n' >&2
  exit 1
}
"$python_bin" -c 'import sys; raise SystemExit(sys.version_info < (3, 8))' || {
  printf 'FAIL: 全文件验证需要 Python 3.8 或更高版本\n' >&2
  exit 1
}

printf '[repository] UTF-8、LF、尾随空白与内部链接\n'
"$python_bin" - "${repository_files[@]}" <<'PY'
from __future__ import annotations

import re
import sys
import urllib.parse
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path.cwd().resolve()
paths = [Path(value) for value in sys.argv[1:]]
failures: list[str] = []
seen_casefold: dict[str, str] = {}
link_pattern = re.compile(r"]\(([^)]+)\)")

for path in paths:
    folded = path.as_posix().casefold()
    if folded in seen_casefold:
        failures.append(
            f"大小写不敏感文件名冲突：{seen_casefold[folded]} / {path.as_posix()}"
        )
    else:
        seen_casefold[folded] = path.as_posix()

    data = path.read_bytes()
    if not data:
        failures.append(f"空文件：{path.as_posix()}")
        continue
    if data.startswith(b"\xef\xbb\xbf"):
        failures.append(f"不允许 UTF-8 BOM：{path.as_posix()}")
    if b"\x00" in data:
        failures.append(f"文本仓库中出现 NUL 字节：{path.as_posix()}")
    if b"\r" in data:
        failures.append(f"检测到 CR/CRLF 换行：{path.as_posix()}")
    if not data.endswith(b"\n"):
        failures.append(f"文件末尾缺少换行：{path.as_posix()}")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        failures.append(f"不是有效 UTF-8：{path.as_posix()} ({error})")
        continue

    for number, line in enumerate(text.splitlines(), 1):
        if line.endswith((" ", "\t")):
            failures.append(f"尾随空白：{path.as_posix()}:{number}")

    repository_path = path.as_posix()
    if (
        path.suffix == ".sh" or repository_path == "bin/serverctl"
    ) and (
        repository_path == "install.sh"
        or repository_path.startswith(("scripts/", "src/"))
    ):
        logical_shell = re.sub(r"\\\n[ \t]*", " ", text)
        curl_command_pattern = re.compile(
            r"(?:^|[;&|()]|\$\()\s*"
            r"(?:(?:if|elif|while|until)\s+)?!?\s*"
            r"curl\s+(?!--disable(?:\s|$))"
        )
        for number, line in enumerate(logical_shell.splitlines(), 1):
            if curl_command_pattern.search(line):
                failures.append(
                    f"curl 网络调用必须以 --disable 作为首个参数："
                    f"{repository_path}:{number}"
                )

    suffix = path.suffix.lower()
    if suffix == ".md":
        if not any(line.startswith("# ") for line in text.splitlines()):
            failures.append(f"Markdown 缺少一级标题：{path.as_posix()}")
        for raw_target in link_pattern.findall(text):
            target = raw_target.strip().strip("<>")
            if not target or target.startswith(("#", "http://", "https://", "mailto:")):
                continue
            target = target.split(maxsplit=1)[0].split("#", 1)[0]
            target = urllib.parse.unquote(target)
            resolved = (path.parent / target).resolve()
            try:
                resolved.relative_to(root)
            except ValueError:
                failures.append(f"Markdown 链接越出仓库：{path.as_posix()} -> {target}")
                continue
            if not resolved.exists():
                failures.append(f"Markdown 内部链接不存在：{path.as_posix()} -> {target}")

    elif suffix == ".svg":
        try:
            svg_root = ET.fromstring(text)
            if not svg_root.tag.endswith("svg"):
                failures.append(f"SVG 根元素无效：{path.as_posix()}")
        except ET.ParseError as error:
            failures.append(f"SVG XML 无效：{path.as_posix()} ({error})")

    elif path.as_posix().startswith(".github/workflows/"):
        required = ("name:", "on:", "jobs:")
        for key in required:
            if not any(line.startswith(key) for line in text.splitlines()):
                failures.append(f"工作流缺少顶层 {key}：{path.as_posix()}")

    elif suffix == ".tsv":
        rows: list[tuple[int, list[str]]] = []
        for number, line in enumerate(text.splitlines(), 1):
            if line.startswith("#") or not line:
                continue
            fields = line.split("|")
            if len(fields) != 6:
                failures.append(f"声明式目录字段数不是 6：{path.as_posix()}:{number}")
                continue
            rows.append((number, fields))
        if path.as_posix() in {"config/navigation.tsv", "config/terminal.tsv", "config/integrations.tsv"}:
            identifiers: set[str] = set()
            handlers = {
                "config/navigation.tsv": {"dashboard_menu", "system_menu", "network_menu", "security_menu", "services_menu", "software_catalog_menu", "apps_menu", "terminal_menu", "recovery_menu", "toolkit_menu"},
                "config/terminal.tsv": {"oh_my_zsh", "starship", "oh-my-posh", "spaceship"},
                "config/integrations.tsv": {"warp_menu", "network_tuning_adapter_menu"},
            }
            numbers: set[str] = set()
            for number, fields in rows:
                identifier = fields[1] if path.name == "navigation.tsv" else fields[0]
                handler = fields[4] if path.name != "terminal.tsv" else fields[3]
                if identifier in identifiers or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", identifier):
                    failures.append(f"注册 ID 重复或无效：{path.as_posix()}:{number}")
                identifiers.add(identifier)
                if not all(fields) or handler not in handlers[path.as_posix()]:
                    failures.append(f"注册字段或执行白名单无效：{path.as_posix()}:{number}")
                if path.name == "navigation.tsv":
                    if fields[0] in numbers or not re.fullmatch(r"[1-9][0-9]?", fields[0]):
                        failures.append(f"导航编号重复或无效：{number}")
                    numbers.add(fields[0])
                elif path.name == "terminal.tsv" and not fields[4].startswith("https://github.com/"):
                    failures.append(f"终端项目来源无效：{number}")
        elif path.as_posix() == "config/network-tuning.tsv":
            allowed_keys = {
                "net.ipv4.tcp_mtu_probing", "net.ipv4.tcp_fastopen",
                "net.ipv4.tcp_keepalive_time", "net.ipv4.tcp_keepalive_intvl",
                "net.ipv4.tcp_keepalive_probes", "net.core.rmem_max", "net.core.wmem_max",
            }
            tuning_keys: set[str] = set()
            for number, fields in rows:
                key, label, minimum, maximum, reference, description = fields
                if key not in allowed_keys or key in tuning_keys:
                    failures.append(f"网络参数键重复或不在白名单：{path.as_posix()}:{number}")
                tuning_keys.add(key)
                if not label or not description:
                    failures.append(f"网络参数说明为空：{path.as_posix()}:{number}")
                if not all(re.fullmatch(r"[0-9]{1,9}", value) for value in (minimum, maximum, reference)):
                    failures.append(f"网络参数范围必须为整数：{path.as_posix()}:{number}")
                elif not int(minimum) <= int(reference) <= int(maximum):
                    failures.append(f"网络参数参考值不在范围内：{path.as_posix()}:{number}")
        elif path.as_posix() == "config/apps.tsv":
            app_ids: set[str] = set()
            app_units: set[str] = set()
            for number, fields in rows:
                app_id, name, unit, catalog_id, package, category = fields
                if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", app_id):
                    failures.append(f"应用 ID 无效：{path.as_posix()}:{number}")
                if app_id in app_ids:
                    failures.append(f"应用 ID 重复：{app_id}")
                app_ids.add(app_id)
                if not name or not unit.endswith(".service") or not category:
                    failures.append(f"应用必填字段无效：{path.as_posix()}:{number}")
                if unit in app_units:
                    failures.append(f"应用 systemd Unit 重复：{unit}")
                app_units.add(unit)
                if catalog_id and not re.fullmatch(r"[a-z0-9][a-z0-9-]*", catalog_id):
                    failures.append(f"应用软件目录 ID 无效：{path.as_posix()}:{number}")
                if package and not re.fullmatch(r"[a-z0-9][a-z0-9+.-]*", package):
                    failures.append(f"应用系统包名无效：{path.as_posix()}:{number}")
        elif path.as_posix() == "config/software-effects.tsv":
            software_ids = {
                line.split("|", 1)[0]
                for line in Path("config/software.tsv").read_text(encoding="utf-8").splitlines()
                if line and not line.startswith("#")
            }
            effect_ids: set[str] = set()
            runtime_values = {"service", "scheduled", "service+scheduled", "boot-hook"}
            scheduler_values = {"none", "timer", "cron", "timer-or-cron"}
            network_values = {
                "none", "local-socket", "tcp-listener", "tcp-udp-listener", "outbound"
            }
            unit_pattern = re.compile(
                r"[A-Za-z0-9@_.-]+\.(?:service|socket|timer)"
                r"(?:,[A-Za-z0-9@_.-]+\.(?:service|socket|timer))*"
            )
            for number, fields in rows:
                effect_id, runtime, units, scheduler, network, note = fields
                if effect_id in effect_ids:
                    failures.append(f"软件运行影响 ID 重复：{effect_id}")
                effect_ids.add(effect_id)
                if effect_id not in software_ids:
                    failures.append(f"软件运行影响引用未知 ID：{effect_id}")
                if runtime not in runtime_values:
                    failures.append(f"软件运行形态无效：{path.as_posix()}:{number}")
                if units != "-" and not unit_pattern.fullmatch(units):
                    failures.append(f"软件运行影响 Unit 无效：{path.as_posix()}:{number}")
                if scheduler not in scheduler_values:
                    failures.append(f"软件调度方式无效：{path.as_posix()}:{number}")
                if network not in network_values:
                    failures.append(f"软件网络行为无效：{path.as_posix()}:{number}")
                if not note:
                    failures.append(f"软件运行影响说明为空：{path.as_posix()}:{number}")

if failures:
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    raise SystemExit(1)
PY

if command -v yamllint >/dev/null 2>&1; then
  printf '[repository] YAML 语法与格式\n'
  yamllint -d '{extends: default, rules: {document-start: disable, line-length: disable, truthy: disable}}' .github/workflows
elif [[ "${REQUIRE_YAMLLINT:-0}" == "1" ]]; then
  printf 'FAIL: 当前检查要求 yamllint，但系统中没有该命令\n' >&2
  exit 1
else
  printf '[repository] 未安装 yamllint，仅执行内置工作流结构检查\n'
fi

printf '[repository] 项目元数据\n'
version="$(tr -d '[:space:]' < VERSION)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'FAIL: VERSION 不是语义版本：%s\n' "$version" >&2
  exit 1
}
grep -Fqx "## $version" docs/CHANGELOG.md || {
  printf 'FAIL: docs/CHANGELOG.md 缺少 %s 发布章节\n' "$version" >&2
  exit 1
}
grep -Fq 'MIT License' LICENSE || {
  printf 'FAIL: LICENSE 不是 MIT License\n' >&2
  exit 1
}
grep -Fq 'Copyright (c) 2026 Elainaicey' LICENSE || {
  printf 'FAIL: LICENSE 缺少项目版权声明\n' >&2
  exit 1
}
grep -Fq "$version" .github/assets/badges/version.svg || {
  printf 'FAIL: 版本徽章与 VERSION 不一致\n' >&2
  exit 1
}
if grep -Fq 'img.shields.io' README.md; then
  printf 'FAIL: README 不应依赖第三方 Shields.io 徽章\n' >&2
  exit 1
fi

for category in shell markdown workflow svg catalog metadata; do
  printf '  %-10s %s\n' "$category" "${category_counts[$category]:-0}"
done
printf 'PASS: repository files (%s)\n' "${#repository_files[@]}"
