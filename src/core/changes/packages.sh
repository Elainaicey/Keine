#!/usr/bin/env bash

changes_package_inventory() {
  dpkg-query -W -f='${binary:Package}|${db:Status-Status}|${Version}\n' 2>/dev/null |
    awk -F '|' '$2=="installed" {print $1 "|" $3}' | LC_ALL=C sort
}

changes_packages_record_new() {
  local before="$1" package version is_new marker
  changes_ready || return 0
  changes_storage_ready || return 1
  while IFS='|' read -r package version is_new; do
    valid_package_name "$package" || return 1
    marker="$(changes_root)/packages/$package"
    [[ "$is_new" == 1 || -f "$marker" ]] || continue
    [[ ! -L "$marker" ]] || return 1
    printf '%s\n' "$version" >"$marker" || return 1
  done < <(awk -F '|' 'FILENAME==ARGV[1] {old[$1]=$2;next} !old[$1] || old[$1]!=$2 {print $0 "|" (!old[$1] ? 1 : 0)}' "$before" <(changes_package_inventory))
}

declare -ag CHANGES_PACKAGE_TARGETS=()

changes_packages_plan() {
  local marker package version plan removed failed=0
  local -A owned=()
  CHANGES_PACKAGE_TARGETS=()
  [[ -d "$(changes_root)/packages" ]] || return 0
  for marker in "$(changes_root)"/packages/*; do
    [[ -f "$marker" && ! -L "$marker" ]] || continue
    package="${marker##*/}"; valid_package_name "$package" || return 1
    if ! package_installed "$package"; then
      continue
    fi
    version="$(package_installed_version "$package")"
    if [[ "$version" != "$(<"$marker")" ]]; then warn "保留后来被更新的软件包：$package"; failed=1; continue; fi
    owned["$package"]=1; CHANGES_PACKAGE_TARGETS+=("$package")
  done
  (( failed == 0 )) || return 1
  ((${#CHANGES_PACKAGE_TARGETS[@]} > 0)) || return 0
  plan="$(LC_ALL=C apt-get -s -o Debug::NoLocking=1 purge "${CHANGES_PACKAGE_TARGETS[@]}" 2>&1)" || { warn "无法验证软件包撤销计划。"; return 1; }
  while IFS= read -r removed; do
    [[ -n "${owned[$removed]:-}" ]] || { warn "撤销会连带删除原有软件包 $removed，已停止。"; return 1; }
  done < <(awk '/^(Remv|Purg) / {print $2}' <<<"$plan")
}

changes_packages_remove() {
  local package marker failed=0
  changes_packages_plan || return 1
  if ((${#CHANGES_PACKAGE_TARGETS[@]} > 0)); then
    ui_note "将移除 ${#CHANGES_PACKAGE_TARGETS[@]} 个由项目新增的软件包（包括新增依赖）；不执行 autoremove。"
    confirm "按验证过的计划移除这些新增软件包？" || return 1
    apt_run purge -y "${CHANGES_PACKAGE_TARGETS[@]}" || return 1
  fi
  (( DRY_RUN == 1 )) && return 0
  for marker in "$(changes_root)"/packages/*; do
    [[ -f "$marker" && ! -L "$marker" ]] || continue
    package="${marker##*/}"
    if package_installed "$package"; then failed=1; else rm -f -- "$marker"; fi
  done
  (( failed == 0 ))
}
