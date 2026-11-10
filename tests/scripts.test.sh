#!/usr/bin/env bash
# Тест логики scripts/cron.sh и scripts/renew-certs.sh без настоящих crontab/docker.
# Подставляет заглушки crontab, flock и docker в конец PATH (системные бинарники, если есть, —
# в начале PATH, поэтому на сервере с настоящим crontab тест НЕ запускайте: используйте его
# на машине разработчика или в CI-контейнере без cron).
#
#   bash tests/scripts.test.sh
set -Euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SHIMS="$TMP/bin"; mkdir -p "$SHIMS"

if command -v crontab >/dev/null 2>&1 && [[ "$(command -v crontab)" != "$SHIMS/crontab" ]]; then
  echo "SKIP: в системе есть настоящий crontab ($(command -v crontab)); тест изменил бы его." >&2
  exit 0
fi

export FAKE_CRONTAB="$TMP/crontab.txt"
cat >"$SHIMS/crontab" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  -l) [[ -f "$FAKE_CRONTAB" ]] && cat "$FAKE_CRONTAB" || { echo "no crontab for user" >&2; exit 1; } ;;
  -)  cat >"$FAKE_CRONTAB" ;;
  -r) rm -f "$FAKE_CRONTAB" ;;
  *)  exit 2 ;;
esac
EOF
cat >"$SHIMS/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
# docker: имитирует compose; состояние сертификата задаётся FAKE_CERT_STATE
cat >"$SHIMS/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >>"$FAKE_DOCKER_LOG"
[[ "$1 $2" == "compose version" ]] && { echo "Docker Compose version v2.99.0"; exit 0; }
args="$*"
if [[ "$args" == *"--entrypoint sh certbot -c"* ]]; then
  if [[ "$args" == *"renewal"* ]]; then echo "$FAKE_CERT_STATE"; exit 0; fi
  if [[ "$args" == *"sha256sum"* ]]; then
    n="$(cat "$FAKE_FP_COUNTER" 2>/dev/null || echo 0)"; echo $((n+1)) >"$FAKE_FP_COUNTER"
    if [[ "${FAKE_RENEWED:-0}" == 1 && $n -ge 1 ]]; then echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"; else echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; fi
    exit 0
  fi
fi
[[ "$args" == *"certbot renew"* ]] && { [[ "${FAKE_RENEW_FAIL:-0}" == 1 ]] && { echo "renew failed" >&2; exit 1; }; exit 0; }
[[ "$args" == *"ps --status running -q web"* ]] && { echo "abc123"; exit 0; }
[[ "$args" == *"exec -T web nginx"* ]] && exit 0
exit 0
EOF
chmod +x "$SHIMS"/*
export PATH="$PATH:$SHIMS"
export FAKE_DOCKER_LOG="$TMP/docker.log"
export FAKE_FP_COUNTER="$TMP/fp"

# копия проекта, чтобы не трогать настоящие logs/ и .env
PROJ="$TMP/proj"; mkdir -p "$PROJ"
cp -r "$ROOT/scripts" "$PROJ/"
chmod +x "$PROJ/scripts/"*.sh

pass=0; failn=0
ok()   { echo "  ok   $*"; pass=$((pass+1)); }
bad()  { echo "  FAIL $*"; failn=$((failn+1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

echo "cron.sh"
"$PROJ/scripts/cron.sh" install >/dev/null
"$PROJ/scripts/cron.sh" install >/dev/null
check "install дважды → одна запись" test "$(grep -c '# chokepoint-renew' "$FAKE_CRONTAB")" -eq 1
check "расписание: дважды в сутки, минута 0–59" grep -Eq "^([0-9]|[1-5][0-9]) 3,15 \* \* \* '.*/scripts/renew-certs.sh' >/dev/null 2>&1 # chokepoint-renew$" "$FAKE_CRONTAB"
printf '0 1 * * * /bin/true # чужая задача\n' >>"$FAKE_CRONTAB"
"$PROJ/scripts/cron.sh" status >"$TMP/st"; grep -q "Расписание: установлено" "$TMP/st" && ok "status видит запись" || bad "status видит запись"
"$PROJ/scripts/cron.sh" remove >/dev/null
check "remove удаляет запись" bash -c "! grep -q chokepoint-renew '$FAKE_CRONTAB'"
check "remove не трогает чужие задачи" grep -q "чужая задача" "$FAKE_CRONTAB"
"$PROJ/scripts/cron.sh" remove >"$TMP/st"; grep -q "не найдена" "$TMP/st" && ok "повторный remove безопасен" || bad "повторный remove безопасен"

echo "renew-certs.sh"
# 1) нет .env
"$PROJ/scripts/renew-certs.sh" >"$TMP/out" 2>&1; rc=$?
check "без .env: ненулевой код ($rc)" test $rc -ne 0
check "без .env: понятное сообщение" grep -q "нет файла .env" "$TMP/out"
check "лог пишется в logs/renew.log" test -s "$PROJ/logs/renew.log"

printf 'DOMAIN=test.example\nLETSENCRYPT_EMAIL=a@test.example\n' >"$PROJ/.env"
# 2) локальный режим: сертификата LE нет
: >"$FAKE_DOCKER_LOG"
FAKE_CERT_STATE=none "$PROJ/scripts/renew-certs.sh" >"$TMP/out" 2>&1; rc=$?
check "нет сертификата LE: код 3 ($rc)" test $rc -eq 3
check "нет сертификата LE: сообщение про init-letsencrypt.sh" grep -q "init-letsencrypt.sh" "$TMP/out"
check "нет сертификата LE: nginx не трогали" bash -c "! grep -q 'nginx' '$FAKE_DOCKER_LOG'"

# 3) сертификат не изменился → без reload
: >"$FAKE_DOCKER_LOG"; rm -f "$FAKE_FP_COUNTER"
FAKE_CERT_STATE=production "$PROJ/scripts/renew-certs.sh" >"$TMP/out" 2>&1; rc=$?
check "без изменений: код 0 ($rc)" test $rc -eq 0
check "без изменений: reload не вызывался" bash -c "! grep -q 'nginx -s reload' '$FAKE_DOCKER_LOG'"
check "команда renew с нужными аргументами" grep -q "compose --profile certbot run --rm -T certbot renew --webroot -w /var/www/certbot --quiet" "$FAKE_DOCKER_LOG"

# 4) сертификат обновился → reload
: >"$FAKE_DOCKER_LOG"; rm -f "$FAKE_FP_COUNTER"
FAKE_CERT_STATE=production FAKE_RENEWED=1 "$PROJ/scripts/renew-certs.sh" >"$TMP/out" 2>&1; rc=$?
check "обновлён: код 0 ($rc)" test $rc -eq 0
check "обновлён: nginx -s reload вызван" grep -q "exec -T web nginx -s reload" "$FAKE_DOCKER_LOG"

# 5) флаги
: >"$FAKE_DOCKER_LOG"; rm -f "$FAKE_FP_COUNTER"
FAKE_CERT_STATE=production "$PROJ/scripts/renew-certs.sh" --dry-run >/dev/null 2>&1
check "--dry-run прокидывается" grep -q "renew .*--dry-run" "$FAKE_DOCKER_LOG"
: >"$FAKE_DOCKER_LOG"; rm -f "$FAKE_FP_COUNTER"
FAKE_CERT_STATE=production "$PROJ/scripts/renew-certs.sh" --force >/dev/null 2>&1
check "--force → --force-renewal" grep -q "renew .*--force-renewal" "$FAKE_DOCKER_LOG"

# 6) ошибка certbot → ненулевой код
FAKE_CERT_STATE=production FAKE_RENEW_FAIL=1 "$PROJ/scripts/renew-certs.sh" >/dev/null 2>&1; rc=$?
check "ошибка certbot: ненулевой код ($rc)" test $rc -ne 0

# 7) работа с минимальным PATH cron и из другого каталога
(cd / && env -i HOME="$HOME" PATH="/usr/bin:/bin:$SHIMS" FAKE_DOCKER_LOG="$FAKE_DOCKER_LOG" FAKE_FP_COUNTER="$FAKE_FP_COUNTER" FAKE_CERT_STATE=production \
  "$PROJ/scripts/renew-certs.sh" >/dev/null 2>&1); rc=$?
check "минимальный PATH, запуск из /: код 0 ($rc)" test $rc -eq 0
check "в логе есть дата" grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' "$PROJ/logs/renew.log"

echo
echo "$pass passed, $failn failed"
[[ $failn -eq 0 ]]
