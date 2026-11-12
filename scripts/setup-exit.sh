#!/usr/bin/env bash
# Настройка выходного сервера B: Xray (VLESS + Reality + Vision) на 443, файрвол ufw
# пропускает на 443 только входные серверы (A, C, …). Запускается на сервере B от root.
# Репозиторий на B не нужен: достаточно скопировать этот файл.
#
#   setup-exit.sh --entry IP [--entry IP ...] [--ssh-port N] [--sni домен] [--address IP_B]
#                 [--harden-ssh] [--regenerate]        первичная установка или повторный запуск
#   setup-exit.sh add-entry IP                         разрешить ещё один вход
#   setup-exit.sh remove-entry IP                      убрать вход из файрвола
#   setup-exit.sh show                                 снова показать данные для 3x-ui на входе
#
# Опции:
#   --entry IP      IP входного сервера; можно повторять. При повторном запуске добавляется
#                   к уже сохранённым.
#   --ssh-port N    порт SSH на этом сервере (по умолчанию — сохранённый или из sshd, иначе 22)
#   --sni ДОМЕН     dest/serverNames для Reality (по умолчанию www.cloudflare.com)
#   --address IP    внешний IP этого сервера для JSON outbound (по умолчанию определяется сам)
#   --harden-ssh    вход по SSH только по ключу (нужен хотя бы один ключ в authorized_keys)
#   --regenerate    сгенерировать новые UUID, ключи и shortId (outbound на входах придётся обновить)
#
# Повторный запуск безопасен: ключи берутся из сохранённого файла и не меняются без --regenerate.
set -Eeuo pipefail

# Пути можно переопределить переменными окружения (используется в тестах).
XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
CRED_FILE="${CRED_FILE:-/root/exit-credentials.txt}"
SSHD_DROPIN="${SSHD_DROPIN:-/etc/ssh/sshd_config.d/00-hardening.conf}"
OS_RELEASE="${OS_RELEASE:-/etc/os-release}"
ROOT_HOME="${ROOT_HOME:-/root}"
XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

# Отпечаток TLS — тот же, что принят в README репозитория для клиентов.
FINGERPRINT="firefox"
DEFAULT_SNI="www.cloudflare.com"

# сохранённые/текущие значения
UUID="" PRIVATE_KEY="" PUBLIC_KEY="" SHORT_ID="" SNI="" ENTRIES="" SSH_PORT="" PUBLIC_ADDR=""

die()  { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
info() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf 'Внимание: %s\n' "$*" >&2; }
usage() { sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ---------- проверки значений ----------

valid_ipv4() {
  local ip="$1" o
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do
    [[ "$o" =~ ^(0|[1-9][0-9]*)$ ]] && (( o <= 255 )) || return 1
  done
}
valid_ipv6() { [[ "$1" =~ ^[0-9A-Fa-f:]+$ && "$1" == *:*:* && ${#1} -le 39 ]]; }
valid_ip() { valid_ipv4 "$1" || valid_ipv6 "$1"; }
valid_uuid() { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
valid_key() { [[ "$1" =~ ^[A-Za-z0-9_-]{43}=?$ ]]; }
valid_short_id() { [[ "$1" =~ ^([0-9a-f]{2}){1,8}$ ]]; }
valid_domain() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; }
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

# ---------- разбор вывода `xray x25519` ----------
# Форматы:
#   новый:  PrivateKey: …   Password: …            (Password — это публичный ключ)
#           PrivateKey: …   Password (PublicKey): …   Hash32: …
#   старый: Private key: …  Public key: …
# Печатает две строки: приватный ключ, публичный ключ. Код 1, если что-то не нашлось.
parse_x25519() {
  local out="$1" line key val priv="" pub=""
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ "$line" == *:* ]] || continue
    key="${line%%:*}"; val="${line#*:}"
    key="$(tr '[:upper:]' '[:lower:]' <<<"$key" | tr -d ' ')"
    val="$(tr -d ' \t' <<<"$val")"
    case "$key" in
      privatekey) priv="$val" ;;
      publickey|password|password\(publickey\)) pub="$val" ;;
    esac
  done <<<"$out"
  [[ -n "$priv" && -n "$pub" ]] || return 1
  printf '%s\n%s\n' "$priv" "$pub"
}

# ---------- файл с сохранёнными значениями ----------

cred_get() {
  local key="$1" line
  [[ -f "$CRED_FILE" ]] || return 1
  line="$(grep -E "^${key}=" "$CRED_FILE" | tail -n 1)" || return 1
  printf '%s' "${line#*=}"
}

load_creds() {
  [[ -f "$CRED_FILE" ]] || return 1
  UUID="$(cred_get UUID || true)"
  PRIVATE_KEY="$(cred_get PRIVATE_KEY || true)"
  PUBLIC_KEY="$(cred_get PUBLIC_KEY || true)"
  SHORT_ID="$(cred_get SHORT_ID || true)"
  SNI="$(cred_get SNI || true)"
  ENTRIES="$(cred_get ENTRIES || true)"
  SSH_PORT="$(cred_get SSH_PORT || true)"
  PUBLIC_ADDR="$(cred_get PUBLIC_ADDR || true)"
  return 0
}

save_creds() {
  local dir tmp
  dir="$(dirname "$CRED_FILE")"
  mkdir -p "$dir"
  tmp="$(umask 077; mktemp "$CRED_FILE.XXXXXX")"
  cat >"$tmp" <<EOF
# Данные выходного сервера (setup-exit.sh). Не публикуйте этот файл.
UUID=$UUID
PRIVATE_KEY=$PRIVATE_KEY
PUBLIC_KEY=$PUBLIC_KEY
SHORT_ID=$SHORT_ID
SNI=$SNI
ENTRIES=$ENTRIES
SSH_PORT=$SSH_PORT
PUBLIC_ADDR=$PUBLIC_ADDR
EOF
  chmod 600 "$tmp"
  mv -f "$tmp" "$CRED_FILE"
}

creds_complete() {
  valid_uuid "$UUID" && valid_key "$PRIVATE_KEY" && valid_key "$PUBLIC_KEY" && valid_short_id "$SHORT_ID"
}

# Список входов хранится через пробел.
entry_has() { [[ " $ENTRIES " == *" $1 "* ]]; }
entry_add() { entry_has "$1" || ENTRIES="${ENTRIES:+$ENTRIES }$1"; }
entry_del() {
  local e out=""
  for e in $ENTRIES; do [[ "$e" == "$1" ]] || out="${out:+$out }$e"; done
  ENTRIES="$out"
}

# ---------- генерация конфига и вывода ----------

# Конфиг Xray сервера B. Значения должны быть уже проверены.
render_config() {
  cat <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "from-entry",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$UUID", "flow": "xtls-rprx-vision", "email": "entry" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "$SNI:443",
          "serverNames": [ "$SNI" ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [ "$SHORT_ID" ]
        }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ], "routeOnly": true }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "streamSettings": { "sockopt": { "domainStrategy": "UseIPv4" } } },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "ip": [ "geoip:private" ], "outboundTag": "block" },
      { "type": "field", "protocol": [ "bittorrent" ], "outboundTag": "block" }
    ]
  }
}
EOF
}

# JSON для 3x-ui на входе: Настройки Xray → Исходящие → Добавить исходящее → JSON.
render_outbound() {
  cat <<EOF
{
  "tag": "exit",
  "protocol": "vless",
  "settings": {
    "vnext": [ {
      "address": "${PUBLIC_ADDR:-IP_B}",
      "port": 443,
      "users": [ { "id": "$UUID", "encryption": "none", "flow": "xtls-rprx-vision" } ]
    } ]
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "serverName": "$SNI",
      "fingerprint": "$FINGERPRINT",
      "publicKey": "$PUBLIC_KEY",
      "shortId": "$SHORT_ID",
      "spiderX": "/"
    }
  }
}
EOF
}

render_table() {
  cat <<EOF
| Поле                   | Значение
|------------------------|------------------------------------------
| Protocol               | vless
| Tag                    | exit
| Address / Port         | ${PUBLIC_ADDR:-IP_B} / 443
| ID                     | $UUID
| Flow                   | xtls-rprx-vision
| Encryption             | none
| Transmission / Network | tcp (raw)
| Security               | reality
| SNI                    | $SNI
| uTLS / Fingerprint     | $FINGERPRINT
| Public Key             | $PUBLIC_KEY
| Short ID               | $SHORT_ID
| SpiderX                | /
EOF
}

cmd_show() {
  load_creds || die "нет файла $CRED_FILE — сначала выполните установку: $0 --entry IP_ВХОДА"
  creds_complete || die "в $CRED_FILE не хватает значений; запустите установку с --regenerate"
  cat <<EOF

Исходящее для 3x-ui на КАЖДОМ входе (A, C, …):
Настройки Xray → Исходящие → Добавить исходящее → вкладка JSON → вставить → Добавить → Сохранить.
Не вставляйте его в расширенный шаблон: панель перезаписывает там раздел outbounds.

$(render_outbound)

Если вкладки JSON нет — заполните форму:

$(render_table)

Разрешённые входы: ${ENTRIES:-нет}
Значения сохранены в $CRED_FILE (права 600).
Проверка на входе: nc -vz -w 5 ${PUBLIC_ADDR:-IP_B} 443  → succeeded
EOF
}

# ---------- системные шаги (только на реальном сервере) ----------

require_root() { [[ "$(id -u)" -eq 0 ]] || die "запустите от root (sudo -i или sudo $0 …)"; }

require_ubuntu() {
  [[ -r "$OS_RELEASE" ]] || die "не найден $OS_RELEASE — поддерживаются только Ubuntu 22.04 и 24.04"
  local id ver
  # shellcheck source=/dev/null
  id="$(. "$OS_RELEASE" && printf '%s' "${ID:-}")"
  # shellcheck source=/dev/null
  ver="$(. "$OS_RELEASE" && printf '%s' "${VERSION_ID:-}")"
  if [[ "$id" != "ubuntu" || ( "$ver" != "22.04" && "$ver" != "24.04" ) ]]; then
    die "поддерживаются только Ubuntu 22.04 и 24.04 (у вас: ${id:-?} ${ver:-?})"
  fi
}

install_packages() {
  local missing=() p
  for p in ufw curl openssl; do command -v "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if (( ${#missing[@]} )); then
    info "Ставлю пакеты: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}"
  fi
}

install_xray() {
  if command -v xray >/dev/null 2>&1; then
    info "Xray уже установлен: $(xray version 2>/dev/null | head -n 1)"
    return 0
  fi
  info "Ставлю Xray официальным скриптом XTLS/Xray-install"
  local tmp
  tmp="$(mktemp)"
  curl -fsSL "$XRAY_INSTALL_URL" -o "$tmp" || { rm -f "$tmp"; die "не удалось скачать $XRAY_INSTALL_URL"; }
  bash "$tmp" @ install || { rm -f "$tmp"; die "установка Xray завершилась с ошибкой"; }
  rm -f "$tmp"
  command -v xray >/dev/null 2>&1 || die "после установки команда xray не найдена"
}

detect_ssh_port() {
  local p=""
  if command -v sshd >/dev/null 2>&1; then
    p="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }')" || true
  fi
  printf '%s' "${p:-22}"
}

detect_public_addr() {
  local ip=""
  ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if ! valid_ipv4 "$ip"; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }' || true)"
  fi
  valid_ipv4 "$ip" && printf '%s' "$ip"
}

# Ключи из уже записанного конфига — на случай, если файл с данными потерян.
recover_from_config() {
  if [[ ! -f "$XRAY_CONFIG" ]] || ! grep -q '"from-entry"' "$XRAY_CONFIG"; then return 1; fi
  local u k s pair
  u="$(grep -oE '"id": *"[0-9a-fA-F-]{36}"' "$XRAY_CONFIG" | head -n 1 | grep -oE '[0-9a-fA-F-]{36}')" || return 1
  k="$(grep -oE '"privateKey": *"[A-Za-z0-9_-]{43}=?"' "$XRAY_CONFIG" | head -n 1 | sed -E 's/.*"([^"]+)"$/\1/')" || return 1
  s="$(grep -A1 '"shortIds"' "$XRAY_CONFIG" | grep -oE '"[0-9a-f]{2,16}"' | head -n 1 | tr -d '"')" || return 1
  pair="$(parse_x25519 "$(xray x25519 -i "$k" 2>/dev/null)")" || return 1
  UUID="$u"; PRIVATE_KEY="$k"; SHORT_ID="$s"; PUBLIC_KEY="$(sed -n 2p <<<"$pair")"
  if [[ -z "$SNI" ]]; then
    SNI="$(grep -A1 '"serverNames"' "$XRAY_CONFIG" | grep -oE '"[A-Za-z0-9.-]+"' | grep -v serverNames | head -n 1 | tr -d '"')" || true
  fi
  creds_complete
}

generate_keys() {
  local out pair
  UUID="$(xray uuid)"
  out="$(xray x25519)"
  pair="$(parse_x25519 "$out")" || die "не удалось разобрать вывод 'xray x25519':
$out"
  PRIVATE_KEY="$(sed -n 1p <<<"$pair")"
  PUBLIC_KEY="$(sed -n 2p <<<"$pair")"
  SHORT_ID="$(openssl rand -hex 8)"
  creds_complete || die "сгенерированные значения не прошли проверку (UUID/ключи/shortId)"
}

write_config() {
  local tmp dir
  dir="$(dirname "$XRAY_CONFIG")"
  mkdir -p "$dir"
  tmp="$(mktemp "$XRAY_CONFIG.XXXXXX")"
  render_config >"$tmp"
  chmod 644 "$tmp"
  if ! xray run -test -config "$tmp" >/dev/null 2>&1; then
    xray run -test -config "$tmp" >&2 || true
    rm -f "$tmp"
    die "xray не принял новый конфиг — старый конфиг не тронут"
  fi
  if [[ -f "$XRAY_CONFIG" ]] && ! cmp -s "$tmp" "$XRAY_CONFIG"; then
    cp -p "$XRAY_CONFIG" "$XRAY_CONFIG.bak-$(date +%Y%m%d-%H%M%S)"
  fi
  mv -f "$tmp" "$XRAY_CONFIG"
  info "Конфиг записан и проверен: $XRAY_CONFIG"
}

ufw_allow_entry() {
  ufw allow from "$1" to any port 443 proto tcp comment 'entry' >/dev/null
}
ufw_delete_entry() {
  ufw --force delete allow from "$1" to any port 443 proto tcp comment 'entry' >/dev/null 2>&1 ||
    ufw --force delete allow from "$1" to any port 443 proto tcp >/dev/null 2>&1 || true
}

setup_firewall() {
  info "Настраиваю ufw: входящие запрещены, SSH $SSH_PORT открыт, 443 — только для входов"
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow "$SSH_PORT/tcp" >/dev/null
  # 443 «для всех» здесь не нужен — убираем, если такое правило осталось
  ufw --force delete allow 443/tcp >/dev/null 2>&1 || true
  ufw --force delete allow 443 >/dev/null 2>&1 || true
  local e
  for e in $ENTRIES; do ufw_allow_entry "$e"; done
  ufw --force enable >/dev/null
  ufw status | sed 's/^/    /'
}

restart_xray() {
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray
  sleep 1
  systemctl is-active --quiet xray || { journalctl -u xray -n 30 --no-pager >&2 || true; die "xray не запустился"; }
  info "Xray запущен"
}

harden_ssh() {
  local keys=0 f home
  for home in "$ROOT_HOME" ${SUDO_USER:+"$(getent passwd "$SUDO_USER" | cut -d: -f6)"}; do
    f="$home/.ssh/authorized_keys"
    [[ -f "$f" ]] || continue
    keys=$(( keys + $(grep -cE '^[[:space:]]*(ssh-|ecdsa-|sk-)' "$f" || true) ))
  done
  if (( keys == 0 )); then
    die "в authorized_keys нет ни одного SSH-ключа — вход по паролю НЕ отключён, иначе вы потеряете доступ.
Добавьте ключ (ssh-copy-id root@IP_B), проверьте вход по нему и запустите снова с --harden-ssh"
  fi
  info "Отключаю вход по паролю ($SSHD_DROPIN)"
  mkdir -p "$(dirname "$SSHD_DROPIN")"
  cat >"$SSHD_DROPIN" <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
  if ! sshd -t; then
    rm -f "$SSHD_DROPIN"
    die "sshd -t нашёл ошибку — файл $SSHD_DROPIN удалён, настройки SSH не изменились"
  fi
  systemctl restart ssh 2>/dev/null || systemctl restart sshd
  warn "не закрывайте текущее окно SSH, пока не проверите вход по ключу в новом"
}

# ---------- команды ----------

cmd_install() {
  local new_entries=() sni="" ssh_port="" addr="" regenerate=0 harden=0 e
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --entry) [[ -n "${2:-}" ]] || die "--entry: укажите IP"; new_entries+=("$2"); shift ;;
      --ssh-port) ssh_port="${2:-}"; shift ;;
      --sni) sni="${2:-}"; shift ;;
      --address) addr="${2:-}"; shift ;;
      --regenerate) regenerate=1 ;;
      --harden-ssh) harden=1 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "неизвестный аргумент: $1" ;;
    esac
    shift
  done
  for e in "${new_entries[@]}"; do valid_ip "$e" || die "--entry: '$e' не похож на IP-адрес"; done
  [[ -z "$sni" ]] || valid_domain "$sni" || die "--sni: '$sni' не похож на домен"
  [[ -z "$ssh_port" ]] || valid_port "$ssh_port" || die "--ssh-port: '$ssh_port' — не номер порта"
  [[ -z "$addr" ]] || valid_ip "$addr" || die "--address: '$addr' не похож на IP-адрес"

  require_root
  require_ubuntu
  load_creds || true
  for e in "${new_entries[@]}"; do entry_add "$e"; done
  [[ -n "$ENTRIES" ]] || die "укажите хотя бы один вход: $0 --entry IP_ВХОДА"

  install_packages
  install_xray

  if (( regenerate )); then
    info "Генерирую новые UUID, ключи и shortId (--regenerate)"
    generate_keys
    warn "ключи изменились — обновите исходящее exit на всех входах (команда: $0 show)"
  elif creds_complete; then
    info "Использую сохранённые ключи из $CRED_FILE"
  elif recover_from_config; then
    info "Ключи восстановлены из $XRAY_CONFIG"
  else
    info "Генерирую UUID, ключи x25519 и shortId"
    generate_keys
  fi

  if [[ -n "$sni" && -n "$SNI" && "$sni" != "$SNI" ]]; then
    warn "SNI изменён на $sni — обновите serverName в исходящем exit на входах"
  fi
  SNI="${sni:-${SNI:-$DEFAULT_SNI}}"
  SSH_PORT="${ssh_port:-${SSH_PORT:-$(detect_ssh_port)}}"
  if [[ -n "$addr" ]]; then PUBLIC_ADDR="$addr"; fi
  [[ -n "$PUBLIC_ADDR" ]] || PUBLIC_ADDR="$(detect_public_addr || true)"
  [[ -n "$PUBLIC_ADDR" ]] || warn "не удалось определить внешний IP — в JSON будет IP_B, укажите --address"

  save_creds
  write_config
  setup_firewall
  restart_xray
  if (( harden )); then harden_ssh; fi
  cmd_show
}

cmd_add_entry() {
  local ip="${1:-}"
  valid_ip "$ip" || die "укажите IP входа: $0 add-entry IP"
  require_root
  load_creds || die "нет файла $CRED_FILE — сначала выполните установку"
  ufw_allow_entry "$ip"
  entry_add "$ip"
  save_creds
  info "Вход $ip разрешён на 443. Сейчас разрешены: $ENTRIES"
  echo "На новом входе добавьте исходящее exit — его JSON: $0 show"
}

cmd_remove_entry() {
  local ip="${1:-}"
  valid_ip "$ip" || die "укажите IP входа: $0 remove-entry IP"
  require_root
  load_creds || die "нет файла $CRED_FILE — сначала выполните установку"
  ufw_delete_entry "$ip"
  entry_del "$ip"
  save_creds
  info "Вход $ip убран. Сейчас разрешены: ${ENTRIES:-нет}"
  [[ -n "$ENTRIES" ]] || warn "не осталось ни одного входа: на 443 сейчас не пускают никого"
}

main() {
  case "${1:-}" in
    add-entry)    shift; cmd_add_entry "$@" ;;
    remove-entry) shift; cmd_remove_entry "$@" ;;
    show)         cmd_show ;;
    -h|--help|help) usage ;;
    "")           usage >&2; exit 2 ;;
    *)            cmd_install "$@" ;;
  esac
}

# При подключении через `source` (тесты) только определяем функции.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
