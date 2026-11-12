#!/usr/bin/env bash
# Режим «сайт-заглушка для REALITY»: nginx становится target-сервером для инбаунда
# VLESS + REALITY в 3x-ui (Xray на 443), а также проксирует XHTTP и подписку 3x-ui.
#
#   scripts/reality.sh enable [опции]   включить режим (или обновить параметры) и пересоздать nginx
#   scripts/reality.sh disable          вернуть обычный режим (nginx снова на 80/443)
#   scripts/reality.sh status           текущий режим и параметры
#   scripts/reality.sh panel            значения, которые нужно ввести в 3x-ui
#
# Опции enable:
#   --target ADDR:PORT    где слушает nginx для REALITY (по умолчанию 127.0.0.1:9443)
#   --xhttp-path /p/      путь XHTTP (по умолчанию — случайный, генерируется один раз)
#   --xhttp-upstream A:P  адрес XHTTP-инбаунда Xray (по умолчанию 127.0.0.1:2023)
#   --no-xhttp / --xhttp  выключить / снова включить XHTTP (без XHTTP — вариант «только TCP»)
#   --sub-path /p/        путь подписки (по умолчанию — случайный)
#   --sub-json-path /p/   путь JSON-подписки (по умолчанию — случайный)
#   --sub-upstream A:P    адрес сервера подписок 3x-ui (по умолчанию 127.0.0.1:2096)
#   --no-sub / --sub      выключить / снова включить проксирование подписки
#   --no-apply            только записать .env, контейнер не пересоздавать
#
# Не указанные параметры берутся из .env (повторный enable ничего не сбрасывает).
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REALITY_COMPOSE="docker-compose.yml:docker-compose.reality.yml"

usage() { sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

rand_hex() { od -An -N"${1:-4}" -tx1 /dev/urandom | tr -d ' \n'; }

valid_path() { [[ "$1" =~ ^/[A-Za-z0-9._~/-]*/$ && "$1" != "/" && "$1" != *"//"* ]]; }
ADDR_RE='^[][0-9A-Za-z.:-]+:[0-9]{1,5}$'
valid_addr() { [[ "$1" =~ $ADDR_RE ]]; }

# пути сайта, которые нельзя занимать прокси-локациями
reserved_path() {
  case "$1" in
    /assets/*|/css/*|/js/*|/fonts/*|/data/*|/.well-known/*|/healthz*) return 0 ;;
  esac
  return 1
}

current_mode() {
  local cf
  cf="$(env_get COMPOSE_FILE || true)"
  if [[ "$cf" == *"docker-compose.reality.yml"* ]]; then echo reality; else echo standard; fi
}

val() { local v; v="$(env_get "$1" || true)"; printf '%s' "${v:-$2}"; }

cmd_panel() {
  load_env
  local target xp xu xe sp sjp su se
  target="$(val REALITY_TARGET_LISTEN 127.0.0.1:9443)"
  xe="$(val XHTTP_ENABLED on)"; xp="$(val XHTTP_PATH '')"; xu="$(val XHTTP_UPSTREAM 127.0.0.1:2023)"
  se="$(val SUB_ENABLED on)"; sp="$(val SUB_PATH '')"; sjp="$(val SUB_JSON_PATH '')"; su="$(val SUB_UPSTREAM 127.0.0.1:2096)"

  cat <<EOF
Значения для 3x-ui (домен $DOMAIN):

[Инбаунд TCP + REALITY — «входная дверь» на 443]
  Protocol / Port ........ vless / 443, Listen IP пусто
  Transmission ........... TCP (RAW), Header type none
  Security ............... Reality, Show выкл., Xver 0
  uTLS ................... firefox
  Dest / Target .......... $target
  SNI / Server Names ..... $DOMAIN
  Short IDs, ключи ....... сгенерировать (Get New Cert), SpiderX /
  Sniffing ............... вкл.: http, tls, quic, Route Only
  Клиент ................. Flow xtls-rprx-vision, subId — своё неочевидное значение
  Ссылку этого инбаунда клиентам не раздавать: он нужен как фронт на 443
  (fallback в nginx), а клиенты подключаются через XHTTP.
EOF
  if [[ "$xe" == "on" ]]; then
    cat <<EOF

[Инбаунд XHTTP за nginx]
  Protocol ............... vless, Listen IP ${xu%:*}, Port ${xu##*:}
  Transmission ........... XHTTP, Path $xp, Host пусто, Mode auto
  Padding Bytes .......... 100-1000
  XMUX ................... вкл.; заполняется ОДНО из двух полей, второе пустое:
                             Max Concurrency 16-32 (по умолчанию)
                             или Max Connections 1 (если VPN пропадает на 1–10 минут)
                           Max Reuse Times 64-128, Max Request Times 600-900,
                           Max Reusable Secs 1800-3000
  Security ............... none — TLS снимает nginx, до Xray доходит h2c;
                           в ссылке при этом security=tls, это не противоречие
  Sniffing ............... вкл.: http, tls, quic, Route Only

  External Proxy — через JSON инбаунда, внутрь "streamSettings": { ... }:
    "externalProxy": [
      { "forceTls": "tls", "dest": "$DOMAIN", "port": 443, "remark": "", "sni": "$DOMAIN", "fingerprint": "firefox" }
    ]
  После сохранения откройте инбаунд снова и убедитесь, что блок на месте;
  в ссылке клиента должно быть @$DOMAIN:443, security=tls и fp=firefox
  (fp= из externalProxy панель подставляет с версии 3.2.0).

  Клиент — не создавать нового (будет Duplicate subId), а привязать существующего:
    TCP-клиент → «Linked Inbounds» → добавить xhttp → сохранить.
    Flow оставить xtls-rprx-vision: для XHTTP панель убирает его сама.
    В XHTTP-ссылке не должно быть flow=. Если есть — x-ui update
    или включить у инбаунда xhttp опцию DisableFlow, если она есть.

  Если externalProxy не сохраняется — запасной вариант, ссылка вручную (UUID — id клиента):
    vless://UUID@$DOMAIN:443?type=xhttp&path=${xp//\//%2F}&mode=auto&security=tls&sni=$DOMAIN&alpn=h2&fp=firefox#xhttp
EOF
  else
    echo; echo "[XHTTP] выключен (XHTTP_ENABLED=$xe)"
  fi
  if [[ "$se" == "on" ]]; then
    cat <<EOF

[Настройки панели → Подписка]
  Listen IP / Порт ....... ${su%:*} / ${su##*:}
  URI Path ............... $sp
  Домен .................. $DOMAIN
  Сертификат и ключ ...... пусто (TLS делает nginx)
  Reverse Proxy URI ...... https://$DOMAIN$sp
  JSON-подписка .......... путь $sjp, Reverse Proxy URI https://$DOMAIN$sjp
  Рекомендуемый вариант — статический файл подписки в каталоге сайта
  (README, «Ссылки и подписка»).
EOF
  else
    echo; echo "[Подписка] выключена (SUB_ENABLED=$se)"
  fi
}

cmd_status() {
  load_env
  local mode; mode="$(current_mode)"
  echo "Режим: $mode"
  if [[ "$mode" == "reality" ]]; then
    printf '  %-22s %s\n' \
      REALITY_TARGET_LISTEN "$(val REALITY_TARGET_LISTEN 127.0.0.1:9443)" \
      XHTTP_ENABLED "$(val XHTTP_ENABLED on)" \
      XHTTP_PATH "$(val XHTTP_PATH '—')" \
      XHTTP_UPSTREAM "$(val XHTTP_UPSTREAM 127.0.0.1:2023)" \
      SUB_ENABLED "$(val SUB_ENABLED on)" \
      SUB_PATH "$(val SUB_PATH '—')" \
      SUB_JSON_PATH "$(val SUB_JSON_PATH '—')" \
      SUB_UPSTREAM "$(val SUB_UPSTREAM 127.0.0.1:2096)"
  fi
  if command -v docker >/dev/null 2>&1 && web_running; then
    echo "nginx (web): запущен"
  else
    echo "nginx (web): не запущен"
  fi
}

apply_compose() {
  require_compose
  legacy_volume_hint && die "сначала перенесите сертификат старой установки"
  if [[ "$(cert_state)" == "none" ]]; then
    echo
    echo "Сертификата для $DOMAIN ещё нет — выпустите его (порт 80 должен быть открыт):"
    echo "  ./scripts/init-letsencrypt.sh"
    echo "Скрипт поднимет nginx уже в выбранном режиме."
    return 0
  fi
  echo "Пересоздаю nginx…"
  dc up -d --force-recreate --remove-orphans web
  local i
  for i in $(seq 1 20); do
    if dc exec -T web wget -q -O /dev/null http://127.0.0.1/healthz 2>/dev/null; then
      echo "nginx работает."
      return 0
    fi
    sleep 1
  done
  dc logs --tail 30 web >&2 || true
  die "nginx не поднялся — см. лог выше"
}

cmd_enable() {
  local target="" xpath="" xup="" sub="" subj="" subup="" xhttp="" subon="" apply=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target) target="${2:?}"; shift ;;
      --xhttp-path) xpath="${2:?}"; shift ;;
      --xhttp-upstream) xup="${2:?}"; shift ;;
      --no-xhttp) xhttp="off" ;;
      --xhttp) xhttp="on" ;;
      --sub-path) sub="${2:?}"; shift ;;
      --sub-json-path) subj="${2:?}"; shift ;;
      --sub-upstream) subup="${2:?}"; shift ;;
      --no-sub) subon="off" ;;
      --sub) subon="on" ;;
      --no-apply) apply=0 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "неизвестный аргумент: $1" ;;
    esac
    shift
  done
  load_env

  # итоговые значения: аргумент → уже сохранённое в .env → значение по умолчанию
  target="${target:-$(val REALITY_TARGET_LISTEN 127.0.0.1:9443)}"
  xup="${xup:-$(val XHTTP_UPSTREAM 127.0.0.1:2023)}"
  subup="${subup:-$(val SUB_UPSTREAM 127.0.0.1:2096)}"
  xhttp="${xhttp:-$(val XHTTP_ENABLED on)}"
  subon="${subon:-$(val SUB_ENABLED on)}"
  xpath="${xpath:-$(val XHTTP_PATH "/media/$(rand_hex 5)/")}"
  sub="${sub:-$(val SUB_PATH "/$(rand_hex 4)/")}"
  subj="${subj:-$(val SUB_JSON_PATH "/$(rand_hex 4)/")}"

  local p
  for p in "$xpath" "$sub" "$subj"; do
    valid_path "$p" || die "путь '$p' должен начинаться и заканчиваться на / и содержать только A-Z a-z 0-9 . _ ~ - /"
    reserved_path "$p" && die "путь '$p' пересекается с файлами сайта — выберите другой"
  done
  [[ "$xpath" != "$sub" && "$xpath" != "$subj" && "$sub" != "$subj" ]] || die "пути XHTTP, подписки и JSON-подписки должны различаться"
  for p in "$target" "$xup" "$subup"; do
    valid_addr "$p" || die "адрес '$p' должен иметь вид IP:PORT"
  done
  if [[ "${target##*:}" == "443" ]]; then
    die "target не может слушать порт 443 — он нужен Xray"
  fi
  case "${target%:*}" in
    127.*|"[::1]"|localhost) ;;
    *) echo "Внимание: target $target доступен не только с loopback — обычно здесь 127.0.0.1." >&2 ;;
  esac

  env_set COMPOSE_FILE "$REALITY_COMPOSE"
  env_set REALITY_TARGET_LISTEN "$target"
  env_set XHTTP_ENABLED "$xhttp"
  env_set XHTTP_PATH "$xpath"
  env_set XHTTP_UPSTREAM "$xup"
  env_set SUB_ENABLED "$subon"
  env_set SUB_PATH "$sub"
  env_set SUB_JSON_PATH "$subj"
  env_set SUB_UPSTREAM "$subup"
  echo "Режим REALITY включён, параметры записаны в .env."

  if [[ $apply -eq 1 ]]; then apply_compose; else echo "(--no-apply: контейнер не пересоздавался)"; fi
  echo
  cmd_panel
}

cmd_disable() {
  local apply=1
  [[ "${1:-}" == "--no-apply" ]] && apply=0
  load_env
  env_unset COMPOSE_FILE
  echo "Обычный режим: nginx снова слушает 80 и 443. Параметры REALITY оставлены в .env на случай повторного включения."
  echo "Перед этим освободите порт 443 (остановите или перенастройте инбаунд Xray на 443)."
  if [[ $apply -eq 1 ]]; then apply_compose; fi
}

case "${1:-}" in
  enable)  shift; cmd_enable "$@" ;;
  disable) shift; cmd_disable "$@" ;;
  status)  cmd_status ;;
  panel)   cmd_panel ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
