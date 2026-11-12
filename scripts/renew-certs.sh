#!/usr/bin/env bash
# Продление сертификата Let's Encrypt и перезагрузка nginx, если сертификат обновился.
# Рассчитан на запуск из cron (дважды в сутки), но можно и вручную.
#
#   scripts/renew-certs.sh            # обычный запуск: certbot сам решает, пора ли продлевать
#   scripts/renew-certs.sh --dry-run  # проверка на тестовом сервере LE, сертификат не меняется
#   scripts/renew-certs.sh --force    # принудительное продление (--force-renewal), расходует лимиты LE
#
# Лог: logs/renew.log. Код возврата: 0 — успех, ≠0 — ошибка.
set -Euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DRY_RUN=0
FORCE=0
usage() { sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; echo "Неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/renew.log"
log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$$" "$*" | tee -a "$LOG_FILE"; }
fail() { local code="$1"; shift; log "ОШИБКА: $*"; exit "$code"; }

# Не даём двум запускам пересечься (cron + ручной запуск)
command -v flock >/dev/null 2>&1 || fail 127 "не найдена команда flock (пакет util-linux)"
exec 9>"$LOG_DIR/.renew.lock"
flock -n 9 || fail 75 "продление уже выполняется другим процессом"

command -v docker >/dev/null 2>&1 || fail 127 "не найдена команда docker (PATH=$PATH)"
docker compose version >/dev/null 2>&1 || fail 127 "нужен Docker Compose v2 (команда 'docker compose')"
[[ -f "$PROJECT_DIR/.env" ]] || fail 2 "нет файла .env в $PROJECT_DIR"
DOMAIN="$(env_get DOMAIN || true)"
[[ -n "$DOMAIN" ]] || fail 2 "в .env не задан DOMAIN"
export DOMAIN
if hint="$(legacy_volume_hint 2>&1)"; then
  log "$hint"
  fail 3 "сертификат старой установки не перенесён в том нового проекта"
fi

mode="обычный"
renew_args=(renew --webroot -w /var/www/certbot --quiet)
[[ $DRY_RUN -eq 1 ]] && { renew_args+=(--dry-run); mode="dry-run"; }
[[ $FORCE -eq 1 ]] && { renew_args+=(--force-renewal); mode="${mode}, force"; }
log "Старт продления ($mode) для $DOMAIN"

state="$(cert_state)"
case "$state" in
  production|staging) ;;
  dummy) fail 3 "для $DOMAIN установлен только временный самоподписанный сертификат — сначала выполните scripts/init-letsencrypt.sh" ;;
  none)  fail 3 "сертификат Let's Encrypt для $DOMAIN не найден — сначала выполните scripts/init-letsencrypt.sh" ;;
  *)     fail 1 "не удалось определить состояние сертификата (контейнер certbot не запустился?)" ;;
esac

before="$(cert_fingerprint)"
if ! certbot_run certbot "${renew_args[@]}" >>"$LOG_FILE" 2>&1; then
  fail 1 "certbot renew завершился с ошибкой (подробности выше в логе)"
fi
after="$(cert_fingerprint)"

if [[ $DRY_RUN -eq 1 ]]; then
  log "dry-run прошёл успешно, сертификат не менялся"
  exit 0
fi

if [[ -n "$after" && "$before" != "$after" ]]; then
  log "Сертификат обновлён (sha256 ${before:0:12}… → ${after:0:12}…), перезагружаю nginx"
  if ! web_running; then
    log "Сервис web не запущен — nginx подхватит новый сертификат при следующем старте"
    exit 0
  fi
  dc exec -T web nginx -t >>"$LOG_FILE" 2>&1 || fail 1 "nginx -t не прошёл, перезагрузка отменена"
  dc exec -T web nginx -s reload >>"$LOG_FILE" 2>&1 || fail 1 "не удалось перезагрузить nginx"
  log "nginx перезагружен"
else
  log "Продление не требуется — сертификат не изменился"
fi
exit 0
