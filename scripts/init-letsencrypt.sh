#!/usr/bin/env bash
# Первичный выпуск сертификата Let's Encrypt для DOMAIN из .env.
#
#   scripts/init-letsencrypt.sh --staging   # проба на тестовом сервере LE (без лимитов)
#   scripts/init-letsencrypt.sh             # настоящий сертификат
#   scripts/init-letsencrypt.sh --force     # выпустить заново, даже если сертификат уже есть
#
# Что делает:
#   1) создаёт временный самоподписанный сертификат, чтобы nginx мог стартовать на 443;
#   2) запускает nginx (сервис web) — он отдаёт /.well-known/acme-challenge/ на 80-м порту;
#   3) удаляет временный сертификат и получает настоящий через certbot (webroot);
#   4) перезагружает nginx.
# Скрипт идемпотентен: если нужный сертификат уже выпущен, он только убеждается, что nginx запущен.
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STAGING=0
FORCE=0
usage() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --staging) STAGING=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "неизвестный аргумент: $1" ;;
  esac
  shift
done

require_compose
load_env
[[ -n "$LETSENCRYPT_EMAIL" ]] || die "в .env не задан LETSENCRYPT_EMAIL"
if [[ "$DOMAIN" == "example.org" || "$LETSENCRYPT_EMAIL" == *"@example.org" ]]; then
  die "в .env остались значения из примера — укажите свой домен и почту"
fi

want="production"; [[ $STAGING -eq 1 ]] && want="staging"
log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

wait_for_nginx() {
  local i
  for i in $(seq 1 30); do
    if dc exec -T web wget -q -O /dev/null http://127.0.0.1/healthz 2>/dev/null; then return 0; fi
    sleep 1
  done
  dc logs --tail 30 web >&2 || true
  die "nginx не ответил на /healthz за 30 секунд"
}

make_dummy() {
  log "Создаю временный самоподписанный сертификат для $DOMAIN"
  certbot_run --entrypoint python3 certbot /opt/chokepoint/selfsigned.py \
    --out "/etc/letsencrypt/live/$DOMAIN" --cn "$DOMAIN" --days 1 >/dev/null
}

remove_cert_files() {
  certbot_run --entrypoint sh certbot -c \
    'rm -rf "/etc/letsencrypt/live/${DOMAIN}" "/etc/letsencrypt/archive/${DOMAIN}" "/etc/letsencrypt/renewal/${DOMAIN}.conf"'
}

state="$(cert_state)"
log "Текущее состояние сертификата: ${state:-неизвестно}; требуется: $want"

if [[ $FORCE -eq 0 && "$state" == "$want" ]]; then
  log "Сертификат ($want) уже выпущен — повторный выпуск не нужен. Убеждаюсь, что nginx запущен."
  dc up -d web
  exit 0
fi
if [[ $FORCE -eq 0 && "$state" == "production" && "$want" == "staging" ]]; then
  die "уже есть настоящий сертификат; чтобы заменить его тестовым, добавьте --force"
fi

# 1–2. временный сертификат и запуск nginx
if [[ "$state" != "dummy" ]]; then
  if [[ "$state" == "staging" || "$state" == "production" ]]; then
    log "Удаляю прежний сертификат ($state)"
    remove_cert_files
  fi
  make_dummy
fi
log "Запускаю nginx"
dc up -d web
wait_for_nginx
dc exec -T web nginx -s reload >/dev/null 2>&1 || true

# 3. настоящий сертификат
log "Удаляю временный сертификат"
remove_cert_files

staging_arg=()
[[ $STAGING -eq 1 ]] && staging_arg=(--staging)
log "Запрашиваю сертификат Let's Encrypt для $DOMAIN${staging_arg:+ (staging)}"
if ! certbot_run certbot certonly \
      --webroot -w /var/www/certbot \
      -d "$DOMAIN" \
      --email "$LETSENCRYPT_EMAIL" \
      --agree-tos --no-eff-email --non-interactive \
      "${staging_arg[@]}"; then
  # возвращаем временный сертификат, чтобы nginx мог перезапуститься
  make_dummy || true
  dc exec -T web nginx -s reload >/dev/null 2>&1 || true
  cat >&2 <<EOF

Не удалось получить сертификат. Проверьте:
  - A-запись $DOMAIN указывает на IP этого сервера:  getent hosts $DOMAIN
  - порт 80 открыт снаружи (файрвол, группа безопасности облака);
  - лимиты Let's Encrypt — сначала пробуйте с --staging.
Подробности: docker compose --profile certbot run --rm certbot certificates
EOF
  exit 1
fi

# 4. перезагрузка nginx с настоящим сертификатом
log "Перезагружаю nginx"
dc exec -T web nginx -t
dc exec -T web nginx -s reload
log "Готово: https://$DOMAIN/ ($want)"
if [[ $STAGING -eq 1 ]]; then
  log "Это тестовый сертификат — браузеры ему не доверяют. Для настоящего запустите скрипт без --staging."
fi
