#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$ROOT/install-singbox-yyds.sh"
PASS=0
FAIL=0

ok() { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }

echo "== syntax =="
if bash -n "$INSTALLER"; then
    ok "installer bash -n"
else
    bad "installer bash -n"
fi

awk '/^cat > "\$SB_PATH" <<'\''SB_SCRIPT'\''$/{p=1;next} /^SB_SCRIPT$/{p=0} p' "$INSTALLER" > /tmp/sb-extracted.sh
if bash -n /tmp/sb-extracted.sh; then
    ok "extracted sb bash -n"
else
    bad "extracted sb bash -n"
fi

echo "== extract helpers =="
# shellcheck disable=SC1090
eval "$(sed -n '/^load_kv_file()/,/^cache_set()/{ /^cache_set()/q; p; }' "$INSTALLER")"
eval "$(sed -n '/^cache_set()/,/^# 生成随机密码/{ /^# 生成随机密码/q; p; }' "$INSTALLER")"
eval "$(sed -n '/^format_host()/,/^# -----------------------/{ /^# -----------------------/q; p; }' "$INSTALLER")"
eval "$(sed -n '/^haversine_km()/,/^lookup_server_geo()/{ /^lookup_server_geo()/q; p; }' "$INSTALLER")"
eval "$(sed -n '/^probe_reality_dest()/,/^discover_reality_sni()/{ /^discover_reality_sni()/q; p; }' "$INSTALLER")"

echo "== load_kv_file does not execute payloads =="
tmpcache=$(mktemp)
printf '%s\n' \
    'ENABLE_SS=true' \
    'SS_PSK=abc$(touch /tmp/pwned-cache-test)123' \
    'EVIL=1; touch /tmp/pwned-cache-test2' \
    'REALITY_SNI=www.stanford.edu' > "$tmpcache"
rm -f /tmp/pwned-cache-test /tmp/pwned-cache-test2
ENABLE_SS=""
SS_PSK=""
REALITY_SNI=""
load_kv_file "$tmpcache"
if [ "$ENABLE_SS" = "true" ] && [ "$SS_PSK" = 'abc$(touch /tmp/pwned-cache-test)123' ] && [ ! -e /tmp/pwned-cache-test ] && [ ! -e /tmp/pwned-cache-test2 ]; then
    ok "cache values stay literal"
else
    bad "cache load executed or dropped values (SS_PSK=$SS_PSK)"
fi
rm -f "$tmpcache"

echo "== cache_set upsert =="
tmpcache=$(mktemp)
printf '%s\n' 'A=1' 'B=2' > "$tmpcache"
cache_set "$tmpcache" B 9
cache_set "$tmpcache" C 3
if grep -qx 'B=9' "$tmpcache" && grep -qx 'C=3' "$tmpcache" && grep -qx 'A=1' "$tmpcache"; then
    ok "cache_set update/insert"
else
    bad "cache_set contents: $(tr '\n' ' ' < "$tmpcache")"
fi
rm -f "$tmpcache"

echo "== format_host =="
[ "$(format_host 1.2.3.4)" = "1.2.3.4" ] && ok "ipv4 host" || bad "ipv4 host"
[ "$(format_host 2001:db8::1)" = "[2001:db8::1]" ] && ok "ipv6 host" || bad "ipv6 host"
[ "$(format_host '[2001:db8::1]')" = "[2001:db8::1]" ] && ok "already-bracket ipv6" || bad "already-bracket ipv6"

echo "== domain helpers =="
looks_like_domain jp.example.com && ok "domain ok" || bad "domain ok"
looks_like_domain example.com && ok "apex domain ok" || bad "apex domain ok"
if looks_like_domain 'not a host'; then bad "invalid domain accepted"; else ok "invalid domain rejected"; fi
if looks_like_domain 1.2.3.4; then bad "ipv4 treated as domain"; else ok "ipv4 not a domain"; fi
is_ipv4 1.2.3.4 && ok "is_ipv4" || bad "is_ipv4"
is_ipv6 2001:db8::1 && ok "is_ipv6" || bad "is_ipv6"

echo "== haversine =="
dist=$(haversine_km 37.4275 -122.1697 34.0689 -118.4452)
if [ "$dist" -gt 400 ] && [ "$dist" -lt 600 ]; then
    ok "stanford-ucla ~${dist}km"
else
    bad "unexpected distance $dist"
fi

echo "== jq inbound generation =="
if ! command -v jq >/dev/null 2>&1; then
    bad "jq missing"
else
    PORT_SS=443
    SS_METHOD="2022-blake3-aes-128-gcm"
    PSK_SS='p+s/w&d=x'
    PORT_REALITY=443
    UUID="11111111-1111-1111-1111-111111111111"
    REALITY_SNI="www.stanford.edu"
    REALITY_PK="priv+key/with=plus"
    REALITY_SID="abcd1234"
    inbounds='[]'
    inbounds=$(jq -c \
        --argjson port "$PORT_SS" \
        --arg method "$SS_METHOD" \
        --arg password "$PSK_SS" \
        '. + [{type:"shadowsocks",listen:"::",listen_port:$port,method:$method,password:$password,tag:"ss-in"}]' <<<"$inbounds")
    inbounds=$(jq -c \
        --argjson port "$PORT_REALITY" \
        --arg uuid "$UUID" \
        --arg sni "$REALITY_SNI" \
        --arg pk "$REALITY_PK" \
        --arg sid "$REALITY_SID" \
        '. + [{type:"vless",tag:"vless-in",listen:"::",listen_port:$port,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$pk,short_id:[$sid]}}}]' <<<"$inbounds")
    cfg=$(jq -n --argjson inbounds "$inbounds" '{inbounds:$inbounds}')
    got_psk=$(printf '%s' "$cfg" | jq -r '.inbounds[]|select(.type=="shadowsocks")|.password')
    got_pk=$(printf '%s' "$cfg" | jq -r '.inbounds[]|select(.type=="vless")|.tls.reality.private_key')
    got_sni=$(printf '%s' "$cfg" | jq -r '.inbounds[]|select(.type=="vless")|.tls.server_name')
    if [ "$got_psk" = 'p+s/w&d=x' ] && [ "$got_pk" = 'priv+key/with=plus' ] && [ "$got_sni" = 'www.stanford.edu' ]; then
        ok "jq preserves special chars"
    else
        bad "jq values psk=$got_psk pk=$got_pk sni=$got_sni"
    fi
    echo "$cfg" | jq -e '.inbounds|length==2' >/dev/null && ok "two inbounds" || bad "inbound count"
    sniff_in_inbound=$(printf '%s' "$cfg" | jq '[.inbounds[]|select(.sniff==true)]|length')
    [ "$sniff_in_inbound" = "0" ] && ok "no legacy sniff on inbound" || bad "legacy sniff still on inbound"
fi

echo "== installer contains required behaviors =="
grep -q 'alloc_port "VLESS Reality".*"443"' "$INSTALLER" && ok "reality default 443" || bad "reality default 443"
grep -q 'User=sing-box' "$INSTALLER" && ok "systemd dedicated user" || bad "systemd dedicated user"
grep -q 'CAP_NET_BIND_SERVICE' "$INSTALLER" && ok "bind capability" || bad "bind capability"
grep -q 'action_rotate_uuid' "$INSTALLER" && ok "rotate uuid" || bad "rotate uuid"
grep -q 'action_rotate_reality_keys' "$INSTALLER" && ok "rotate keys" || bad "rotate keys"
grep -q 'KEEP_EXISTING_CONFIG' "$INSTALLER" && ok "reinstall keep-config" || bad "reinstall keep-config"
grep -q 'NEEDRESTART_SUSPEND=1' "$INSTALLER" && ok "needrestart suspended" || bad "needrestart not suspended"
grep -q -- '--no-upgrade' "$INSTALLER" && ok "apt --no-upgrade" || bad "apt --no-upgrade"
grep -q 'stop_running_singbox' "$INSTALLER" && ok "stop old sing-box before reinstall" || bad "stop old sing-box missing"
grep -q 'reserved_port' "$INSTALLER" && ok "ssh port reserved" || bad "ssh port reserved"
grep -q 'backup_existing_install' "$INSTALLER" && ok "reinstall backup" || bad "reinstall backup"
grep -q 'ask_node_address' "$INSTALLER" && ok "node address prompt" || bad "node address prompt"
grep -q 'ask_tls_certs' "$INSTALLER" && ok "tls cert prompt" || bad "tls cert prompt"
grep -q 'issue_acme_cert' "$INSTALLER" && ok "acme helper" || bad "acme helper"
grep -q 'apply_config' "$INSTALLER" && ok "sb apply_config check" || bad "sb apply_config check"
grep -q 'action_status' "$INSTALLER" && ok "sb status page" || bad "sb status page"
grep -q 'action_change_node_host' "$INSTALLER" && ok "sb change node host" || bad "sb change node host"
grep -q 'REINSTALL_BINARY' "$INSTALLER" && ok "skip binary on keep-config" || bad "skip binary on keep-config"
grep -q 'sni=\${TLS_SNI' "$INSTALLER" && ok "hy2/tuic uri uses tls sni" || bad "hy2/tuic uri uses tls sni"
grep -q '/root/singbox-uris.txt' "$INSTALLER" && ok "uri dump to root" || bad "uri dump to root"
grep -q '不是 Reality SNI' "$INSTALLER" && ok "domain vs reality sni copy" || bad "domain vs reality sni copy"
grep -q 'load_kv_file' "$INSTALLER" && ok "safe kv loader" || bad "safe kv loader"
! grep -q 'addons.mozilla.org' "$INSTALLER" && ok "no mozilla default sni" || bad "mozilla default still present"
grep -q 'action: "sniff"' "$INSTALLER" && ok "sniff moved to route action" || bad "sniff route action missing"
! grep -q 'sniff: true' "$INSTALLER" && ok "no inbound sniff:true" || bad "inbound sniff:true still present"
grep -Eq 'Subject Alternative Name|subjectAltName|DNS:' "$INSTALLER" && ok "SAN check in probe" || bad "SAN check in probe"
if grep -n 'sed -i "s|PSK_SS_PLACEHOLDER' "$INSTALLER" >/dev/null; then
    bad "legacy sed placeholder still used for config"
else
    ok "config no longer uses sed placeholders"
fi

echo "== dest probe (network) =="
if probe_ms=$(probe_reality_dest www.stanford.edu); then
    ok "stanford dest accepted (${probe_ms}ms)"
else
    echo "  [WARN] stanford dest rejected from this network (not a hard fail)"
fi
if probe_reality_dest cloudflare.com; then
    bad "cloudflare.com should be rejected"
else
    ok "cloudflare.com rejected"
fi

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
