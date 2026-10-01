#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
cd "$ROOT_DIR"

printf '[tests] 离线单元测试\n'
for test_file in tests/test_*.sh; do
  bash "$test_file"
done

printf '[tests] 声明式目录格式\n'
for catalog_file in config/software.tsv config/apps.tsv config/software-effects.tsv config/official-releases.tsv; do
  awk -F '|' -v catalog="$catalog_file" '
    !/^#/ && NF != 6 { print "invalid catalog line " catalog ":" NR; failed=1 }
    END { exit failed }
  ' "$catalog_file"
done
awk -F '|' '
  FNR == NR {
    if ($0 !~ /^#/ && NF == 6) software[$1]=1
    next
  }
  $0 !~ /^#/ && NF == 6 {
    if (!software[$1]) { print "unknown software effect id " $1; failed=1 }
    if (seen[$1]++) { print "duplicate software effect id " $1; failed=1 }
    if ($2 != "service" && $2 != "scheduled" && $2 != "service+scheduled" && $2 != "boot-hook") {
      print "invalid software effect runtime " $1; failed=1
    }
    if ($4 != "none" && $4 != "timer" && $4 != "cron" && $4 != "timer-or-cron") {
      print "invalid software effect scheduler " $1; failed=1
    }
    if ($5 != "none" && $5 != "local-socket" && $5 != "tcp-listener" &&
        $5 != "tcp-udp-listener" && $5 != "outbound") {
      print "invalid software effect network " $1; failed=1
    }
  }
  END { exit failed }
' config/software.tsv config/software-effects.tsv

printf '[tests] CLI 冒烟测试\n'
expected_version="$(tr -d '[:space:]' < VERSION)"
[[ "$(bash bin/serverctl version)" == "Server Toolkit $expected_version" ]]
[[ "$(bash bin/serverctl --version)" == "Server Toolkit $expected_version" ]]
bash bin/serverctl --help | grep -q '一次只接受一个软件 ID'
bash bin/serverctl --help | grep -q 'update ID'
bash bin/serverctl --help | grep -q 'software \[ID\]'
bash bin/serverctl --help | grep -q 'sources'
bash bin/serverctl --help | grep -q 'official-updates'
bash bin/serverctl --help | grep -q 'exposure'
bash bin/serverctl --help | grep -q 'doctor'
bash bin/serverctl --help | grep -q 'triage'
bash bin/serverctl --help | grep -q 'probe HOST PORT'
bash bin/serverctl --help | grep -q 'http URL'
bash bin/serverctl --help | grep -q 'auth-activity'
bash bin/serverctl --help | grep -q 'app ID'
bash bin/serverctl --help | grep -q 'dns \[域名\]'
bash bin/serverctl --help | grep -q 'logs SERVICE'
if bash bin/serverctl --help | grep -Eq 'serverctl (health|toolkit-doctor|users|user |timer )'; then
  printf 'FAIL: CLI 帮助仍包含已移除的重复或多用户入口\n' >&2
  exit 1
fi
bash install.sh --help | grep -q 'Server Toolkit 安装器'
bash scripts/install.sh --help | grep -q -- '--purge-data'

printf 'PASS: tests\n'
