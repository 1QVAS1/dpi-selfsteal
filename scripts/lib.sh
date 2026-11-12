#!/usr/bin/env bash
# Общие функции для скриптов сайта. Подключается через `source`.
# shellcheck shell=bash

# cron запускает задачи с минимальным PATH — добавляем стандартные каталоги явно.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

# Каталог установки. По умолчанию — тот, где лежат скрипты (рекомендуемый путь: /opt/site).
# Переменная окружения INSTALL_DIR задаёт его явно — одна для всех скриптов.
PROJECT_DIR="${INSTALL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
PROJECT_DIR="${PROJECT_DIR%/}"
export PROJECT_DIR
LOG_DIR="$PROJECT_DIR/logs"

die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }

if [[ -n "${INSTALL_DIR:-}" && ! -f "$PROJECT_DIR/docker-compose.yml" ]]; then
  die "INSTALL_DIR=$INSTALL_DIR: в каталоге нет docker-compose.yml — укажите каталог, куда склонирован репозиторий"
fi

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "не найдена команда '$c' (PATH=$PATH)"
  done
}

require_compose() {
  require_cmd docker
  docker compose version >/dev/null 2>&1 || die "нужен Docker Compose v2 (команда 'docker compose')"
}

# Читает переменную из .env без выполнения файла как кода.
env_get() {
  local key="$1" file="$PROJECT_DIR/.env" line val
  [[ -f "$file" ]] || return 1
  line="$(grep -E "^[[:space:]]*${key}=" "$file" | tail -n 1)" || return 1
  val="${line#*=}"
  val="${val%$'\r'}"
  val="${val#\"}"; val="${val%\"}"
  val="${val#\'}"; val="${val%\'}"
  printf '%s' "$val"
}

load_env() {
  [[ -f "$PROJECT_DIR/.env" ]] || die "нет файла .env — выполните: cp .env.example .env и заполните DOMAIN и LETSENCRYPT_EMAIL"
  DOMAIN="$(env_get DOMAIN || true)"
  LETSENCRYPT_EMAIL="$(env_get LETSENCRYPT_EMAIL || true)"
  [[ -n "$DOMAIN" ]] || die "в .env не задан DOMAIN"
  [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "DOMAIN содержит недопустимые символы: '$DOMAIN'"
  export DOMAIN LETSENCRYPT_EMAIL
}

# docker compose из каталога проекта
dc() { (cd "$PROJECT_DIR" && docker compose "$@"); }

# одноразовый запуск контейнера certbot (сервис под profile "certbot")
certbot_run() { dc --profile certbot run --rm -T "$@"; }

# Состояние сертификата в томе letsencrypt: production | staging | dummy | none
cert_state() {
  certbot_run --entrypoint sh certbot -c '
    f="/etc/letsencrypt/renewal/${DOMAIN}.conf"
    if [ -f "$f" ]; then
      if grep -q "acme-staging" "$f"; then echo staging; else echo production; fi
    elif [ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
      echo dummy
    else
      echo none
    fi' 2>/dev/null | tr -d '\r' | tail -n 1
}

# SHA-256 файла fullchain.pem (пусто, если файла нет)
cert_fingerprint() {
  certbot_run --entrypoint sh certbot -c \
    'f="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"; [ -f "$f" ] && sha256sum "$f" | cut -d" " -f1 || true' \
    2>/dev/null | tr -d '\r' | tail -n 1
}

web_running() {
  [[ -n "$(dc ps --status running -q web 2>/dev/null)" ]]
}

# Записывает KEY=VALUE в .env: заменяет существующую строку или добавляет в конец.
env_set() {
  local key="$1" value="$2" file="$PROJECT_DIR/.env" tmp
  [[ -f "$file" ]] || die "нет файла .env"
  tmp="$(mktemp "$file.XXXXXX")"
  awk -v k="$key" -v v="$value" '
    BEGIN { done = 0 }
    { sub(/\r$/, "") }
    $0 ~ "^[[:space:]]*" k "=" { if (!done) { print k "=" v; done = 1 }; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$file" >"$tmp" && cat "$tmp" >"$file"
  rm -f "$tmp"
}

# Удаляет строку KEY=… из .env (если есть).
env_unset() {
  local key="$1" file="$PROJECT_DIR/.env" tmp
  [[ -f "$file" ]] || return 0
  tmp="$(mktemp "$file.XXXXXX")"
  awk -v k="$key" '{ sub(/\r$/, "") } $0 !~ "^[[:space:]]*" k "=" { print }' "$file" >"$tmp" && cat "$tmp" >"$file"
  rm -f "$tmp"
}

# Имя Docker-проекта: из COMPOSE_PROJECT_NAME в .env или из `name:` в docker-compose.yml.
compose_project() {
  local p
  p="$(env_get COMPOSE_PROJECT_NAME || true)"
  printf '%s' "${p:-site}"
}

# Старые установки назывались «chokepoint», и сертификат лежит в томе chokepoint_letsencrypt.
# Если он есть, а тома нового проекта нет — сертификат не перенесён (README, «Миграция
# со старого пути»). Печатает подсказку и возвращает 0, если перенос нужен.
legacy_volume_hint() {
  local project new="" old="chokepoint_letsencrypt"
  project="$(compose_project)"
  [[ "$project" == "chokepoint" ]] && return 1
  new="${project}_letsencrypt"
  docker volume inspect "$old" >/dev/null 2>&1 || return 1
  docker volume inspect "$new" >/dev/null 2>&1 && return 1
  cat >&2 <<MSG
Найден сертификат старой установки (том $old), а тома $new нет.
Перенесите сертификат, чтобы не выпускать его заново (README, «Миграция со старого пути»):
  docker volume create $new
  docker run --rm -v $old:/from:ro -v $new:/to alpine cp -a /from/. /to/
MSG
  return 0
}
