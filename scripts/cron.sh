#!/usr/bin/env bash
# Управление расписанием автопродления сертификата в crontab текущего пользователя.
#
#   scripts/cron.sh install   # добавить задачу: дважды в сутки в случайную минуту (без дублей)
#   scripts/cron.sh remove    # удалить задачу
#   scripts/cron.sh status    # показать задачу и последние строки лога
#   scripts/cron.sh run [...] # запустить продление вручную (аргументы передаются в renew-certs.sh)
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MARKER="# chokepoint-renew"
RENEW="$PROJECT_DIR/scripts/renew-certs.sh"
HOURS="3,15"

usage() { sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

current_crontab() { crontab -l 2>/dev/null || true; }

cron_line() {
  local minute="$1"
  # путь в одинарных кавычках — на случай пробелов в пути проекта
  printf "%s %s * * * '%s' >/dev/null 2>&1 %s\n" "$minute" "$HOURS" "$RENEW" "$MARKER"
}

cmd_install() {
  require_cmd crontab flock
  chmod +x "$RENEW" "$PROJECT_DIR/scripts/"*.sh 2>/dev/null || true
  local existing
  existing="$(current_crontab)"
  if grep -qF "$MARKER" <<<"$existing"; then
    echo "Задача уже установлена:"
    grep -F "$MARKER" <<<"$existing"
    return 0
  fi
  local minute=$(( RANDOM % 60 ))
  { [[ -n "$existing" ]] && printf '%s\n' "$existing"; cron_line "$minute"; } | crontab -
  echo "Задача добавлена в crontab ($(id -un 2>/dev/null || echo "$USER")):"
  cron_line "$minute"
}

cmd_remove() {
  require_cmd crontab
  local existing
  existing="$(current_crontab)"
  if ! grep -qF "$MARKER" <<<"$existing"; then
    echo "Задача не найдена — удалять нечего."
    return 0
  fi
  grep -vF "$MARKER" <<<"$existing" | crontab -
  echo "Задача удалена из crontab."
}

cmd_status() {
  require_cmd crontab
  local line
  line="$(current_crontab | grep -F "$MARKER" || true)"
  if [[ -n "$line" ]]; then
    echo "Расписание: установлено"
    echo "  $line"
  else
    echo "Расписание: не установлено (scripts/cron.sh install)"
  fi
  local log="$LOG_DIR/renew.log"
  echo
  if [[ -s "$log" ]]; then
    echo "Последние записи $log:"
    tail -n 15 "$log" | sed 's/^/  /'
  else
    echo "Лог $log пока пуст."
  fi
}

case "${1:-}" in
  install) cmd_install ;;
  remove)  cmd_remove ;;
  status)  cmd_status ;;
  run)     shift; exec "$RENEW" "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
