#!/usr/bin/env bash
# Тесты scripts/setup-exit.sh без настоящего сервера: разбор вывода `xray x25519`
# (новый и старый форматы), генерация конфига и JSON outbound, идемпотентность установки.
# Системные команды (xray, ufw, systemctl, apt-get, id, sshd, curl) подменяются заглушками.
# Для проверки JSON нужен node.
#
#   bash tests/setup-exit.test.sh
set -Euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="$ROOT/scripts/setup-exit.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; failn=0
ok()   { echo "  ok   $*"; pass=$((pass+1)); }
bad()  { echo "  FAIL $*"; failn=$((failn+1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

command -v node >/dev/null 2>&1 || { echo "SKIP: нужен node для проверки JSON" >&2; exit 0; }
# JSON из stdin → вычислить выражение JS над объектом j; код 0, если результат истинный
json_ok() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);process.exit(eval(process.argv[1])?0:1)})' "$1"; }

PRIV="aGVsbG8td29ybGQtcHJpdmF0ZS1rZXktZm9yLXRlc3Q"   # 43 символа, не настоящий ключ
PUB="cHVibGljLWtleS1mb3ItdGVzdHMtb25seS0wMTIzNDU"

echo "parse_x25519"
# shellcheck source=scripts/setup-exit.sh
source "$SCRIPT"
set +e  # setup-exit.sh включает -e; тесты сами проверяют коды возврата

out="$(parse_x25519 "$(printf 'PrivateKey: %s\nPassword: %s\n' "$PRIV" "$PUB")")"
check "новый формат (PrivateKey / Password)" test "$out" = "$PRIV"$'\n'"$PUB"
out="$(parse_x25519 "$(printf 'PrivateKey: %s\nPassword (PublicKey): %s\nHash32: zzzz\n' "$PRIV" "$PUB")")"
check "новый формат с Hash32 и «Password (PublicKey)»" test "$out" = "$PRIV"$'\n'"$PUB"
out="$(parse_x25519 "$(printf 'Private key: %s\r\nPublic key: %s\r\n' "$PRIV" "$PUB")")"
check "старый формат (Private key / Public key), CRLF" test "$out" = "$PRIV"$'\n'"$PUB"
parse_x25519 "что-то непонятное" >/dev/null; rc=$?
check "непонятный вывод → ошибка ($rc)" test $rc -ne 0
parse_x25519 "PrivateKey: $PRIV" >/dev/null; rc=$?
check "нет публичного ключа → ошибка ($rc)" test $rc -ne 0

echo "проверки значений"
check "IPv4 ок" valid_ip 203.0.113.7
check "IPv4 с 256 → нет" bash -c "! (source '$SCRIPT'; valid_ip 203.0.113.256)"
check "IPv4 с ведущим нулём → нет" bash -c "! (source '$SCRIPT'; valid_ip 203.0.113.07)"
check "IPv6 ок" valid_ip 2001:db8::1
check "мусор вместо IP → нет" bash -c "! (source '$SCRIPT'; valid_ip 'IP_A; rm -rf /')"
check "домен SNI ок" valid_domain www.cloudflare.com
check "SNI с кавычкой → нет" bash -c "! (source '$SCRIPT'; valid_domain 'a\".com')"
check "shortId 16 hex ок" valid_short_id 0123456789abcdef
check "shortId нечётной длины → нет" bash -c "! (source '$SCRIPT'; valid_short_id abc)"

echo "конфиг сервера B"
UUID="11111111-2222-3333-4444-555555555555"; PRIVATE_KEY="$PRIV"; PUBLIC_KEY="$PUB"
SHORT_ID="0123456789abcdef"; SNI="www.cloudflare.com"; PUBLIC_ADDR="203.0.113.10"
render_config >"$TMP/config.json"
check "конфиг — корректный JSON" json_ok 'true' <"$TMP/config.json"
check "inbound: vless + reality + vision на 443" json_ok 'const i=j.inbounds[0]; i.port===443&&i.protocol==="vless"&&i.streamSettings.security==="reality"&&i.settings.clients[0].flow==="xtls-rprx-vision"' <"$TMP/config.json"
check "reality: dest/serverNames/privateKey/shortIds" json_ok 'const r=j.inbounds[0].streamSettings.realitySettings; r.dest==="www.cloudflare.com:443"&&r.serverNames[0]==="www.cloudflare.com"&&r.privateKey==="'"$PRIV"'"&&r.shortIds[0]==="0123456789abcdef"' <"$TMP/config.json"
check "direct: domainStrategy только в sockopt" json_ok 'const d=j.outbounds.find(o=>o.tag==="direct"); d.streamSettings.sockopt.domainStrategy==="UseIPv4"&&!(d.settings&&d.settings.domainStrategy)' <"$TMP/config.json"
check "blackhole и правила geoip:private / bittorrent" json_ok 'j.outbounds.some(o=>o.protocol==="blackhole")&&j.routing.rules.some(r=>r.ip&&r.ip[0]==="geoip:private")&&j.routing.rules.some(r=>r.protocol&&r.protocol[0]==="bittorrent")' <"$TMP/config.json"

render_outbound >"$TMP/outbound.json"
check "outbound exit — корректный JSON" json_ok 'j.tag==="exit"' <"$TMP/outbound.json"
check "outbound: fingerprint firefox, publicKey, shortId, serverName, flow" json_ok 'const r=j.streamSettings.realitySettings; r.fingerprint==="firefox"&&r.publicKey==="'"$PUB"'"&&r.shortId==="0123456789abcdef"&&r.serverName==="www.cloudflare.com"&&j.settings.vnext[0].users[0].flow==="xtls-rprx-vision"&&j.settings.vnext[0].address==="203.0.113.10"' <"$TMP/outbound.json"
check "outbound не содержит приватного ключа" bash -c "! grep -q '$PRIV' '$TMP/outbound.json'"

echo "список входов"
ENTRIES=""; entry_add 198.51.100.1; entry_add 198.51.100.2; entry_add 198.51.100.1
check "добавление без дублей" test "$ENTRIES" = "198.51.100.1 198.51.100.2"
entry_del 198.51.100.1
check "удаление" test "$ENTRIES" = "198.51.100.2"

# ---------- установка целиком на заглушках ----------
echo "установка на заглушках"
SHIMS="$TMP/bin"; mkdir -p "$SHIMS"
export SHIM_LOG="$TMP/calls.log" SHIM_N="$TMP/n"
for c in apt-get systemctl journalctl; do printf '#!/usr/bin/env bash\necho "%s $*" >>"$SHIM_LOG"\nexit 0\n' "$c" >"$SHIMS/$c"; done
cat >"$SHIMS/ufw" <<'EOF'
#!/usr/bin/env bash
echo "ufw $*" >>"$SHIM_LOG"
[[ "$1" == status ]] && echo "Status: active"
exit 0
EOF
cat >"$SHIMS/id" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "-u" ]] && { echo 0; exit 0; }
/usr/bin/id "$@"
EOF
cat >"$SHIMS/sshd" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "-T" ]] && { echo "port 2222"; exit 0; }
exit 0
EOF
cat >"$SHIMS/curl" <<'EOF'
#!/usr/bin/env bash
echo 203.0.113.10
EOF
# xray: каждый вызов uuid/x25519 даёт новые значения; x25519 -i возвращает пару для ключа
cat >"$SHIMS/xray" <<'EOF'
#!/usr/bin/env bash
n="$(cat "$SHIM_N" 2>/dev/null || echo 0)"; n=$((n+1)); echo "$n" >"$SHIM_N"
case "$1" in
  version) echo "Xray 99.0.0 (shim)" ;;
  uuid) printf '00000000-0000-0000-0000-%012d\n' "$n" ;;
  x25519)
    if [[ "${2:-}" == "-i" ]]; then printf 'PrivateKey: %s\nPassword: %s\n' "$3" "$(printf '%s' "$3" | tr 'A-Za-z' 'N-ZA-Mn-za-m')"
    else k="$(printf 'k%042d' "$n")"; printf 'PrivateKey: %s\nPassword: %s\n' "$k" "$(printf '%s' "$k" | tr 'A-Za-z' 'N-ZA-Mn-za-m')"; fi ;;
  run) echo "xray $*" >>"$SHIM_LOG"; exit 0 ;;
esac
EOF
chmod +x "$SHIMS"/*
printf 'ID=ubuntu\nVERSION_ID="24.04"\n' >"$TMP/os-ubuntu"
printf 'ID=debian\nVERSION_ID="12"\n' >"$TMP/os-debian"

run_exit() {
  env PATH="$SHIMS:$PATH" XRAY_CONFIG="$TMP/xray/config.json" CRED_FILE="$TMP/root/exit-credentials.txt" \
    SSHD_DROPIN="$TMP/sshd/00-hardening.conf" OS_RELEASE="${OSR:-$TMP/os-ubuntu}" ROOT_HOME="$TMP/root" SUDO_USER= \
    bash "$SCRIPT" "$@"
}
credv() { grep -E "^$1=" "$TMP/root/exit-credentials.txt" | cut -d= -f2-; }

OSR="$TMP/os-debian" run_exit --entry 198.51.100.1 >"$TMP/out" 2>&1; rc=$?
check "не Ubuntu → ошибка ($rc)" test $rc -ne 0
check "не Ubuntu → понятное сообщение" grep -q "только Ubuntu 22.04 и 24.04" "$TMP/out"

run_exit >"$TMP/out" 2>&1; rc=$?
check "без аргументов → справка и код ≠0 ($rc)" test $rc -ne 0
run_exit --entry 'not-an-ip' >"$TMP/out" 2>&1; rc=$?
check "кривой --entry → ошибка ($rc)" test $rc -ne 0

run_exit --entry 198.51.100.1 >"$TMP/out" 2>&1; rc=$?
check "установка: код 0 ($rc)" test $rc -eq 0
check "конфиг записан и это JSON" json_ok 'j.inbounds[0].tag==="from-entry"' <"$TMP/xray/config.json"
check "файл данных создан" test -s "$TMP/root/exit-credentials.txt"
if [[ "$(uname -s)" == Linux ]]; then
  check "права файла данных 600" test "$(stat -c %a "$TMP/root/exit-credentials.txt")" = 600
fi
check "SSH-порт определён из sshd (2222)" test "$(credv SSH_PORT)" = 2222
check "ufw: SSH-порт открыт" grep -q "ufw allow 2222/tcp" "$SHIM_LOG"
check "ufw: 443 только с входа" grep -q "ufw allow from 198.51.100.1 to any port 443 proto tcp" "$SHIM_LOG"
check "ufw: deny incoming и enable" bash -c "grep -q 'ufw default deny incoming' '$SHIM_LOG' && grep -q 'ufw --force enable' '$SHIM_LOG'"
check "конфиг проверен xray run -test" grep -q "xray run -test -config" "$SHIM_LOG"
check "xray перезапущен" grep -q "systemctl restart xray" "$SHIM_LOG"
check "в выводе JSON outbound с fingerprint firefox" grep -q '"fingerprint": "firefox"' "$TMP/out"
check "в выводе таблица для формы" grep -q "| Public Key" "$TMP/out"
check "внешний IP подставлен" grep -q '"address": "203.0.113.10"' "$TMP/out"

u1="$(credv UUID)"; k1="$(credv PRIVATE_KEY)"; s1="$(credv SHORT_ID)"
run_exit --entry 198.51.100.2 >"$TMP/out" 2>&1; rc=$?
check "повторный запуск: код 0 ($rc)" test $rc -eq 0
check "повторный запуск: ключи не изменились" test "$(credv UUID)|$(credv PRIVATE_KEY)|$(credv SHORT_ID)" = "$u1|$k1|$s1"
check "повторный запуск: входы объединены" test "$(credv ENTRIES)" = "198.51.100.1 198.51.100.2"

rm -f "$TMP/root/exit-credentials.txt"
run_exit --entry 198.51.100.1 >"$TMP/out" 2>&1; rc=$?
check "файл данных потерян: ключи восстановлены из конфига" test "$(credv UUID)|$(credv PRIVATE_KEY)|$(credv SHORT_ID)" = "$u1|$k1|$s1"

run_exit --entry 198.51.100.1 --regenerate >"$TMP/out" 2>&1; rc=$?
check "--regenerate: код 0 ($rc)" test $rc -eq 0
check "--regenerate: новые ключи" test "$(credv PRIVATE_KEY)" != "$k1"

: >"$SHIM_LOG"
run_exit add-entry 192.0.2.5 >"$TMP/out" 2>&1; rc=$?
check "add-entry: код 0 ($rc)" test $rc -eq 0
check "add-entry: правило ufw" grep -q "ufw allow from 192.0.2.5 to any port 443 proto tcp" "$SHIM_LOG"
check "add-entry: вход сохранён" bash -c "[[ ' $(credv ENTRIES) ' == *' 192.0.2.5 '* ]]"
run_exit remove-entry 192.0.2.5 >"$TMP/out" 2>&1; rc=$?
check "remove-entry: код 0 ($rc)" test $rc -eq 0
check "remove-entry: правило удаляется" grep -q "delete allow from 192.0.2.5 to any port 443" "$SHIM_LOG"
check "remove-entry: вход убран из списка" bash -c "[[ ' $(credv ENTRIES) ' != *' 192.0.2.5 '* ]]"

run_exit show >"$TMP/out" 2>&1; rc=$?
check "show: код 0 и JSON" bash -c "[[ $rc -eq 0 ]] && grep -q '\"tag\": \"exit\"' '$TMP/out'"

# --harden-ssh без ключей — отказ, файл sshd не создаётся
run_exit --entry 198.51.100.1 --harden-ssh >"$TMP/out" 2>&1; rc=$?
check "--harden-ssh без ключей: отказ ($rc)" test $rc -ne 0
check "--harden-ssh без ключей: sshd не тронут" test ! -e "$TMP/sshd/00-hardening.conf"
check "--harden-ssh без ключей: понятное сообщение" grep -q "нет ни одного SSH-ключа" "$TMP/out"

mkdir -p "$TMP/root/.ssh"; echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITEST test@example" >"$TMP/root/.ssh/authorized_keys"
: >"$SHIM_LOG"
run_exit --entry 198.51.100.1 --harden-ssh >"$TMP/out" 2>&1; rc=$?
check "--harden-ssh с ключом: код 0 ($rc)" test $rc -eq 0
check "--harden-ssh: PasswordAuthentication no и остальное" bash -c "grep -qx 'PasswordAuthentication no' '$TMP/sshd/00-hardening.conf' && grep -qx 'KbdInteractiveAuthentication no' '$TMP/sshd/00-hardening.conf' && grep -qx 'PermitRootLogin prohibit-password' '$TMP/sshd/00-hardening.conf'"
check "--harden-ssh: ssh перезапущен" grep -q "systemctl restart ssh" "$SHIM_LOG"

echo
echo "$pass passed, $failn failed"
[[ $failn -eq 0 ]]
