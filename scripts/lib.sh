#!/usr/bin/env bash
# Общие функции для скриптов CHOKEPOINT. Подключается через `source`.
# shellcheck shell=bash

# cron запускает задачи с минимальным PATH — добавляем стандартные каталоги явно.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

# Каталог проекта вычисляется от расположения скрипта, а не от текущего каталога.
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export PROJECT_DIR
LOG_DIR="$PROJECT_DIR/logs"

die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }

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
