#!/usr/bin/env bash

APPS_SERVICE_CATALOG="${KEINE_APPS_CATALOG:-${CONFIG_DIR:-$ROOT_DIR/config}/apps.tsv}"

apps_service_catalog() {
  [[ -r "$APPS_SERVICE_CATALOG" ]] || return 1
  awk -F '|' '!/^#/ && NF == 6' "$APPS_SERVICE_CATALOG"
}

apps_service_record() {
  local number="$1"
  [[ "$number" =~ ^[0-9]+$ ]] || return 1
  apps_service_catalog | awk -F '|' -v number="$number" 'NR == number {print; found=1; exit} END {if (!found) exit 1}'
}

apps_service_record_by_id() {
  local app_id="$1"
  apps_service_catalog | awk -F '|' -v wanted="$app_id" '$1 == wanted {print; found=1; exit} END {if (!found) exit 1}'
}

apps_service_field() {
  local app_id="$1" field="$2" record
  [[ "$field" =~ ^[1-6]$ ]] || return 1
  record="$(apps_service_record_by_id "$app_id")" || return 1
  awk -F '|' -v field="$field" '{print $field}' <<<"$record"
}

apps_service_label() { apps_service_field "$1" 2; }
apps_service_unit() { apps_service_field "$1" 3; }
apps_service_catalog_id() { apps_service_field "$1" 4; }
apps_service_package() { apps_service_field "$1" 5; }
apps_service_config_paths() {
  case "$1" in
    docker) printf '%s\n' /etc/docker/daemon.json /etc/docker ;;
    nginx) printf '%s\n' /etc/nginx/nginx.conf /etc/nginx/conf.d /etc/nginx/sites-enabled ;;
    caddy) printf '%s\n' /etc/caddy/Caddyfile /etc/caddy ;;
    apache) printf '%s\n' /etc/apache2/apache2.conf /etc/apache2/sites-enabled /etc/apache2/mods-enabled ;;
    haproxy) printf '%s\n' /etc/haproxy/haproxy.cfg /etc/haproxy ;;
    redis) printf '%s\n' /etc/redis/redis.conf /etc/redis ;;
    memcached) printf '%s\n' /etc/memcached.conf ;;
    postgresql) printf '%s\n' /etc/postgresql ;;
    mariadb) printf '%s\n' /etc/mysql/mariadb.conf.d /etc/mysql/my.cnf ;;
    mosquitto) printf '%s\n' /etc/mosquitto/mosquitto.conf /etc/mosquitto/conf.d ;;
    x-ui) printf '%s\n' /etc/x-ui ;;
    *) return 1 ;;
  esac
}

apps_service_data_paths() {
  case "$1" in
    docker) printf '%s\n' /var/lib/docker ;;
    nginx) printf '%s\n' /var/log/nginx ;;
    caddy) printf '%s\n' /var/lib/caddy /var/log/caddy ;;
    apache) printf '%s\n' /var/log/apache2 ;;
    haproxy) printf '%s\n' /var/lib/haproxy /var/log/haproxy.log ;;
    redis) printf '%s\n' /var/lib/redis /var/log/redis ;;
    memcached) printf '%s\n' /var/log/memcached.log ;;
    postgresql) printf '%s\n' /var/lib/postgresql /var/log/postgresql ;;
    mariadb) printf '%s\n' /var/lib/mysql /var/log/mysql ;;
    mosquitto) printf '%s\n' /var/lib/mosquitto /var/log/mosquitto ;;
    x-ui) printf '%s\n' /etc/x-ui/x-ui.db ;;
    *) return 1 ;;
  esac
}

apps_service_config_validation_supported() {
  case "$1" in nginx|caddy|apache|haproxy|docker) return 0 ;; *) return 1 ;; esac
}

apps_service_reload_supported() {
  case "$1" in nginx|caddy|apache|haproxy) return 0 ;; *) return 1 ;; esac
}
