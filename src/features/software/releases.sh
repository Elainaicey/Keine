#!/usr/bin/env bash

OFFICIAL_RELEASE_CATALOG="${KEINE_RELEASE_CATALOG:-$CONFIG_DIR/official-releases.tsv}"
SOFTWARE_RELEASE_STATE_DIR="${KEINE_RELEASE_STATE_DIR:-$STATE_ROOT/software-releases}"
SOFTWARE_RELEASE_BIN_DIR="${KEINE_RELEASE_BIN_DIR:-/usr/local/bin}"
declare -Ag SOFTWARE_RELEASE_LATEST_CACHE=()
SOFTWARE_RELEASE_LATEST_VERSION=""
SOFTWARE_RELEASE_LATEST_ASSET=""
SOFTWARE_RELEASE_LATEST_DIGEST=""
SOFTWARE_RELEASE_LATEST_URL=""

software_release_record() {
  local id="$1"
  [[ -r "$OFFICIAL_RELEASE_CATALOG" ]] || { warn "官方 Release 目录不可读：$OFFICIAL_RELEASE_CATALOG"; return 1; }
  awk -F '|' -v wanted="$id" '!/^#/ && NF == 6 && $1 == wanted {print; found=1; exit} END {if (!found) exit 1}' \
    "$OFFICIAL_RELEASE_CATALOG"
}

software_release_field() {
  local id="$1" field="$2" record
  record="$(software_release_record "$id")" || return 1
  awk -F '|' -v field="$field" '{print $field}' <<<"$record"
}

software_release_command() { software_release_field "$1" 3; }
software_release_repository() { software_release_field "$1" 2; }
software_release_homepage() { software_release_field "$1" 6; }

software_release_asset_name() {
  local id="$1" version="$2" record _id _repository _command amd64_asset arm64_asset _homepage template
  record="$(software_release_record "$id")" || return 1
  IFS='|' read -r _id _repository _command amd64_asset arm64_asset _homepage <<<"$record"
  case "$ARCH" in
    amd64) template="$amd64_asset" ;;
    arm64) template="$arm64_asset" ;;
    *) warn "官方 Release 暂不支持当前架构：$ARCH"; return 1 ;;
  esac
  [[ -n "$template" ]] || { warn "$id 没有适用于 $ARCH 的官方资产。"; return 1; }
  printf '%s' "${template//\{version\}/$version}"
}

software_release_supported() {
  local id="$1"
  software_release_record "$id" >/dev/null 2>&1 || return 1
  case "$ARCH" in amd64|arm64) return 0 ;; *) return 1 ;; esac
}

software_release_marker() {
  local id="$1"
  [[ "$id" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
  printf '%s/%s.conf' "$SOFTWARE_RELEASE_STATE_DIR" "$id"
}

software_release_marker_value() {
  local id="$1" key="$2" marker
  marker="$(software_release_marker "$id")" || return 1
  [[ -f "$marker" && ! -L "$marker" ]] || return 1
  sed -n "s/^${key}=//p" "$marker" | head -n 1
}

software_release_target() {
  local id="$1" command
  command="$(software_release_command "$id")" || return 1
  [[ "$command" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || return 1
  printf '%s/%s' "$SOFTWARE_RELEASE_BIN_DIR" "$command"
}

software_release_version_output() {
  local id="$1" target="$2"
  case "$id" in
    actionlint) "$target" -version 2>&1 ;;
    *) "$target" --version 2>&1 ;;
  esac
}

software_release_managed() {
  local id="$1" repository command marker
  marker="$(software_release_marker "$id")" || return 1
  [[ -f "$marker" && ! -L "$marker" ]] || return 1
  repository="$(software_release_repository "$id")" || return 1
  command="$(software_release_command "$id")" || return 1
  [[ "$(software_release_marker_value "$id" source)" == "github-release" &&
    "$(software_release_marker_value "$id" repository)" == "$repository" &&
    "$(software_release_marker_value "$id" command)" == "$command" &&
    "$(software_release_marker_value "$id" path)" == "$(software_release_target "$id")" ]]
}

software_release_installed() {
  local id="$1" target
  software_release_managed "$id" || return 1
  target="$(software_release_target "$id")" || return 1
  [[ -f "$target" && ! -L "$target" && -x "$target" ]]
}

software_release_version() {
  software_release_managed "$1" || return 0
  software_release_marker_value "$1" version
}

software_release_integrity() {
  local id="$1" target expected actual
  software_release_installed "$id" || return 1
  target="$(software_release_target "$id")" || return 1
  expected="$(software_release_marker_value "$id" binary_sha256)"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
  actual="$(sha256sum "$target" 2>/dev/null | awk '{print $1}')"
  [[ "$actual" == "$expected" ]]
}

software_release_parse_latest() {
  local id="$1" json_file="$2" tag version asset repository details digest url
  [[ -r "$json_file" ]] || return 1
  tag="$(sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)",\{0,1\}$/\1/p' "$json_file" | head -n 1)"
  [[ "$tag" =~ ^v?[0-9][0-9A-Za-z._+-]*$ ]] || { warn "GitHub 返回了无效版本标签：${tag:-空}"; return 1; }
  version="${tag#v}"
  asset="$(software_release_asset_name "$id" "$version")" || return 1
  details="$(awk -v wanted="$asset" '
    /^[[:space:]]*"name":[[:space:]]*"/ {
      name=$0
      sub(/^[[:space:]]*"name":[[:space:]]*"/, "", name)
      sub(/".*$/, "", name)
      digest=""
    }
    name == wanted && /^[[:space:]]*"digest":[[:space:]]*"/ {
      digest=$0
      sub(/^[[:space:]]*"digest":[[:space:]]*"/, "", digest)
      sub(/".*$/, "", digest)
    }
    name == wanted && /^[[:space:]]*"browser_download_url":[[:space:]]*"/ {
      url=$0
      sub(/^[[:space:]]*"browser_download_url":[[:space:]]*"/, "", url)
      sub(/".*$/, "", url)
      print digest "|" url
      exit
    }
  ' "$json_file")"
  IFS='|' read -r digest url <<<"$details"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { warn "$asset 缺少可信的 SHA-256 digest。"; return 1; }
  repository="$(software_release_repository "$id")" || return 1
  [[ "$url" == "https://github.com/$repository/releases/download/"*"/$asset" ]] || {
    warn "官方资产下载地址与项目来源不匹配。"
    return 1
  }
  printf '%s|%s|%s|%s' "$version" "$asset" "${digest#sha256:}" "$url"
}

software_release_load_latest() {
  local id="$1" repository response result
  if [[ -n "${SOFTWARE_RELEASE_LATEST_CACHE[$id]:-}" ]]; then
    result="${SOFTWARE_RELEASE_LATEST_CACHE[$id]}"
  else
    command_exists curl || { warn "缺少 curl，无法查询官方 Release。"; return 1; }
    repository="$(software_release_repository "$id")" || return 1
    response="$(mktemp)" || { warn "无法创建 Release 元数据临时文件。"; return 1; }
    if ! curl --disable -fsSL --proto '=https' --proto-redir '=https' \
      --retry 2 --connect-timeout 8 --max-time 30 \
      --max-filesize 2097152 \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      "https://api.github.com/repos/$repository/releases/latest" -o "$response"; then
      rm -f "$response"
      warn "无法读取 $repository 的官方 Release。"
      return 1
    fi
    result="$(software_release_parse_latest "$id" "$response")" || { rm -f "$response"; return 1; }
    rm -f "$response"
    SOFTWARE_RELEASE_LATEST_CACHE["$id"]="$result"
  fi
  IFS='|' read -r SOFTWARE_RELEASE_LATEST_VERSION SOFTWARE_RELEASE_LATEST_ASSET \
    SOFTWARE_RELEASE_LATEST_DIGEST SOFTWARE_RELEASE_LATEST_URL <<<"$result"
}

software_release_write_marker() {
  local id="$1" version="$2" asset="$3" digest="$4" binary_digest="$5"
  local repository command target marker temporary
  repository="$(software_release_repository "$id")" || return 1
  command="$(software_release_command "$id")" || return 1
  target="$(software_release_target "$id")" || return 1
  marker="$(software_release_marker "$id")" || return 1
  safe_toolkit_path "$SOFTWARE_RELEASE_STATE_DIR" || { warn "Release 状态目录不安全。"; return 1; }
  [[ ! -L "$SOFTWARE_RELEASE_STATE_DIR" ]] || { warn "Release 状态目录不能是符号链接。"; return 1; }
  mkdir -p "$SOFTWARE_RELEASE_STATE_DIR" || { warn "无法创建 Release 状态目录。"; return 1; }
  temporary="$(mktemp "$SOFTWARE_RELEASE_STATE_DIR/.${id}.XXXXXX")" || { warn "无法创建 Release 状态文件。"; return 1; }
  if ! {
    printf 'source=github-release\n'
    printf 'repository=%s\n' "$repository"
    printf 'command=%s\n' "$command"
    printf 'path=%s\n' "$target"
    printf 'version=%s\n' "$version"
    printf 'asset=%s\n' "$asset"
    printf 'asset_sha256=%s\n' "$digest"
    printf 'binary_sha256=%s\n' "$binary_digest"
    printf 'installed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$temporary"; then
    rm -f "$temporary"
    warn "无法生成 Release 状态文件。"
    return 1
  fi
  chmod 0600 "$temporary" || { rm -f "$temporary"; warn "无法保护 Release 状态文件。"; return 1; }
  mv -f "$temporary" "$marker" || { rm -f "$temporary"; warn "无法保存 Release 状态文件。"; return 1; }
}

software_install_release() {
  local id="$1" mode="${2:-install}" version asset digest url target command
  local temporary archive extract listing binary binary_digest version_output previous="" had_previous=0
  software_release_supported "$id" || { warn "$id 没有适用于当前平台的官方 Release。"; return 1; }
  target="$(software_release_target "$id")" || return 1
  command="$(software_release_command "$id")" || return 1
  if [[ -e "$target" || -L "$target" ]]; then
    if ! software_release_managed "$id"; then
      [[ "$mode" == adopt && -f "$target" && ! -L "$target" ]] || {
        warn "$target 是外部安装；请从详情页选择来源切换并确认接管。"; return 1;
      }
      changes_prepare_file "$target" || return 1
    fi
    if software_release_managed "$id" && ! software_release_integrity "$id"; then
      [[ "$mode" == "repair" ]] || { warn "$target 已被修改，拒绝自动覆盖。"; return 1; }
      changes_prepare_file "$target" || { warn "无法登记 $target 的初始状态。"; return 1; }
    fi
  fi
  package_install ca-certificates curl tar gzip || return 1
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "将查询并安装 $id 的官方最新稳定 Release 到 $target，并验证 GitHub SHA-256 digest。"
    return 0
  fi
  software_release_load_latest "$id" || return 1
  version="$SOFTWARE_RELEASE_LATEST_VERSION"
  asset="$SOFTWARE_RELEASE_LATEST_ASSET"
  digest="$SOFTWARE_RELEASE_LATEST_DIGEST"
  url="$SOFTWARE_RELEASE_LATEST_URL"
  if software_release_installed "$id" && software_release_integrity "$id" &&
    [[ "$(software_release_version "$id")" == "$version" ]]; then
    info "$id 已经是官方最新稳定版 $version。"
    return 0
  fi
  temporary="$(mktemp -d)" || { warn "无法创建 Release 安装临时目录。"; return 1; }
  archive="$temporary/$asset"
  extract="$temporary/extract"
  listing="$temporary/archive.list"
  mkdir -p "$extract" || { rm -rf "$temporary"; warn "无法创建 Release 解压目录。"; return 1; }
  if ! curl --disable -fL --proto '=https' --proto-redir '=https' \
    --retry 3 --connect-timeout 10 --max-time 180 --max-filesize 134217728 "$url" -o "$archive"; then
    rm -rf "$temporary"
    warn "官方 Release 下载失败：$asset"
    return 1
  fi
  if ! printf '%s  %s\n' "$digest" "$archive" | sha256sum -c - >/dev/null; then
    rm -rf "$temporary"
    warn "官方 Release SHA-256 校验失败，已拒绝安装。"
    return 1
  fi
  tar -tzf "$archive" >"$listing" || { rm -rf "$temporary"; warn "无法读取 Release 压缩包目录。"; return 1; }
  if grep -Eq '(^/|(^|/)\.\.(/|$))' "$listing"; then
    rm -rf "$temporary"
    warn "Release 压缩包包含不安全路径，已拒绝解压。"
    return 1
  fi
  if (( $(wc -l <"$listing") > 5000 )); then
    rm -rf "$temporary"
    warn "Release 压缩包文件数量异常，已拒绝解压。"
    return 1
  fi
  if ! LC_ALL=C tar -tvzf "$archive" >"$temporary/archive.verbose"; then
    rm -rf "$temporary"
    warn "无法检查 Release 压缩包条目类型。"
    return 1
  fi
  if awk 'substr($1,1,1) != "-" && substr($1,1,1) != "d" {bad=1} END {exit !bad}' "$temporary/archive.verbose"; then
    rm -rf "$temporary"
    warn "Release 压缩包包含链接或特殊文件，已拒绝解压。"
    return 1
  fi
  if awk '$3 ~ /^[0-9]+$/ {total += $3} END {exit total <= 536870912}' "$temporary/archive.verbose"; then
    rm -rf "$temporary"
    warn "Release 压缩包展开体积超过安全限制。"
    return 1
  fi
  tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$extract" || {
    rm -rf "$temporary"; warn "Release 解压失败。"; return 1;
  }
  local binaries=()
  mapfile -t binaries < <(find "$extract" -type f -name "$command" -print)
  ((${#binaries[@]} == 1)) || {
    rm -rf "$temporary"
    warn "Release 中没有找到唯一的 $command 可执行文件。"
    return 1
  }
  binary="${binaries[0]}"
  [[ -f "$binary" && ! -L "$binary" ]] || { rm -rf "$temporary"; warn "Release 可执行文件类型不安全。"; return 1; }
  [[ -d "$SOFTWARE_RELEASE_BIN_DIR" && ! -L "$SOFTWARE_RELEASE_BIN_DIR" ]] || {
    rm -rf "$temporary"; warn "命令安装目录不存在或类型不安全：$SOFTWARE_RELEASE_BIN_DIR"; return 1;
  }
  if [[ -f "$target" && ! -L "$target" ]]; then
    previous="$temporary/previous"
    cp -a "$target" "$previous" || { rm -rf "$temporary"; warn "无法暂存当前版本。"; return 1; }
    had_previous=1
  fi
  if declare -F changes_prepare_file >/dev/null; then
    changes_prepare_file "$target" || { rm -rf -- "$temporary"; return 1; }
  fi
  install -m 0755 "$binary" "$target" || { rm -rf "$temporary"; warn "无法安装 $target。"; return 1; }
  version_output="$(software_release_version_output "$id" "$target" || true)"
  if ! grep -Fq "$version" <<<"$version_output"; then
    if (( had_previous == 1 )); then install -m 0755 "$previous" "$target" || true; else rm -f "$target"; fi
    rm -rf "$temporary"
    warn "$command 安装后版本验证失败。"
    return 1
  fi
  binary_digest="$(sha256sum "$target" | awk '{print $1}')"
  if ! software_release_write_marker "$id" "$version" "$asset" "$digest" "$binary_digest"; then
    if (( had_previous == 1 )); then install -m 0755 "$previous" "$target" || true; else rm -f "$target"; fi
    rm -rf "$temporary"
    return 1
  fi
  rm -rf "$temporary"
  software_release_integrity "$id" || { warn "$id 安装后完整性验证失败。"; return 1; }
}

software_update_release() {
  local id="$1" current latest
  software_release_installed "$id" || { warn "$id 尚未由 keine 官方 Release 安装器管理。"; return 1; }
  software_release_integrity "$id" || { warn "$id 的托管二进制已被修改，拒绝自动更新。"; return 1; }
  current="$(software_release_version "$id")"
  software_release_load_latest "$id" || return 1
  latest="$SOFTWARE_RELEASE_LATEST_VERSION"
  if ! dpkg --compare-versions "$latest" gt "$current"; then
    info "$id 已经是官方最新稳定版 $current。"
    return 0
  fi
  software_install_release "$id"
}

software_repair_release() {
  local id="$1"
  software_release_managed "$id" || { warn "$id 不由 keine 官方 Release 安装器管理。"; return 1; }
  software_install_release "$id" repair
}

software_remove_release() {
  local id="$1" target marker
  software_release_managed "$id" || { warn "$id 不由 keine 官方 Release 安装器管理。"; return 1; }
  software_release_integrity "$id" || { warn "$id 的托管二进制已被修改，拒绝自动删除。"; return 1; }
  target="$(software_release_target "$id")" || return 1
  marker="$(software_release_marker "$id")" || return 1
  if [[ "$DRY_RUN" -eq 1 ]]; then info "将删除托管命令 $target 和状态文件 $marker。"; return 0; fi
  if declare -F changes_prepare_file >/dev/null; then changes_prepare_file "$target" || return 1; fi
  rm -f -- "$target" || { warn "无法删除 $target。"; return 1; }
  rm -f -- "$marker" || { warn "无法删除 $id 的 Release 状态文件。"; return 1; }
  [[ ! -e "$target" && ! -L "$target" ]] || { warn "$target 删除后仍然存在。"; return 1; }
}
