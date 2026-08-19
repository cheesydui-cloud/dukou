#!/usr/bin/env bash
set -euo pipefail

# -----------------------
# 彩色输出函数
info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

# -----------------------
# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_ID_LIKE="${ID_LIKE:-}"
    else
        OS_ID=""
        OS_ID_LIKE=""
    fi

    if echo "$OS_ID $OS_ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
        OS="debian"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "centos|rhel|fedora|rocky|almalinux|amazon" >/dev/null; then
        OS="redhat"
    else
        OS="unknown"
    fi
}

detect_os
info "检测到系统: $OS (${OS_ID:-unknown})"
if [ "$OS" = "unknown" ]; then
    err "未识别的系统，仅支持 Alpine / Debian / Ubuntu / CentOS / RHEL / Fedora"
    exit 1
fi

# -----------------------
# 检查 root 权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        err "此脚本需要 root 权限"
        err "请使用: sudo bash -c \"\$(curl -fsSL ...)\" 或切换到 root 用户"
        exit 1
    fi
}

check_root

# curl | bash 时 stdin 不是终端，read 会把脚本自身当输入
ensure_tty() {
    if [ -t 0 ]; then
        return 0
    fi
    if [ -e /dev/tty ] && exec </dev/tty; then
        return 0
    fi
    err "此脚本需要交互终端"
    err "请使用: bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/cheesydui-cloud/dukou/main/install-singbox-yyds.sh)\""
    exit 1
}

ensure_tty

# -----------------------
# 安装依赖
install_deps() {
    info "安装系统依赖..."
    
    case "$OS" in
        alpine)
            apk update || { err "apk update 失败"; exit 1; }
            apk add --no-cache bash curl ca-certificates openssl openrc jq iproute2 libcap || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y || { err "apt update 失败"; exit 1; }
            apt-get install -y curl ca-certificates openssl jq iproute2 libcap2-bin || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        redhat)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y curl ca-certificates openssl jq iproute libcap || {
                    err "依赖安装失败"
                    exit 1
                }
            else
                yum install -y curl ca-certificates openssl jq iproute libcap || {
                    err "依赖安装失败"
                    exit 1
                }
            fi
            ;;
        *)
            err "未识别的系统类型"
            exit 1
            ;;
    esac
    
    info "依赖安装完成"
}

install_deps

# -----------------------
# 工具函数
# 生成随机端口
rand_port() {
    local port
    port=$(shuf -i 10000-60000 -n 1 2>/dev/null) || port=$((RANDOM % 50001 + 10000))
    echo "$port"
}

is_valid_port() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

port_in_use() {
    local p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -lntuH 2>/dev/null | grep -Eq "[:(]$p([^0-9]|$)" && return 0
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lntu 2>/dev/null | grep -Eq "[.:]$p([^0-9]|$)" && return 0
    fi
    return 1
}

USED_PORTS=""
mark_port() {
    USED_PORTS="${USED_PORTS} $1 "
}

port_taken() {
    local p="$1"
    echo " $USED_PORTS " | grep -q " $p " && return 0
    port_in_use "$p"
}

alloc_port() {
    local name="$1" env_val="${2:-}" default_port="${3:-}" user_val="" port="" i
    local prompt
    if [ -n "$default_port" ]; then
        prompt="请输入 ${name} 端口(留空默认 ${default_port}): "
    else
        prompt="请输入 ${name} 端口(留空则随机 10000-60000): "
    fi
    if [ -n "$env_val" ]; then
        port="$env_val"
    else
        read -r -p "$prompt" user_val
        port="${user_val:-}"
    fi
    if [ -z "$port" ]; then
        if [ -n "$default_port" ] && ! port_taken "$default_port"; then
            port="$default_port"
        else
            [ -n "$default_port" ] && warn "${name} 默认端口 ${default_port} 已被占用，改为随机端口"
            for i in $(seq 1 30); do
                port=$(rand_port)
                port_taken "$port" || break
                port=""
            done
        fi
        [ -n "$port" ] || { err "无法分配空闲端口"; exit 1; }
    fi
    if ! is_valid_port "$port"; then
        err "${name} 端口无效: $port"
        exit 1
    fi
    if port_taken "$port"; then
        err "${name} 端口已被占用: $port"
        exit 1
    fi
    mark_port "$port"
    echo "$port"
}

load_kv_file() {
    local file="$1"
    local line key val
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
        key="${line%%=*}"
        val="${line#*=}"
        case "$key" in
            ENABLE_SS|ENABLE_HY2|ENABLE_TUIC|ENABLE_REALITY|ENABLE_ANYTLS|CUSTOM_IP|REALITY_SNI|SS_PORT|SS_PSK|SS_METHOD|HY2_PORT|HY2_PSK|TUIC_PORT|TUIC_UUID|TUIC_PSK|REALITY_PORT|REALITY_UUID|REALITY_PK|REALITY_SID|REALITY_PUB|ANYTLS_PORT|ANYTLS_USER|ANYTLS_PSK)
                printf -v "$key" '%s' "$val"
                ;;
        esac
    done < "$file"
}

cache_set() {
    local file="$1" key="$2" val="$3"
    local tmp
    tmp=$(mktemp 2>/dev/null || echo "/tmp/cache_set.$$")
    if [ -f "$file" ]; then
        awk -v k="$key" -v v="$val" '
            BEGIN { found=0 }
            index($0, k"=")==1 { print k"="v; found=1; next }
            { print }
            END { if (!found) print k"="v }
        ' "$file" > "$tmp" && mv "$tmp" "$file"
    else
        printf '%s=%s\n' "$key" "$val" > "$file"
    fi
}

# 生成随机密码
rand_pass() {
    local pass
    pass=$(openssl rand -base64 16 2>/dev/null | tr -d '\n\r') || pass=$(head -c 16 /dev/urandom | base64 2>/dev/null | tr -d '\n\r')
    echo "$pass"
}

# 生成UUID
rand_uuid() {
    local uuid
    if [ -f /proc/sys/kernel/random/uuid ]; then
        uuid=$(cat /proc/sys/kernel/random/uuid)
    else
        uuid=$(openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/')
    fi
    echo "$uuid"
}

# Reality dest：全球高校 / 科研机构（尽量选自建源站，避开纯 CDN）
# 格式: domain|lat|lon|名称
reality_dest_catalog() {
    cat <<'DESTS'
www.stanford.edu|37.4275|-122.1697|Stanford University
www.berkeley.edu|37.8719|-122.2585|UC Berkeley
www.ucla.edu|34.0689|-118.4452|UCLA
www.caltech.edu|34.1377|-118.1253|Caltech
www.washington.edu|47.6553|-122.3035|University of Washington
www.mit.edu|42.3601|-71.0942|MIT
www.harvard.edu|42.3770|-71.1167|Harvard University
www.yale.edu|41.3163|-72.9223|Yale University
www.princeton.edu|40.3431|-74.6551|Princeton University
www.columbia.edu|40.8075|-73.9626|Columbia University
www.cornell.edu|42.4534|-76.4735|Cornell University
www.cmu.edu|40.4433|-79.9436|Carnegie Mellon
www.uchicago.edu|41.7886|-87.5987|University of Chicago
www.umich.edu|42.2780|-83.7382|University of Michigan
www.utexas.edu|30.2849|-97.7341|UT Austin
www.gatech.edu|33.7756|-84.3963|Georgia Tech
www.jhu.edu|39.3299|-76.6205|Johns Hopkins
www.nyu.edu|40.7295|-73.9965|NYU
www.utoronto.ca|43.6629|-79.3957|University of Toronto
www.ubc.ca|49.2606|-123.2460|UBC
www.mcgill.ca|45.5048|-73.5772|McGill University
www.ox.ac.uk|51.7548|-1.2544|University of Oxford
www.cam.ac.uk|52.2053|0.1218|University of Cambridge
www.imperial.ac.uk|51.4988|-0.1749|Imperial College London
www.ucl.ac.uk|51.5246|-0.1340|UCL
www.ed.ac.uk|55.9445|-3.1892|University of Edinburgh
www.ethz.ch|47.3763|8.5476|ETH Zurich
www.epfl.ch|46.5191|6.5668|EPFL
www.tum.de|48.1497|11.5678|Technical University of Munich
www.sorbonne-universite.fr|48.8487|2.3431|Sorbonne University
www.ku.dk|55.6802|12.5724|University of Copenhagen
www.uva.nl|52.3558|4.9557|University of Amsterdam
www.kth.se|59.3498|18.0706|KTH
home.cern|46.2330|6.0557|CERN
www.mpg.de|48.1410|11.5820|Max Planck Society
www.u-tokyo.ac.jp|35.7128|139.7620|University of Tokyo
www.kyoto-u.ac.jp|35.0263|135.7808|Kyoto University
www.osaka-u.ac.jp|34.8190|135.5230|Osaka University
www.nus.edu.sg|1.2966|103.7764|NUS
www.ntu.edu.sg|1.3483|103.6831|NTU Singapore
www.hkust.edu.hk|22.3364|114.2655|HKUST
www.hku.hk|22.2830|114.1371|University of Hong Kong
www.cuhk.edu.hk|22.4196|114.2068|CUHK
www.kaist.ac.kr|36.3721|127.3604|KAIST
www.snu.ac.kr|37.4601|126.9520|Seoul National University
www.ntu.edu.tw|25.0173|121.5397|National Taiwan University
www.nthu.edu.tw|24.7961|120.9967|NTHU
www.tsinghua.edu.cn|40.0000|116.3260|Tsinghua University
www.pku.edu.cn|39.9869|116.3059|Peking University
www.fudan.edu.cn|31.2989|121.4992|Fudan University
www.sjtu.edu.cn|31.0252|121.4337|Shanghai Jiao Tong
www.ustc.edu.cn|31.8384|117.2644|USTC
www.zju.edu.cn|30.2638|120.1230|Zhejiang University
www.unimelb.edu.au|-37.7964|144.9612|University of Melbourne
www.sydney.edu.au|-33.8882|151.1873|University of Sydney
www.anu.edu.au|-35.2777|149.1185|Australian National University
www.auckland.ac.nz|-36.8523|174.7691|University of Auckland
www.riken.jp|35.7800|139.6130|RIKEN
DESTS
}

haversine_km() {
    awk -v lat1="$1" -v lon1="$2" -v lat2="$3" -v lon2="$4" 'BEGIN{
        pi = 3.141592653589793
        rlat1 = lat1 * pi / 180
        rlat2 = lat2 * pi / 180
        dlat = (lat2 - lat1) * pi / 180
        dlon = (lon2 - lon1) * pi / 180
        a = sin(dlat/2)^2 + cos(rlat1) * cos(rlat2) * sin(dlon/2)^2
        if (a > 1) a = 1
        c = 2 * atan2(sqrt(a), sqrt(1-a))
        printf "%d", 6371 * c
    }'
}

lookup_server_geo() {
    GEO_LAT=""
    GEO_LON=""
    GEO_CITY=""
    GEO_COUNTRY=""
    GEO_IP=""

    local json="" loc status
    json=$(curl -fsS --max-time 6 "https://ipinfo.io/json" 2>/dev/null || true)
    if [ -n "$json" ] && command -v jq >/dev/null 2>&1; then
        GEO_IP=$(printf '%s' "$json" | jq -r '.ip // empty')
        GEO_CITY=$(printf '%s' "$json" | jq -r '.city // empty')
        GEO_COUNTRY=$(printf '%s' "$json" | jq -r '.country // empty')
        loc=$(printf '%s' "$json" | jq -r '.loc // empty')
        if [[ "$loc" =~ ^-?[0-9.]+,-?[0-9.]+$ ]]; then
            GEO_LAT="${loc%%,*}"
            GEO_LON="${loc#*,}"
        fi
    fi

    if [ -z "$GEO_LAT" ] || [ -z "$GEO_LON" ]; then
        json=$(curl -fsS --max-time 6 "http://ip-api.com/json/?fields=status,lat,lon,country,city,query" 2>/dev/null || true)
        if [ -n "$json" ] && command -v jq >/dev/null 2>&1; then
            status=$(printf '%s' "$json" | jq -r '.status // empty')
            if [ "$status" = "success" ]; then
                GEO_IP=$(printf '%s' "$json" | jq -r '.query // empty')
                GEO_CITY=$(printf '%s' "$json" | jq -r '.city // empty')
                GEO_COUNTRY=$(printf '%s' "$json" | jq -r '.country // empty')
                GEO_LAT=$(printf '%s' "$json" | jq -r '.lat // empty')
                GEO_LON=$(printf '%s' "$json" | jq -r '.lon // empty')
            fi
        fi
    fi

    [ -n "$GEO_LAT" ] && [ -n "$GEO_LON" ]
}

# 探测站点是否适合做 Reality dest：TLS1.3 + HTTP/2，证书 SAN 覆盖 SNI，排除常见 CDN
probe_reality_dest() {
    local host="$1"
    local out headers code ver tms rest san_ok tls_ok
    local tmp_body tmp_err
    tmp_body=$(mktemp 2>/dev/null || echo "/tmp/reality_body.$$")
    tmp_err=$(mktemp 2>/dev/null || echo "/tmp/reality_err.$$")

    local curl_opts=(--connect-timeout 4 --max-time 8)
    # 部分系统 curl 文档里有 --tlsv1.3，但编出来没有；TLS1.3 改由 openssl 校验
    if curl -V 2>/dev/null | grep -qi http2; then
        curl_opts+=(--http2)
    fi

    headers=$(curl -sSI "${curl_opts[@]}" "https://${host}/" 2>/dev/null || true)
    if printf '%s' "$headers" | grep -Eiq \
        '^[Ss]erver:[[:space:]]*(cloudflare|cloudfront|akamai|gws|gse|fastly|sucuri|incapsula)|[[:space:]]cf-ray:|[[:space:]]x-amz-cf-id:|[[:space:]]x-cache:[[:space:]].*cloudfront|[[:space:]]x-served-by:[[:space:]]*cache-|[[:space:]]x-fastly-request-id:'; then
        rm -f "$tmp_body" "$tmp_err"
        return 1
    fi

    out=$(curl -sS -o "$tmp_body" "${curl_opts[@]}" \
        -w '%{http_code}|%{http_version}|%{ssl_verify_result}|%{time_appconnect}' \
        "https://${host}/" 2>"$tmp_err") || {
        rm -f "$tmp_body" "$tmp_err"
        return 1
    }

    code="${out%%|*}"
    rest="${out#*|}"
    ver="${rest%%|*}"
    rest="${rest#*|}"
    local verify="${rest%%|*}"
    tms="${rest#*|}"

    rm -f "$tmp_body"
    [ -z "$code" ] || [ "$code" = "000" ] && { rm -f "$tmp_err"; return 1; }
    [ "$verify" = "0" ] || { rm -f "$tmp_err"; return 1; }
    case "$ver" in
        2|2.0) ;;
        *) rm -f "$tmp_err"; return 1 ;;
    esac

    san_ok=0
    tls_ok=0
    if command -v openssl >/dev/null 2>&1; then
        local handshake cert names cn
        handshake=$(echo | openssl s_client -servername "$host" -connect "${host}:443" -tls1_3 2>/dev/null || true)
        printf '%s' "$handshake" | grep -Eq 'Protocol[[:space:]]*:[[:space:]]*TLSv1\.3' && tls_ok=1
        cert=$(printf '%s' "$handshake" | openssl x509 -noout -text -subject 2>/dev/null || true)
        names=$(printf '%s' "$cert" | tr ',' '\n' | sed -n 's/.*DNS:[[:space:]]*//p' | tr -d ' ')
        cn=$(printf '%s' "$cert" | sed -n 's/.*CN[=[:space:]]*//p' | head -n1 | cut -d'/' -f1 | tr -d ' ')
        if printf '%s\n' "$names" "$cn" | grep -Fxq "$host"; then
            san_ok=1
        elif printf '%s\n' "$names" | grep -Eq "^\*\.${host#*.}$" && [[ "$host" == *.* ]]; then
            san_ok=1
        fi
    else
        san_ok=1
        tls_ok=1
    fi
    rm -f "$tmp_err"
    [ "$tls_ok" = "1" ] || return 1
    [ "$san_ok" = "1" ] || return 1

    awk -v t="$tms" 'BEGIN{
        if (t+0 <= 0) exit 1
        printf "%d", t * 1000
    }'
}

discover_reality_sni() {
    RECOMMENDED_SNI=""
    REALITY_SNI_REASON=""
    REALITY_SNI_CHOICES=()

    local result_file ranked_file
    result_file=$(mktemp 2>/dev/null || echo "/tmp/reality_sni_probe.$$")
    ranked_file=$(mktemp 2>/dev/null || echo "/tmp/reality_sni_rank.$$")
    : > "$result_file"

    info "正在定位本机出口并探测附近适合 Reality 的高校/机构站点..."
    if lookup_server_geo; then
        info "出口位置: ${GEO_CITY:-unknown}, ${GEO_COUNTRY:-unknown} (${GEO_LAT},${GEO_LON})"
    else
        warn "无法定位出口经纬度，改为按握手延迟全球优选"
    fi

    local domain lat lon label dist
    local -a jobs=()
    while IFS='|' read -r domain lat lon label; do
        [ -z "$domain" ] && continue
        if [ -n "${GEO_LAT:-}" ] && [ -n "${GEO_LON:-}" ]; then
            dist=$(haversine_km "$GEO_LAT" "$GEO_LON" "$lat" "$lon")
        else
            dist=99999
        fi
        printf '%s\n' "${dist}|${domain}|${label}"
    done < <(reality_dest_catalog) | sort -t'|' -k1,1n > "$ranked_file"

    local max_probe=16
    [ -z "${GEO_LAT:-}" ] && max_probe=20

    local count=0
    while IFS='|' read -r dist domain label; do
        [ -z "$domain" ] && continue
        count=$((count + 1))
        [ "$count" -gt "$max_probe" ] && break
        (
            local ms
            if ms=$(probe_reality_dest "$domain"); then
                printf '%s|%s|%s|%s\n' "$ms" "$dist" "$domain" "$label" >> "$result_file"
            fi
        ) &
        jobs+=("$!")
        if [ "${#jobs[@]}" -ge 8 ]; then
            wait "${jobs[0]}" || true
            jobs=("${jobs[@]:1}")
        fi
    done < "$ranked_file"
    wait || true

    if [ ! -s "$result_file" ]; then
        warn "附近高校/机构均未通过 TLS1.3+HTTP/2 探测"
        rm -f "$result_file" "$ranked_file"
        return 1
    fi

    local best_line best_ms best_dist best_label
    best_line=$(sort -t'|' -k1,1n "$result_file" | head -n1)
    RECOMMENDED_SNI=$(printf '%s' "$best_line" | cut -d'|' -f3)
    best_ms=$(printf '%s' "$best_line" | cut -d'|' -f1)
    best_dist=$(printf '%s' "$best_line" | cut -d'|' -f2)
    best_label=$(printf '%s' "$best_line" | cut -d'|' -f4-)

    if [ "$best_dist" != "99999" ]; then
        REALITY_SNI_REASON="${best_label} · 约 ${best_dist}km · 握手 ${best_ms}ms"
    else
        REALITY_SNI_REASON="${best_label} · 握手 ${best_ms}ms"
    fi

    echo ""
    info "探测通过的 Reality dest（按握手延迟排序）:"
    local i=0 line ms domain_i label_i
    while IFS='|' read -r ms dist domain_i label_i; do
        i=$((i + 1))
        [ "$i" -gt 5 ] && break
        REALITY_SNI_CHOICES+=("$domain_i")
        if [ "$dist" != "99999" ]; then
            echo "  $i) ${domain_i}  (${label_i}, ${dist}km, ${ms}ms)"
        else
            echo "  $i) ${domain_i}  (${label_i}, ${ms}ms)"
        fi
    done < <(sort -t'|' -k1,1n "$result_file")
    echo ""
    info "推荐 SNI: ${RECOMMENDED_SNI}  (${REALITY_SNI_REASON})"

    rm -f "$result_file" "$ranked_file"
    return 0
}

format_host() {
    local host="$1"
    if [[ "$host" == *:* && "$host" != \[* ]]; then
        printf '[%s]' "$host"
    else
        printf '%s' "$host"
    fi
}

# -----------------------
# 选择要部署的协议
select_protocols() {
    info "=== 选择要部署的协议 ==="
    echo "1) Shadowsocks (SS)"
    echo "2) Hysteria2 (HY2)"
    echo "3) TUIC"
    echo "4) VLESS Reality  (自动探测本机附近高校/机构 SNI)"
    echo "5) AnyTLS Reality (与 VLESS 共用 Reality 密钥/SNI)"
    echo ""
    echo "请输入要部署的协议编号(多个用空格分隔,如: 1 2 4):"
    read -r protocol_input
    
    # 使用全局变量
    ENABLE_SS=false
    ENABLE_HY2=false
    ENABLE_TUIC=false
    ENABLE_REALITY=false
    ENABLE_ANYTLS=false
    
    for num in $protocol_input; do
        case "$num" in
            1) ENABLE_SS=true ;;
            2) ENABLE_HY2=true ;;
            3) ENABLE_TUIC=true ;;
            4) ENABLE_REALITY=true ;;
            5) ENABLE_ANYTLS=true ;;
            *) warn "无效选项: $num" ;;
        esac
    done
    
    if ! $ENABLE_SS && ! $ENABLE_HY2 && ! $ENABLE_TUIC && ! $ENABLE_REALITY && ! $ENABLE_ANYTLS; then
        err "未选择任何协议,退出安装"
        exit 1
    fi
    
    # 保存协议选择到文件（确保持久化）
    mkdir -p /etc/sing-box
    cat > /etc/sing-box/.protocols <<EOF
ENABLE_SS=$ENABLE_SS
ENABLE_HY2=$ENABLE_HY2
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_REALITY=$ENABLE_REALITY
ENABLE_ANYTLS=$ENABLE_ANYTLS
EOF
    
    info "已选择协议:"
    $ENABLE_SS && echo "  - Shadowsocks"
    $ENABLE_HY2 && echo "  - Hysteria2"
    $ENABLE_TUIC && echo "  - TUIC"
    $ENABLE_REALITY && echo "  - VLESS Reality"
    $ENABLE_ANYTLS && echo "  - AnyTLS Reality"
    
    # 导出为全局变量（确保后续脚本可以访问）
    export ENABLE_SS
    export ENABLE_HY2
    export ENABLE_TUIC
    export ENABLE_REALITY
    export ENABLE_ANYTLS
}

# 创建配置目录
mkdir -p /etc/sing-box

KEEP_EXISTING_CONFIG=false
if [ -f /etc/sing-box/config.json ]; then
    warn "检测到已有 sing-box 配置: /etc/sing-box/config.json"
    echo "1) 保留现有配置，只更新二进制 / 管理脚本 (推荐)"
    echo "2) 全量重装（会重新生成端口、密码、UUID、Reality 密钥）"
    echo "3) 退出"
    read -r -p "请选择(默认 1): " reinstall_mode
    case "${reinstall_mode:-1}" in
        2) KEEP_EXISTING_CONFIG=false ;;
        3) info "已取消"; exit 0 ;;
        *) KEEP_EXISTING_CONFIG=true ;;
    esac
fi

if $KEEP_EXISTING_CONFIG; then
    info "保留现有节点配置，仅更新程序与管理面板"
    ENABLE_SS=false
    ENABLE_HY2=false
    ENABLE_TUIC=false
    ENABLE_REALITY=false
    ENABLE_ANYTLS=false
    load_kv_file /etc/sing-box/.protocols
    load_kv_file /etc/sing-box/.config_cache
    [ -n "${SS_PORT:-}" ] && ENABLE_SS=true
    [ -n "${HY2_PORT:-}" ] && ENABLE_HY2=true
    [ -n "${TUIC_PORT:-}" ] && ENABLE_TUIC=true
    [ -n "${REALITY_PORT:-}" ] && ENABLE_REALITY=true
    [ -n "${ANYTLS_PORT:-}" ] && ENABLE_ANYTLS=true
    suffix="$(cat /root/node_names.txt 2>/dev/null || true)"
    CUSTOM_IP="${CUSTOM_IP:-}"
    REALITY_SNI="${REALITY_SNI:-}"
    SS_METHOD="${SS_METHOD:-2022-blake3-aes-128-gcm}"
    PORT_SS="${SS_PORT:-}"
    PSK_SS="${SS_PSK:-}"
    PORT_HY2="${HY2_PORT:-}"
    PSK_HY2="${HY2_PSK:-}"
    PORT_TUIC="${TUIC_PORT:-}"
    UUID_TUIC="${TUIC_UUID:-}"
    PSK_TUIC="${TUIC_PSK:-}"
    PORT_REALITY="${REALITY_PORT:-}"
    UUID="${REALITY_UUID:-}"
    PORT_ANYTLS="${ANYTLS_PORT:-}"
else
    echo "请输入节点名称(留空则使用默认协议名):"
    read -r user_name
    if [[ -n "$user_name" ]]; then
        suffix="-${user_name}"
        echo "$suffix" > /root/node_names.txt
    else
        suffix=""
    fi
    select_protocols
fi

# -----------------------
# 选择SS加密方式（新增）
select_ss_method() {
    if ! $ENABLE_SS; then
        SS_METHOD="2022-blake3-aes-128-gcm"
        return 0
    fi
    
    info "=== 选择 Shadowsocks 加密方式 ==="
    echo "1) 2022-blake3-aes-128-gcm (推荐)"
    echo "2) aes-128-gcm"
    echo ""
    echo "请输入选择(默认为 1):"
    read -r ss_method_choice
    
    case "${ss_method_choice:-1}" in
        1) SS_METHOD="2022-blake3-aes-128-gcm" ;;
        2) SS_METHOD="aes-128-gcm" ;;
        *) 
            warn "无效选择，使用默认方式: 2022-blake3-aes-128-gcm"
            SS_METHOD="2022-blake3-aes-128-gcm"
            ;;
    esac
    
    info "已选择加密方式: $SS_METHOD"
    export SS_METHOD
}

if ! $KEEP_EXISTING_CONFIG; then
select_ss_method

# -----------------------
# 在获取公网 IP 之前，询问连接ip和sni配置
echo ""
echo "请输入节点连接 IP 或 DDNS域名(留空默认出口IP):"
read -r CUSTOM_IP
CUSTOM_IP="$(echo "$CUSTOM_IP" | tr -d '[:space:]')"

# 如果用户选择了 Reality 协议，按出口位置探测附近高校/机构 SNI
REALITY_SNI=""
RECOMMENDED_SNI=""
REALITY_SNI_REASON=""
REALITY_SNI_CHOICES=()
if $ENABLE_REALITY || $ENABLE_ANYTLS; then
    echo ""
    if discover_reality_sni; then
        echo "请选择 Reality SNI:"
        echo "  回车 使用推荐: ${RECOMMENDED_SNI}"
        echo "  1-5  选用上面探测通过的站点"
        echo "  或直接输入自定义域名"
        read -r REALITY_SNI_INPUT
        REALITY_SNI_INPUT="$(echo "${REALITY_SNI_INPUT:-}" | tr -d '[:space:]')"
        if [ -z "$REALITY_SNI_INPUT" ]; then
            REALITY_SNI="$RECOMMENDED_SNI"
        elif [[ "$REALITY_SNI_INPUT" =~ ^[1-5]$ ]] && [ -n "${REALITY_SNI_CHOICES[$((REALITY_SNI_INPUT-1))]:-}" ]; then
            REALITY_SNI="${REALITY_SNI_CHOICES[$((REALITY_SNI_INPUT-1))]}"
        else
            REALITY_SNI="$REALITY_SNI_INPUT"
        fi
    else
        warn "自动探测失败，回退到 www.microsoft.com"
        echo "请输入 Reality 的 SNI(留空默认 www.microsoft.com):"
        read -r REALITY_SNI
        REALITY_SNI="$(echo "${REALITY_SNI:-www.microsoft.com}" | tr -d '[:space:]')"
    fi
    info "已选择 Reality SNI: $REALITY_SNI"
else
    REALITY_SNI=""
fi

# 将用户选择写入缓存
mkdir -p /etc/sing-box
# preserve existing cache if any (append/overwrite relevant keys)
# 最简单直接：在后面 create_config 也会写入 .config_cache，先写初始值以便中间步骤可读取
echo "CUSTOM_IP=$CUSTOM_IP" > /etc/sing-box/.config_cache.tmp || true
echo "REALITY_SNI=$REALITY_SNI" >> /etc/sing-box/.config_cache.tmp || true
# 保留其他可能已有的缓存条目（若存在老的 .config_cache），把新临时与旧文件合并（保新值覆盖旧值）
if [ -f /etc/sing-box/.config_cache ]; then
    # 将旧文件中不在新文件内的行追加
    awk 'FNR==NR{a[$1]=1;next} {split($0,k,"="); if(!(k[1] in a)) print $0}' /etc/sing-box/.config_cache.tmp /etc/sing-box/.config_cache >> /etc/sing-box/.config_cache.tmp2 || true
    mv /etc/sing-box/.config_cache.tmp2 /etc/sing-box/.config_cache.tmp || true
fi
mv /etc/sing-box/.config_cache.tmp /etc/sing-box/.config_cache || true

# -----------------------
# 配置端口和密码
get_config() {
    info "开始配置端口和密码..."
    
    if $ENABLE_SS; then
        info "=== 配置 Shadowsocks (SS) ==="
        PORT_SS=$(alloc_port "SS" "${SINGBOX_PORT_SS:-}")
        PSK_SS=$(rand_pass)
        info "SS 端口: $PORT_SS"
        info "SS 加密方式: $SS_METHOD"
        info "SS 密码已自动生成"
    fi

    if $ENABLE_HY2; then
        info "=== 配置 Hysteria2 (HY2) ==="
        PORT_HY2=$(alloc_port "HY2" "${SINGBOX_PORT_HY2:-}")
        PSK_HY2=$(rand_pass)
        info "HY2 端口: $PORT_HY2"
        info "HY2 密码已自动生成"
    fi

    if $ENABLE_TUIC; then
        info "=== 配置 TUIC ==="
        PORT_TUIC=$(alloc_port "TUIC" "${SINGBOX_PORT_TUIC:-}")
        PSK_TUIC=$(rand_pass)
        UUID_TUIC=$(rand_uuid)
        info "TUIC 端口: $PORT_TUIC"
        info "TUIC UUID 和密码已自动生成"
    fi

    if $ENABLE_REALITY; then
        info "=== 配置 VLESS Reality ==="
        PORT_REALITY=$(alloc_port "VLESS Reality" "${SINGBOX_PORT_REALITY:-}" "443")
        UUID=$(rand_uuid)
        info "VLESS Reality 端口: $PORT_REALITY"
        info "VLESS Reality UUID 已自动生成"
    fi
    
    if $ENABLE_ANYTLS; then
        info "=== 配置 AnyTLS Reality ==="
        if $ENABLE_REALITY; then
            PORT_ANYTLS=$(alloc_port "AnyTLS Reality" "${SINGBOX_PORT_ANYTLS:-}")
        else
            PORT_ANYTLS=$(alloc_port "AnyTLS Reality" "${SINGBOX_PORT_ANYTLS:-}" "443")
        fi
        ANYTLS_USER=$(openssl rand -hex 4)
        ANYTLS_PSK=$(openssl rand -base64 16)
        info "AnyTLS Reality 端口: $PORT_ANYTLS"
        info "AnyTLS Reality 用户名: $ANYTLS_USER"
        info "AnyTLS Reality 密码已自动生成"
    fi

    info "配置完成，继续安装..."
}

get_config
fi

# -----------------------
# 安装 sing-box
install_singbox() {
    info "开始安装 sing-box..."

    if command -v sing-box >/dev/null 2>&1; then
        CURRENT_VERSION=$(sing-box version 2>/dev/null | head -1 || echo "unknown")
        warn "检测到已安装 sing-box: $CURRENT_VERSION"
        read -p "是否重新安装?(y/N): " REINSTALL
        if [[ ! "$REINSTALL" =~ ^[Yy]$ ]]; then
            info "跳过 sing-box 安装"
            return 0
        fi
    fi

    case "$OS" in
        alpine)
            info "使用 Edge 仓库安装 sing-box"
            apk update || { err "apk update 失败"; exit 1; }
            apk add --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community sing-box || {
                err "sing-box 安装失败"
                exit 1
            }
            ;;
        debian|redhat)
            bash <(curl -fsSL https://sing-box.app/install.sh) || {
                err "sing-box 安装失败"
                exit 1
            }
            ;;
        *)
            err "未支持的系统,无法安装 sing-box"
            exit 1
            ;;
    esac

    if ! command -v sing-box >/dev/null 2>&1; then
        err "sing-box 安装后未找到可执行文件"
        exit 1
    fi

    INSTALLED_VERSION=$(sing-box version 2>/dev/null | head -1 || echo "unknown")
    info "sing-box 安装成功: $INSTALLED_VERSION"
}

install_singbox

# -----------------------
# 生成 Reality 密钥对（必须在 sing-box 安装之后）
generate_reality_keys() {
    if ! $ENABLE_REALITY && ! $ENABLE_ANYTLS; then
        info "跳过 Reality 密钥生成（未选择 Reality 协议）"
        return 0
    fi
    
    info "生成 Reality 密钥对..."
    
    if ! command -v sing-box >/dev/null 2>&1; then
        err "sing-box 未安装，无法生成 Reality 密钥"
        exit 1
    fi
    
    REALITY_KEYS=$(sing-box generate reality-keypair 2>&1) || {
        err "生成 Reality 密钥失败"
        exit 1
    }
    
    REALITY_PK=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_PUB=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_SID=$(sing-box generate rand 8 --hex 2>&1) || {
        err "生成 Reality ShortID 失败"
        exit 1
    }
    
    if [ -z "$REALITY_PK" ] || [ -z "$REALITY_PUB" ] || [ -z "$REALITY_SID" ]; then
        err "Reality 密钥生成结果为空"
        exit 1
    fi
    
    mkdir -p /etc/sing-box
    echo -n "$REALITY_PUB" > /etc/sing-box/.reality_pub
    echo -n "$REALITY_SID" > /etc/sing-box/.reality_sid
    chmod 600 /etc/sing-box/.reality_pub /etc/sing-box/.reality_sid 2>/dev/null || true
    
    info "Reality 密钥已生成"
}

if ! $KEEP_EXISTING_CONFIG; then
generate_reality_keys
fi

# -----------------------
# 生成 HY2/TUIC 自签证书(仅在需要时)
generate_cert() {
    if ! $ENABLE_HY2 && ! $ENABLE_TUIC; then
        info "跳过证书生成(未选择 HY2 或 TUIC)"
        return 0
    fi
    
    info "生成 HY2/TUIC 自签证书..."
    mkdir -p /etc/sing-box/certs
    
    if [ ! -f /etc/sing-box/certs/fullchain.pem ] || [ ! -f /etc/sing-box/certs/privkey.pem ]; then
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
          -keyout /etc/sing-box/certs/privkey.pem \
          -out /etc/sing-box/certs/fullchain.pem \
          -days 3650 \
          -subj "/CN=www.bing.com" || {
            err "证书生成失败"
            exit 1
        }
        info "证书已生成"
    else
        info "证书已存在"
    fi
}

if ! $KEEP_EXISTING_CONFIG; then
generate_cert
fi

# -----------------------
# 生成配置文件
CONFIG_PATH="/etc/sing-box/config.json"

create_config() {
    info "生成配置文件: $CONFIG_PATH"

    mkdir -p "$(dirname "$CONFIG_PATH")"
    local inbounds
    inbounds='[]'

    if $ENABLE_SS; then
        inbounds=$(jq -c \
            --argjson port "$PORT_SS" \
            --arg method "$SS_METHOD" \
            --arg password "$PSK_SS" \
            '. + [{
              type: "shadowsocks",
              listen: "::",
              listen_port: $port,
              method: $method,
              password: $password,
              tag: "ss-in"
            }]' <<<"$inbounds")
    fi

    if $ENABLE_HY2; then
        inbounds=$(jq -c \
            --argjson port "$PORT_HY2" \
            --arg password "$PSK_HY2" \
            '. + [{
              type: "hysteria2",
              tag: "hy2-in",
              listen: "::",
              listen_port: $port,
              users: [{password: $password}],
              ignore_client_bandwidth: true,
              masquerade: "https://www.bing.com",
              tls: {
                enabled: true,
                alpn: ["h3"],
                certificate_path: "/etc/sing-box/certs/fullchain.pem",
                key_path: "/etc/sing-box/certs/privkey.pem"
              }
            }]' <<<"$inbounds")
    fi

    if $ENABLE_TUIC; then
        inbounds=$(jq -c \
            --argjson port "$PORT_TUIC" \
            --arg uuid "$UUID_TUIC" \
            --arg password "$PSK_TUIC" \
            '. + [{
              type: "tuic",
              tag: "tuic-in",
              listen: "::",
              listen_port: $port,
              users: [{uuid: $uuid, password: $password}],
              congestion_control: "bbr",
              tls: {
                enabled: true,
                alpn: ["h3"],
                certificate_path: "/etc/sing-box/certs/fullchain.pem",
                key_path: "/etc/sing-box/certs/privkey.pem"
              }
            }]' <<<"$inbounds")
    fi

    if $ENABLE_REALITY; then
        inbounds=$(jq -c \
            --argjson port "$PORT_REALITY" \
            --arg uuid "$UUID" \
            --arg sni "$REALITY_SNI" \
            --arg pk "$REALITY_PK" \
            --arg sid "$REALITY_SID" \
            '. + [{
              type: "vless",
              tag: "vless-in",
              listen: "::",
              listen_port: $port,
              tcp_fast_open: true,
              users: [{uuid: $uuid, flow: "xtls-rprx-vision"}],
              tls: {
                enabled: true,
                server_name: $sni,
                reality: {
                  enabled: true,
                  handshake: {server: $sni, server_port: 443},
                  private_key: $pk,
                  short_id: [$sid]
                }
              }
            }]' <<<"$inbounds")
    fi

    if $ENABLE_ANYTLS; then
        inbounds=$(jq -c \
            --argjson port "$PORT_ANYTLS" \
            --arg name "$ANYTLS_USER" \
            --arg password "$ANYTLS_PSK" \
            --arg sni "$REALITY_SNI" \
            --arg pk "$REALITY_PK" \
            --arg sid "$REALITY_SID" \
            '. + [{
              type: "anytls",
              tag: "anytls-in",
              listen: "::",
              listen_port: $port,
              users: [{name: $name, password: $password}],
              tls: {
                enabled: true,
                server_name: $sni,
                reality: {
                  enabled: true,
                  handshake: {server: $sni, server_port: 443},
                  private_key: $pk,
                  short_id: [$sid]
                }
              }
            }]' <<<"$inbounds")
    fi

    jq -n --argjson inbounds "$inbounds" '{
      log: {level: "info", timestamp: true},
      ntp: {enabled: true, server: "time.apple.com", server_port: 123, interval: "30m"},
      inbounds: $inbounds,
      outbounds: [{type: "direct", tag: "direct-out"}],
      route: {
        rules: [
          {action: "sniff", timeout: "1s"}
        ]
      }
    }' > "$CONFIG_PATH"

    if sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
        info "配置文件验证通过"
    else
        err "配置文件验证失败"
        sing-box check -c "$CONFIG_PATH" || true
        exit 1
    fi

    # 保存配置缓存（追加/覆盖）
    cat > /etc/sing-box/.config_cache <<CACHEEOF
ENABLE_SS=$ENABLE_SS
ENABLE_HY2=$ENABLE_HY2
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_REALITY=$ENABLE_REALITY
ENABLE_ANYTLS=$ENABLE_ANYTLS
CACHEEOF

    $ENABLE_SS && cat >> /etc/sing-box/.config_cache <<CACHEEOF
SS_PORT=$PORT_SS
SS_PSK=$PSK_SS
SS_METHOD=$SS_METHOD
CACHEEOF

    $ENABLE_HY2 && cat >> /etc/sing-box/.config_cache <<CACHEEOF
HY2_PORT=$PORT_HY2
HY2_PSK=$PSK_HY2
CACHEEOF

    $ENABLE_TUIC && cat >> /etc/sing-box/.config_cache <<CACHEEOF
TUIC_PORT=$PORT_TUIC
TUIC_UUID=$UUID_TUIC
TUIC_PSK=$PSK_TUIC
CACHEEOF

    $ENABLE_REALITY && cat >> /etc/sing-box/.config_cache <<CACHEEOF
REALITY_PORT=$PORT_REALITY
REALITY_UUID=$UUID
CACHEEOF

    $ENABLE_ANYTLS && cat >> /etc/sing-box/.config_cache <<CACHEEOF
ANYTLS_PORT=$PORT_ANYTLS
ANYTLS_USER=$ANYTLS_USER
ANYTLS_PSK=$ANYTLS_PSK
CACHEEOF

    if $ENABLE_REALITY || $ENABLE_ANYTLS; then
        cat >> /etc/sing-box/.config_cache <<CACHEEOF
REALITY_PK=$REALITY_PK
REALITY_SID=$REALITY_SID
REALITY_PUB=$REALITY_PUB
REALITY_SNI=$REALITY_SNI
CACHEEOF
    fi

    # 全局写入 CUSTOM_IP（哪怕为空也写）
    echo "CUSTOM_IP=$CUSTOM_IP" >> /etc/sing-box/.config_cache
    chmod 600 /etc/sing-box/.config_cache "$CONFIG_PATH" 2>/dev/null || true
    chmod 700 /etc/sing-box 2>/dev/null || true

    info "配置缓存已保存到 /etc/sing-box/.config_cache"
}

# 调用配置生成
if ! $KEEP_EXISTING_CONFIG; then
create_config
else
    info "跳过配置生成，沿用现有 $CONFIG_PATH"
    [ -n "${SERVICE_PATH:-}" ] || true
fi

info "配置生成完成，准备设置服务..."

# -----------------------
# 设置服务
ensure_service_user() {
    if id sing-box >/dev/null 2>&1; then
        return 0
    fi
    if command -v useradd >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin --home-dir /etc/sing-box sing-box 2>/dev/null \
            || useradd --system --no-create-home --shell /sbin/nologin sing-box
    elif command -v adduser >/dev/null 2>&1; then
        adduser -S -H -s /sbin/nologin -h /etc/sing-box sing-box 2>/dev/null || true
    fi
    id sing-box >/dev/null 2>&1 || { err "无法创建 sing-box 系统用户"; exit 1; }
}

setup_service() {
    info "配置系统服务..."
    SINGBOX_BIN="$(command -v sing-box || true)"
    [ -n "$SINGBOX_BIN" ] || SINGBOX_BIN="/usr/bin/sing-box"
    ensure_service_user
    chown -R sing-box:sing-box /etc/sing-box
    chmod 750 /etc/sing-box
    chmod 640 /etc/sing-box/config.json 2>/dev/null || true
    if command -v setcap >/dev/null 2>&1; then
        setcap cap_net_bind_service=+ep "$SINGBOX_BIN" 2>/dev/null || warn "setcap 失败，443 可能需要额外权限"
    fi
    
    if [ "$OS" = "alpine" ]; then
        SERVICE_PATH="/etc/init.d/sing-box"
        
        cat > "$SERVICE_PATH" <<OPENRC
#!/sbin/openrc-run

name="sing-box"
description="Sing-box Proxy Server"
command="${SINGBOX_BIN}"
command_args="run -c /etc/sing-box/config.json"
command_user="sing-box"
pidfile="/run/\${RC_SVCNAME}.pid"
command_background="yes"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"
# 自动拉起（程序崩溃、OOM、被 kill 后自动恢复）
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --mode 0755 /var/log
    checkpath --directory --mode 0755 /run
}
OPENRC
        
        chmod +x "$SERVICE_PATH"
        rc-update add sing-box default >/dev/null 2>&1 || warn "添加开机自启失败"
        rc-service sing-box restart || {
            err "服务启动失败"
            tail -20 /var/log/sing-box.err 2>/dev/null || tail -20 /var/log/sing-box.log 2>/dev/null || true
            exit 1
        }
        
        sleep 2
        if rc-service sing-box status >/dev/null 2>&1; then
            info "✅ OpenRC 服务已启动"
        else
            err "服务状态异常"
            exit 1
        fi
        
    else
        SERVICE_PATH="/etc/systemd/system/sing-box.service"
        
        cat > "$SERVICE_PATH" <<SYSTEMD
[Unit]
Description=Sing-box Proxy Server
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=sing-box
Group=sing-box
WorkingDirectory=/etc/sing-box
ExecStart=${SINGBOX_BIN} run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SYSTEMD
        
        systemctl daemon-reload
        systemctl enable sing-box >/dev/null 2>&1
        systemctl restart sing-box || {
            err "服务启动失败"
            journalctl -u sing-box -n 30 --no-pager
            exit 1
        }
        
        sleep 2
        if systemctl is-active sing-box >/dev/null 2>&1; then
            info "✅ Systemd 服务已启动"
        else
            err "服务状态异常"
            exit 1
        fi
    fi
    
    info "服务配置完成: $SERVICE_PATH"
}

# 开启 BBR，并按需调大 UDP 缓冲
enable_bbr() {
    info "配置 BBR 拥塞控制..."

    if [ "$OS" = "alpine" ]; then
        if ! lsmod 2>/dev/null | grep -q '^tcp_bbr'; then
            modprobe tcp_bbr 2>/dev/null || true
        fi
        if ! grep -q '^tcp_bbr' /etc/modules 2>/dev/null; then
            echo tcp_bbr >> /etc/modules
        fi
    fi

    mkdir -p /etc/sysctl.d
    {
        echo "net.core.default_qdisc=fq"
        echo "net.ipv4.tcp_congestion_control=bbr"
        if $ENABLE_HY2 || $ENABLE_TUIC; then
            echo "net.core.rmem_max=16777216"
            echo "net.core.wmem_max=16777216"
        fi
    } > /etc/sysctl.d/99-singbox-bbr.conf

    sysctl -p /etc/sysctl.d/99-singbox-bbr.conf >/dev/null 2>&1 || true

    local cc qdisc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)
    if [ "$cc" = "bbr" ]; then
        info "BBR 已启用 (qdisc=${qdisc})"
    else
        warn "当前拥塞控制为 ${cc}，该内核可能未编译 BBR，已写入 /etc/sysctl.d/99-singbox-bbr.conf"
    fi
}

print_firewall_hint() {
    local ports=()
    $ENABLE_SS && ports+=("$PORT_SS/tcp")
    $ENABLE_HY2 && ports+=("$PORT_HY2/udp")
    $ENABLE_TUIC && ports+=("$PORT_TUIC/udp")
    $ENABLE_REALITY && ports+=("$PORT_REALITY/tcp")
    $ENABLE_ANYTLS && ports+=("$PORT_ANYTLS/tcp")
    [ "${#ports[@]}" -eq 0 ] && return 0
    echo ""
    info "请在云安全组 / 防火墙放行: ${ports[*]}"
}

setup_service
enable_bbr

# -----------------------
# 获取公网 IP
get_public_ip() {
    local ip=""
    for url in \
        "https://api.ipify.org" \
        "https://api64.ipify.org" \
        "https://ipinfo.io/ip" \
        "https://ifconfig.me" \
        "https://icanhazip.com" \
        "https://ipecho.net/plain"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$ip" =~ ^[0-9a-fA-F:]+$ && "$ip" == *:* ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

# 如果用户提供了 CUSTOM_IP，则优先使用；否则自动检测出口 IP
if [ -n "${CUSTOM_IP:-}" ]; then
    PUB_IP="$CUSTOM_IP"
    info "使用用户提供的连接IP或ddns域名 : $PUB_IP"
else
    PUB_IP=$(get_public_ip || echo "YOUR_SERVER_IP")
    if [ "$PUB_IP" = "YOUR_SERVER_IP" ]; then
        warn "无法获取公网 IP,请手动替换"
    else
        info "检测到公网 IP: $PUB_IP"
    fi
fi

# -----------------------
# 生成链接(仅生成已选择的协议)
generate_uris() {
    local host
    host="$(format_host "$PUB_IP")"
    
    if $ENABLE_SS; then
        local ss_userinfo="${SS_METHOD}:${PSK_SS}"
        ss_b64=$(printf "%s" "$ss_userinfo" | base64 -w0 2>/dev/null || printf "%s" "$ss_userinfo" | base64 | tr -d '\n')

        echo "=== Shadowsocks (SS) ==="
        echo "ss://${ss_b64}@${host}:${PORT_SS}#ss${suffix}"
        echo ""
    fi
    
    if $ENABLE_HY2; then
        hy2_encoded=$(printf "%s" "$PSK_HY2" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        echo "=== Hysteria2 (HY2) ==="
        echo "hy2://${hy2_encoded}@${host}:${PORT_HY2}/?sni=www.bing.com&alpn=h3&insecure=1#hy2${suffix}"
        echo ""
    fi

    if $ENABLE_TUIC; then
        tuic_encoded=$(printf "%s" "$PSK_TUIC" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        echo "=== TUIC ==="
        echo "tuic://${UUID_TUIC}:${tuic_encoded}@${host}:${PORT_TUIC}/?congestion_control=bbr&alpn=h3&sni=www.bing.com&insecure=1#tuic${suffix}"
        echo ""
    fi
    
    if $ENABLE_REALITY; then
        echo "=== VLESS Reality ==="
        echo "vless://${UUID}@${host}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#reality${suffix}"
        echo ""
    fi

    if $ENABLE_ANYTLS; then
        anytls_pass_encoded=$(printf "%s" "$ANYTLS_PSK" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        echo "=== AnyTLS Reality ==="
        echo "anytls://${anytls_pass_encoded}@${host}:${PORT_ANYTLS}/?security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#anytls${suffix}"
        echo ""
    fi
}

# -----------------------
# 最终输出
echo ""
echo "=========================================="
info "🎉 Sing-box 部署完成!"
echo "=========================================="
echo ""
info "📋 配置信息:"
$ENABLE_SS && echo "   SS 端口: $PORT_SS | 密码: $PSK_SS | 加密: $SS_METHOD"
$ENABLE_HY2 && echo "   HY2 端口: $PORT_HY2 | 密码: $PSK_HY2"
$ENABLE_TUIC && echo "   TUIC 端口: $PORT_TUIC | UUID: $UUID_TUIC | 密码: $PSK_TUIC"
$ENABLE_REALITY && echo "   Reality 端口: $PORT_REALITY | UUID: $UUID"
$ENABLE_ANYTLS && echo "   AnyTLS 端口: $PORT_ANYTLS | 用户: $ANYTLS_USER | 密码: $ANYTLS_PSK"
    echo "   服务器: $PUB_IP"
    if $ENABLE_REALITY || $ENABLE_ANYTLS; then
        echo "   Reality server_name(SNI): $REALITY_SNI"
        [ -n "${REALITY_SNI_REASON:-}" ] && echo "   SNI 来源: $REALITY_SNI_REASON"
    fi
echo ""
info "📂 文件位置:"
echo "   配置: $CONFIG_PATH"
($ENABLE_HY2 || $ENABLE_TUIC) && echo "   证书: /etc/sing-box/certs/"
echo "   服务: $SERVICE_PATH"
echo ""
info "📜 客户端链接:"
generate_uris | while IFS= read -r line; do
    echo "   $line"
done
echo ""
info "🔧 管理命令:"
if [ "$OS" = "alpine" ]; then
    echo "   启动: rc-service sing-box start"
    echo "   停止: rc-service sing-box stop"
    echo "   重启: rc-service sing-box restart"
    echo "   状态: rc-service sing-box status"
    echo "   日志: tail -f /var/log/sing-box.log"
else
    echo "   启动: systemctl start sing-box"
    echo "   停止: systemctl stop sing-box"
    echo "   重启: systemctl restart sing-box"
    echo "   状态: systemctl status sing-box"
    echo "   日志: journalctl -u sing-box -f"
    fi
    print_firewall_hint
    echo ""
    echo "=========================================="

# -----------------------
# 导出 SNI 探测函数，供 sb 复用
mkdir -p /usr/local/lib/singbox-yyds
{
    echo '#!/usr/bin/env bash'
    declare -f reality_dest_catalog haversine_km lookup_server_geo probe_reality_dest discover_reality_sni
} > /usr/local/lib/singbox-yyds/sni.sh
chmod 755 /usr/local/lib/singbox-yyds/sni.sh

# 创建 sb 管理脚本
SB_PATH="/usr/local/bin/sb"
info "正在创建 sb 管理面板: $SB_PATH"

cat > "$SB_PATH" <<'SB_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

CONFIG_PATH="/etc/sing-box/config.json"
CACHE_FILE="/etc/sing-box/.config_cache"
SERVICE_NAME="sing-box"

# 检测系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        ID="${ID:-}"
        ID_LIKE="${ID_LIKE:-}"
    else
        ID=""
        ID_LIKE=""
    fi

    if echo "$ID $ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$ID $ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
        OS="debian"
    elif echo "$ID $ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then
        OS="redhat"
    else
        OS="unknown"
    fi
}

detect_os

# 服务控制
service_start() {
    [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" start || systemctl start "$SERVICE_NAME"
}
service_stop() {
    [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" stop || systemctl stop "$SERVICE_NAME"
}
service_restart() {
    [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" restart || systemctl restart "$SERVICE_NAME"
}
service_status() {
    [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" status || systemctl status "$SERVICE_NAME" --no-pager
}

# 生成随机值
rand_port() { shuf -i 10000-60000 -n 1 2>/dev/null || echo $((RANDOM % 50001 + 10000)); }
rand_pass() { openssl rand -base64 16 | tr -d '\n\r' || head -c 16 /dev/urandom | base64 | tr -d '\n\r'; }
rand_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/'; }

ask_new_port() {
    local current="$1" label="$2" new_port
    read -r -p "输入新的 ${label} 端口(回车保持 $current): " new_port
    new_port="${new_port:-$current}"
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        err "端口无效: $new_port"
        return 1
    fi
    printf '%s' "$new_port"
}

# URL 编码
url_encode() {
    printf "%s" "$1" | sed -e 's/%/%25/g' -e 's/:/%3A/g' -e 's/+/%2B/g' -e 's/\//%2F/g' -e 's/=/%3D/g'
}

# 读取配置
read_config() {
    if [ ! -f "$CONFIG_PATH" ]; then
        err "未找到配置文件: $CONFIG_PATH"
        return 1
    fi
    
    load_kv_file() {
        local file="$1" line key val
        [ -f "$file" ] || return 0
        while IFS= read -r line || [ -n "$line" ]; do
            [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
            key="${line%%=*}"
            val="${line#*=}"
            case "$key" in
                ENABLE_SS|ENABLE_HY2|ENABLE_TUIC|ENABLE_REALITY|ENABLE_ANYTLS|CUSTOM_IP|REALITY_SNI|SS_PORT|SS_PSK|SS_METHOD|HY2_PORT|HY2_PSK|TUIC_PORT|TUIC_UUID|TUIC_PSK|REALITY_PORT|REALITY_UUID|REALITY_PK|REALITY_SID|REALITY_PUB|ANYTLS_PORT|ANYTLS_USER|ANYTLS_PSK)
                    printf -v "$key" '%s' "$val"
                    ;;
            esac
        done < "$file"
    }

    cache_set() {
        local file="$1" key="$2" val="$3" tmp
        tmp=$(mktemp 2>/dev/null || echo "/tmp/cache_set.$$")
        if [ -f "$file" ]; then
            awk -v k="$key" -v v="$val" '
                BEGIN { found=0 }
                index($0, k"=")==1 { print k"="v; found=1; next }
                { print }
                END { if (!found) print k"="v }
            ' "$file" > "$tmp" && mv "$tmp" "$file"
        else
            printf '%s=%s\n' "$key" "$val" > "$file"
        fi
        chmod 600 "$file" 2>/dev/null || true
    }

    # 优先加载 .protocols 文件（确认协议标记）
    PROTOCOL_FILE="/etc/sing-box/.protocols"
    load_kv_file "$PROTOCOL_FILE"
    load_kv_file "$CACHE_FILE"
    
    # 确保有默认值
    REALITY_SNI="${REALITY_SNI:-}"
    ENABLE_ANYTLS="${ENABLE_ANYTLS:-false}"
    CUSTOM_IP="${CUSTOM_IP:-}"

    if [ -z "$REALITY_SNI" ] && [ -f "$CONFIG_PATH" ]; then
        REALITY_SNI=$(jq -r '
            .inbounds[]
            | select(.tls.reality.enabled == true)
            | .tls.server_name // empty
        ' "$CONFIG_PATH" 2>/dev/null | head -n1)
    fi
    REALITY_SNI="${REALITY_SNI:-www.microsoft.com}"

    # 读取各协议配置
    if [ "${ENABLE_SS:-false}" = "true" ]; then
        SS_PORT=$(jq -r '.inbounds[] | select(.type=="shadowsocks") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
        SS_PSK=$(jq -r '.inbounds[] | select(.type=="shadowsocks") | .password // empty' "$CONFIG_PATH" | head -n1)
        SS_METHOD=$(jq -r '.inbounds[] | select(.type=="shadowsocks") | .method // empty' "$CONFIG_PATH" | head -n1)
    fi
    
    if [ "${ENABLE_HY2:-false}" = "true" ]; then
        HY2_PORT=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
        HY2_PSK=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .users[0].password // empty' "$CONFIG_PATH" | head -n1)
    fi
    
    if [ "${ENABLE_TUIC:-false}" = "true" ]; then
        TUIC_PORT=$(jq -r '.inbounds[] | select(.type=="tuic") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
        TUIC_UUID=$(jq -r '.inbounds[] | select(.type=="tuic") | .users[0].uuid // empty' "$CONFIG_PATH" | head -n1)
        TUIC_PSK=$(jq -r '.inbounds[] | select(.type=="tuic") | .users[0].password // empty' "$CONFIG_PATH" | head -n1)
    fi
    
# Reality 公共参数（Reality / AnyTLS 共用）
if [ "${ENABLE_REALITY:-false}" = "true" ] || [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
    REALITY_SID=$(jq -r '
        .inbounds[]
        | select(.tls.reality.enabled == true)
        | .tls.reality.short_id[0] // empty
    ' "$CONFIG_PATH" | head -n1)

    [ -f /etc/sing-box/.reality_pub ] && REALITY_PUB=$(cat /etc/sing-box/.reality_pub)
fi

# VLESS Reality 专属参数
if [ "${ENABLE_REALITY:-false}" = "true" ]; then
    REALITY_PORT=$(jq -r '.inbounds[] | select(.type=="vless") | .listen_port // empty' "$CONFIG_PATH" | head -n1)

    REALITY_UUID=$(jq -r '.inbounds[] | select(.type=="vless") | .users[0].uuid // empty' "$CONFIG_PATH" | head -n1)

    REALITY_PK=$(jq -r '.inbounds[] | select(.type=="vless") | .tls.reality.private_key // empty' "$CONFIG_PATH" | head -n1)
fi

if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
    ANYTLS_PORT=$(jq -r '.inbounds[] | select(.type=="anytls") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
    ANYTLS_USER=$(jq -r '.inbounds[] | select(.type=="anytls") | .users[0].name // empty' "$CONFIG_PATH" | head -n1)
    ANYTLS_PSK=$(jq -r '.inbounds[] | select(.type=="anytls") | .users[0].password // empty' "$CONFIG_PATH" | head -n1)
fi
}

# 获取公网IP
get_public_ip() {
    local ip=""
    for url in \
        "https://api.ipify.org" \
        "https://api64.ipify.org" \
        "https://ipinfo.io/ip" \
        "https://ifconfig.me"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$ip" =~ : ]]; then
            echo "$ip"
            return 0
        fi
    done
    echo "YOUR_SERVER_IP"
}

format_host() {
    local host="$1"
    if [[ "$host" == *:* && "$host" != \[* ]]; then
        printf '[%s]' "$host"
    else
        printf '%s' "$host"
    fi
}

# 生成并保存URI
generate_uris() {
    read_config || return 1

    # 优先使用用户自定义入口 IP
    if [ -n "${CUSTOM_IP:-}" ]; then
        PUBLIC_IP="$CUSTOM_IP"
    else
        PUBLIC_IP=$(get_public_ip)
    fi
    PUBLIC_HOST="$(format_host "$PUBLIC_IP")"

    node_suffix=$(cat /root/node_names.txt 2>/dev/null || echo "")
    
    URI_FILE="/etc/sing-box/uris.txt"
    > "$URI_FILE"
    
    if [ "${ENABLE_SS:-false}" = "true" ]; then
        ss_userinfo="${SS_METHOD}:${SS_PSK}"
        ss_b64=$(printf "%s" "$ss_userinfo" | base64 -w0 2>/dev/null || printf "%s" "$ss_userinfo" | base64 | tr -d '\n')
        
        echo "=== Shadowsocks (SS) ===" >> "$URI_FILE"
        echo "ss://${ss_b64}@${PUBLIC_HOST}:${SS_PORT}#ss${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi
    
    if [ "${ENABLE_HY2:-false}" = "true" ]; then
        hy2_encoded=$(url_encode "$HY2_PSK")
        echo "=== Hysteria2 (HY2) ===" >> "$URI_FILE"
        echo "hy2://${hy2_encoded}@${PUBLIC_HOST}:${HY2_PORT}/?sni=www.bing.com&alpn=h3&insecure=1#hy2${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi
    
    if [ "${ENABLE_TUIC:-false}" = "true" ]; then
        tuic_encoded=$(url_encode "$TUIC_PSK")
        echo "=== TUIC ===" >> "$URI_FILE"
        echo "tuic://${TUIC_UUID}:${tuic_encoded}@${PUBLIC_HOST}:${TUIC_PORT}/?congestion_control=bbr&alpn=h3&sni=www.bing.com&insecure=1#tuic${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi
    
    if [ "${ENABLE_REALITY:-false}" = "true" ]; then
        REALITY_SNI="${REALITY_SNI:-www.microsoft.com}"
        echo "=== VLESS Reality ===" >> "$URI_FILE"
        echo "vless://${REALITY_UUID}@${PUBLIC_HOST}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#reality${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi
    
    if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
        anytls_pass_encoded=$(url_encode "$ANYTLS_PSK")
        echo "=== AnyTLS Reality ===" >> "$URI_FILE"
        echo "anytls://${anytls_pass_encoded}@${PUBLIC_HOST}:${ANYTLS_PORT}/?security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#anytls${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi

    chmod 600 "$URI_FILE" 2>/dev/null || true
    info "URI 已保存到: $URI_FILE"
}

# 查看URI
action_view_uri() {
    info "正在生成并显示 URI..."
    generate_uris || { err "生成 URI 失败"; return 1; }
    echo ""
    cat /etc/sing-box/uris.txt
}

# 查看配置文件路径
action_view_config() {
    echo "$CONFIG_PATH"
}

# 编辑配置
action_edit_config() {
    if [ ! -f "$CONFIG_PATH" ]; then
        err "配置文件不存在: $CONFIG_PATH"
        return 1
    fi
    
    ${EDITOR:-nano} "$CONFIG_PATH" 2>/dev/null || ${EDITOR:-vi} "$CONFIG_PATH"
    
    if command -v sing-box >/dev/null 2>&1; then
        if sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
            info "配置校验通过,已重启服务"
            service_restart || warn "重启失败"
            generate_uris || true
        else
            warn "配置校验失败,服务未重启"
        fi
    fi
}

# 重置SS端口
action_reset_ss() {
    read_config || return 1
    
    if [ "${ENABLE_SS:-false}" != "true" ]; then
        err "SS 协议未启用"
        return 1
    fi
    
    new_port=$(ask_new_port "$SS_PORT" "SS") || return 1
    
    info "正在停止服务..."
    service_stop || warn "停止服务失败"
    
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    
    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="shadowsocks" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    info "已启动服务并更新 SS 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置HY2端口
action_reset_hy2() {
    read_config || return 1
    
    if [ "${ENABLE_HY2:-false}" != "true" ]; then
        err "HY2 协议未启用"
        return 1
    fi
    
    new_port=$(ask_new_port "$HY2_PORT" "HY2") || return 1
    
    info "正在停止服务..."
    service_stop || warn "停止服务失败"
    
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    
    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="hysteria2" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    info "已启动服务并更新 HY2 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置TUIC端口
action_reset_tuic() {
    read_config || return 1
    
    if [ "${ENABLE_TUIC:-false}" != "true" ]; then
        err "TUIC 协议未启用"
        return 1
    fi
    
    new_port=$(ask_new_port "$TUIC_PORT" "TUIC") || return 1
    
    info "正在停止服务..."
    service_stop || warn "停止服务失败"
    
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    
    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="tuic" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    info "已启动服务并更新 TUIC 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置Vless Reality端口
action_reset_reality() {
    read_config || return 1
    
    if [ "${ENABLE_REALITY:-false}" != "true" ]; then
        err "Vless Reality 协议未启用"
        return 1
    fi
    
    new_port=$(ask_new_port "$REALITY_PORT" "VLESS Reality") || return 1
    
    info "正在停止服务..."
    service_stop || warn "停止服务失败"
    
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    
    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="vless" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    info "已启动服务并更新 Vless Reality 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置AnyTLS Reality端口
action_reset_anytls() {
    read_config || return 1

    if [ "${ENABLE_ANYTLS:-false}" != "true" ]; then
        err "AnyTLS Reality 协议未启用"
        return 1
    fi

    new_port=$(ask_new_port "$ANYTLS_PORT" "AnyTLS Reality") || return 1

    info "正在停止服务..."
    service_stop || warn "停止服务失败"

    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"

    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="anytls" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    info "已启动服务并更新 AnyTLS Reality 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 更换 Reality SNI（按出口位置重新探测附近高校/机构）
action_change_sni() {
    read_config || return 1

    if [ "${ENABLE_REALITY:-false}" != "true" ] && [ "${ENABLE_ANYTLS:-false}" != "true" ]; then
        err "未启用 Reality / AnyTLS，无需修改 SNI"
        return 1
    fi

    if [ -f /usr/local/lib/singbox-yyds/sni.sh ]; then
        # shellcheck disable=SC1091
        . /usr/local/lib/singbox-yyds/sni.sh
    fi

    if ! command -v discover_reality_sni >/dev/null 2>&1; then
        err "未找到 SNI 探测函数，请重新运行安装脚本"
        return 1
    fi

    info "当前 Reality SNI: ${REALITY_SNI}"
    RECOMMENDED_SNI=""
    REALITY_SNI_REASON=""
    REALITY_SNI_CHOICES=()
    local new_sni=""
    if discover_reality_sni; then
        echo "请选择新的 Reality SNI:"
        echo "  回车 使用推荐: ${RECOMMENDED_SNI}"
        echo "  1-5  选用上面探测通过的站点"
        echo "  或直接输入自定义域名"
        read -r sni_input
        sni_input="$(echo "${sni_input:-}" | tr -d '[:space:]')"
        if [ -z "$sni_input" ]; then
            new_sni="$RECOMMENDED_SNI"
        elif [[ "$sni_input" =~ ^[1-5]$ ]] && [ -n "${REALITY_SNI_CHOICES[$((sni_input-1))]:-}" ]; then
            new_sni="${REALITY_SNI_CHOICES[$((sni_input-1))]}"
        else
            new_sni="$sni_input"
        fi
    else
        echo "请输入新的 Reality SNI(留空取消):"
        read -r new_sni
        new_sni="$(echo "${new_sni:-}" | tr -d '[:space:]')"
        [ -z "$new_sni" ] && info "已取消" && return 0
    fi

    info "正在停止服务..."
    service_stop || warn "停止服务失败"
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"

    jq --arg sni "$new_sni" '
      .inbounds |= map(
        if (.tls.reality.enabled == true) then
          .tls.server_name = $sni
          | .tls.reality.handshake.server = $sni
        else . end
      )
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    cache_set "$CACHE_FILE" REALITY_SNI "$new_sni"

    info "已更新 Reality SNI: $new_sni"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

action_rotate_uuid() {
    read_config || return 1
    if [ "${ENABLE_REALITY:-false}" != "true" ]; then
        err "VLESS Reality 未启用"
        return 1
    fi
    local new_uuid
    new_uuid=$(rand_uuid)
    info "正在更换 VLESS UUID..."
    service_stop || warn "停止服务失败"
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    jq --arg uuid "$new_uuid" '
      .inbounds |= map(if .type=="vless" then .users[0].uuid = $uuid else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    cache_set "$CACHE_FILE" REALITY_UUID "$new_uuid"
    chown sing-box:sing-box "$CONFIG_PATH" 2>/dev/null || true
    info "新 UUID: $new_uuid"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

action_rotate_reality_keys() {
    read_config || return 1
    if [ "${ENABLE_REALITY:-false}" != "true" ] && [ "${ENABLE_ANYTLS:-false}" != "true" ]; then
        err "未启用 Reality / AnyTLS"
        return 1
    fi
    if ! command -v sing-box >/dev/null 2>&1; then
        err "未找到 sing-box"
        return 1
    fi
    info "正在更换 Reality 密钥和 ShortID..."
    local keys pk pub sid
    keys=$(sing-box generate reality-keypair) || { err "生成密钥失败"; return 1; }
    pk=$(printf '%s' "$keys" | awk '/PrivateKey/{print $NF}' | tr -d '\r')
    pub=$(printf '%s' "$keys" | awk '/PublicKey/{print $NF}' | tr -d '\r')
    sid=$(sing-box generate rand 8 --hex) || { err "生成 ShortID 失败"; return 1; }
    [ -n "$pk" ] && [ -n "$pub" ] && [ -n "$sid" ] || { err "密钥为空"; return 1; }

    service_stop || warn "停止服务失败"
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    jq --arg pk "$pk" --arg sid "$sid" '
      .inbounds |= map(
        if (.tls.reality.enabled == true) then
          .tls.reality.private_key = $pk
          | .tls.reality.short_id = [$sid]
        else . end
      )
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    printf '%s' "$pub" > /etc/sing-box/.reality_pub
    printf '%s' "$sid" > /etc/sing-box/.reality_sid
    chmod 600 /etc/sing-box/.reality_pub /etc/sing-box/.reality_sid
    chown sing-box:sing-box "$CONFIG_PATH" /etc/sing-box/.reality_pub /etc/sing-box/.reality_sid 2>/dev/null || true
    cache_set "$CACHE_FILE" REALITY_PK "$pk"
    cache_set "$CACHE_FILE" REALITY_PUB "$pub"
    cache_set "$CACHE_FILE" REALITY_SID "$sid"
    info "Reality 公钥已更新: $pub"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 更新sing-box
action_update() {
    info "开始更新 sing-box..."
    if [ "$OS" = "alpine" ]; then
        apk update && apk upgrade sing-box || bash <(curl -fsSL https://sing-box.app/install.sh)
    else
        bash <(curl -fsSL https://sing-box.app/install.sh)
    fi
    
    info "更新完成,已重启服务..."
    if command -v sing-box >/dev/null 2>&1; then
        NEW_VER=$(sing-box version 2>/dev/null | head -n1)
        info "当前版本: $NEW_VER"
        service_restart || warn "重启失败"
    fi
}

# 卸载
action_uninstall() {
    read -p "确认卸载 sing-box?(y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && info "已取消" && return 0
    
    info "正在卸载..."
    service_stop || true
    if [ "$OS" = "alpine" ]; then
        rc-update del sing-box default 2>/dev/null || true
        rm -f /etc/init.d/sing-box
        apk del sing-box 2>/dev/null || true
    else
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload 2>/dev/null || true
        if command -v dnf >/dev/null 2>&1; then
            dnf remove -y sing-box >/dev/null 2>&1 || true
        elif command -v yum >/dev/null 2>&1; then
            yum remove -y sing-box >/dev/null 2>&1 || true
        else
            apt-get purge -y sing-box >/dev/null 2>&1 || true
        fi
    fi
    rm -rf /etc/sing-box /var/log/sing-box* /usr/local/bin/sb /usr/bin/sb \
        /usr/bin/sing-box /usr/local/bin/sing-box /usr/local/lib/singbox-yyds \
        /root/node_names.txt /etc/sysctl.d/99-singbox-bbr.conf \
        /etc/sysctl.d/99-singbox-udp.conf 2>/dev/null || true
    info "卸载完成"
}

# 生成线路机脚本
action_generate_relay() {
    read_config || return 1
    
    # 检查是否启用了SS
    if [ "${ENABLE_SS:-false}" != "true" ]; then
        warn "未检测到 SS 协议,需要先部署 SS 作为入站"
        read -p "是否现在部署 SS 协议?(y/N): " deploy_ss
        if [[ "$deploy_ss" =~ ^[Yy]$ ]]; then
            info "开始部署 SS 协议..."
            
            # 让用户选择端口
            read -p "请输入 SS 端口(留空则随机 10000-60000): " USER_SS_PORT
            SS_PORT="${USER_SS_PORT:-$(rand_port)}"
            SS_PSK=$(rand_pass)
            SS_METHOD="aes-128-gcm"
            
            info "SS 端口: $SS_PORT | 密码已自动生成"
            
            info "正在停止服务..."
            service_stop || warn "停止服务失败"
            
            cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
            
            # 添加 SS inbound
            jq --argjson port "$SS_PORT" --arg psk "$SS_PSK" '
            .inbounds += [{
              "type": "shadowsocks",
              "listen": "::",
              "listen_port": $port,
              "method": "aes-128-gcm",
              "password": $psk,
              "tag": "ss-in"
            }]
            ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            
            # 更新缓存和协议标记
            sed -i 's/ENABLE_SS=false/ENABLE_SS=true/' "$CACHE_FILE" 2>/dev/null || echo "ENABLE_SS=true" >> "$CACHE_FILE"
            echo "SS_PORT=$SS_PORT" >> "$CACHE_FILE"
            echo "SS_PSK=$SS_PSK" >> "$CACHE_FILE"
            echo "SS_METHOD=$SS_METHOD" >> "$CACHE_FILE"
            
            # 同步更新协议标记文件
            PROTOCOL_FILE="/etc/sing-box/.protocols"
            if [ -f "$PROTOCOL_FILE" ]; then
                sed -i 's/ENABLE_SS=false/ENABLE_SS=true/' "$PROTOCOL_FILE"
            else
                echo "ENABLE_SS=true" >> "$PROTOCOL_FILE"
            fi
            
            # 更新当前会话变量
            ENABLE_SS=true
            
            info "SS 已部署 - 端口: $SS_PORT"
            service_start || warn "启动服务失败"
            sleep 1
            
            # 重新读取配置
            read_config
        else
            err "取消生成线路机脚本"
            return 1
        fi
    fi
    
    # 线路机模板使用 CUSTOM_IP（若设置）或当前公共 IP
    if [ -n "${CUSTOM_IP:-}" ]; then
        INBOUND_IP="${CUSTOM_IP}"
    else
        INBOUND_IP="$(get_public_ip)"
    fi

    PUBLIC_IP="$INBOUND_IP"
    RELAY_SCRIPT="/tmp/relay-install.sh"
    
    info "正在生成线路机脚本: $RELAY_SCRIPT"
    
    cat > "$RELAY_SCRIPT" <<'RELAY_EOF'
#!/usr/bin/env bash
set -euo pipefail

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

[ "$(id -u)" != "0" ] && err "必须以 root 运行" && exit 1

detect_os(){
    . /etc/os-release 2>/dev/null || true
    case "${ID:-}" in
        alpine) OS=alpine ;;
        debian|ubuntu) OS=debian ;;
        centos|rhel|fedora) OS=redhat ;;
        *) OS=unknown ;;
    esac
}
detect_os

info "安装依赖..."
case "$OS" in
    alpine) apk update; apk add --no-cache curl jq bash openssl ca-certificates ;;
    debian) apt-get update -y; apt-get install -y curl jq bash openssl ca-certificates ;;
    redhat) yum install -y curl jq bash openssl ca-certificates ;;
esac

info "安装 sing-box..."
case "$OS" in
    alpine) apk add --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community sing-box ;;
    *) bash <(curl -fsSL https://sing-box.app/install.sh) ;;
esac

UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "00000000-0000-0000-0000-000000000000")

info "生成 Reality 密钥对"
REALITY_KEYS=$(sing-box generate reality-keypair 2>/dev/null || echo "")
REALITY_PK=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $NF}' | tr -d '\r' || echo "")
REALITY_PUB=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $NF}' | tr -d '\r' || echo "")
REALITY_SID=$(sing-box generate rand 8 --hex 2>/dev/null || echo "0123456789abcdef")

read -p "请输入线路机监听端口(留空随机 20000-65000): " USER_PORT
LISTEN_PORT="${USER_PORT:-$(shuf -i 20000-65000 -n 1 2>/dev/null || echo 20443)}"

mkdir -p /etc/sing-box

cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": $LISTEN_PORT,
      "users": [{ "uuid": "$UUID", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "__REALITY_SNI__",
        "reality": {
          "enabled": true,
          "handshake": { "server": "__REALITY_SNI__", "server_port": 443 },
          "private_key": "$REALITY_PK",
          "short_id": ["$REALITY_SID"]
        }
      },
      "tag": "vless-in"
    }
  ],
  "outbounds": [
    {
      "type": "shadowsocks",
      "server": "__INBOUND_IP__",
      "server_port": __INBOUND_PORT__,
      "method": "__INBOUND_METHOD__",
      "password": "__INBOUND_PASSWORD__",
      "tag": "relay-out"
    },
    { "type": "direct", "tag": "direct-out" }
  ],
  "route": { "rules": [{ "inbound": "vless-in", "outbound": "relay-out" }] }
}
EOF

if [ "$OS" = "alpine" ]; then
    cat > /etc/init.d/sing-box <<'SVC'
#!/sbin/openrc-run
name="sing-box"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/sing-box.pid"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"

depend() { need net; }
SVC
    chmod +x /etc/init.d/sing-box
    rc-update add sing-box default
    rc-service sing-box restart
else
    cat > /etc/systemd/system/sing-box.service <<'SYSTEMD'
[Unit]
Description=Sing-box Relay
After=network.target
[Service]
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10s
[Install]
WantedBy=multi-user.target
SYSTEMD
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl restart sing-box
fi

PUB_IP=$(curl -s https://api.ipify.org 2>/dev/null || echo "YOUR_RELAY_IP")

# 生成并保存链接
RELAY_URI="vless://$UUID@$PUB_IP:$LISTEN_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=__REALITY_SNI__&fp=chrome&pbk=$REALITY_PUB&sid=$REALITY_SID#relay"

mkdir -p /etc/sing-box
echo "$RELAY_URI" > /etc/sing-box/relay_uri.txt

echo ""
info "✅ 安装完成"
echo "=============== 中转节点 Reality 链接 ==============="
echo "$RELAY_URI"
echo "===================================================="
echo ""
info "💡 链接已保存到: /etc/sing-box/relay_uri.txt"
info "💡 查看链接命令: cat /etc/sing-box/relay_uri.txt"
RELAY_EOF

    # 替换占位符（INBOUND_IP/PORT/METHOD/PASSWORD 同时替换 REALITY_SNI）
    sed -i "s|__INBOUND_IP__|$INBOUND_IP|g" "$RELAY_SCRIPT"
    sed -i "s|__INBOUND_PORT__|$SS_PORT|g" "$RELAY_SCRIPT"
    sed -i "s|__INBOUND_METHOD__|$SS_METHOD|g" "$RELAY_SCRIPT"
    sed -i "s|__INBOUND_PASSWORD__|$SS_PSK|g" "$RELAY_SCRIPT"
    sed -i "s|__REALITY_SNI__|${REALITY_SNI:-www.microsoft.com}|g" "$RELAY_SCRIPT"
    
    chmod +x "$RELAY_SCRIPT"
    
    info "✅ 线路机脚本已生成: $RELAY_SCRIPT"
    echo ""
    info "请复制以下内容到线路机执行:"
    echo "----------------------------------------"
    cat "$RELAY_SCRIPT"
    echo "----------------------------------------"
    echo ""
    info "在线路机执行命令示例："
    echo "   nano /tmp/relay-install.sh 保存后执行"
    echo "   chmod +x /tmp/relay-install.sh && bash /tmp/relay-install.sh"
    echo ""
    info "复制执行完成后，即可在线路机完成 sing-box 中转节点部署。"
}

# 动态生成菜单
show_menu() {
    read_config 2>/dev/null || true
    
    cat <<'MENU'

==========================
 Sing-box 管理面板 (快速指令sb)
==========================
1) 查看协议链接
2) 查看配置文件路径
3) 编辑配置文件
MENU

    # 构建协议重置选项映射
    declare -g -A MENU_MAP
    local option=4
    
    if [ "${ENABLE_SS:-false}" = "true" ]; then
        echo "$option) 重置 SS 端口"
        MENU_MAP[$option]="reset_ss"
        option=$((option + 1))
    fi
    
    if [ "${ENABLE_HY2:-false}" = "true" ]; then
        echo "$option) 重置 HY2 端口"
        MENU_MAP[$option]="reset_hy2"
        option=$((option + 1))
    fi
    
    if [ "${ENABLE_TUIC:-false}" = "true" ]; then
        echo "$option) 重置 TUIC 端口"
        MENU_MAP[$option]="reset_tuic"
        option=$((option + 1))
    fi
    
    if [ "${ENABLE_REALITY:-false}" = "true" ]; then
        echo "$option) 重置 Vless Reality 端口"
        MENU_MAP[$option]="reset_reality"
        option=$((option + 1))
    fi
    
    if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
        echo "$option) 重置 AnyTLS Reality 端口"
        MENU_MAP[$option]="reset_anytls"
        option=$((option + 1))
    fi

    if [ "${ENABLE_REALITY:-false}" = "true" ] || [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
        echo "$option) 更换 Reality SNI(探测附近高校/机构)"
        MENU_MAP[$option]="change_sni"
        option=$((option + 1))
    fi

    if [ "${ENABLE_REALITY:-false}" = "true" ]; then
        echo "$option) 更换 VLESS UUID"
        MENU_MAP[$option]="rotate_uuid"
        option=$((option + 1))
    fi

    if [ "${ENABLE_REALITY:-false}" = "true" ] || [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
        echo "$option) 更换 Reality 密钥"
        MENU_MAP[$option]="rotate_keys"
        option=$((option + 1))
    fi

    # 固定功能选项
    MENU_MAP[$option]="start"
    echo "$option) 启动服务"
    option=$((option + 1))
    
    MENU_MAP[$option]="stop"
    echo "$((option))) 停止服务"
    option=$((option + 1))
    
    MENU_MAP[$option]="restart"
    echo "$((option))) 重启服务"
    option=$((option + 1))
    
    MENU_MAP[$option]="status"
    echo "$((option))) 查看状态"
    option=$((option + 1))
    
    MENU_MAP[$option]="update"
    echo "$((option))) 更新 sing-box"
    option=$((option + 1))
    
    MENU_MAP[$option]="relay"
    echo "$((option))) 生成线路机脚本(出口为本机ss协议)"
    option=$((option + 1))
    
    MENU_MAP[$option]="uninstall"
    echo "$((option))) 卸载 sing-box"
    
    cat <<MENU2
0) 退出
==========================
MENU2
}

# 主循环
while true; do
    show_menu
    read -p "请输入选项: " opt
    
    # 处理退出
    if [ "$opt" = "0" ]; then
        exit 0
    fi
    
    # 处理固定选项
    case "$opt" in
        1) action_view_uri ;;
        2) action_view_config ;;
        3) action_edit_config ;;
        *)
            # 处理动态选项
            action="${MENU_MAP[$opt]:-}"
            case "$action" in
                reset_ss) action_reset_ss ;;
                reset_hy2) action_reset_hy2 ;;
                reset_tuic) action_reset_tuic ;;
                reset_reality) action_reset_reality ;;
                reset_anytls) action_reset_anytls ;;
                change_sni) action_change_sni ;;
                rotate_uuid) action_rotate_uuid ;;
                rotate_keys) action_rotate_reality_keys ;;
                start) service_start && info "已启动" ;;
                stop) service_stop && info "已停止" ;;
                restart) service_restart && info "已重启" ;;
                status) service_status ;;
                update) action_update ;;
                relay) action_generate_relay ;;
                uninstall) action_uninstall; exit 0 ;;
                *) warn "无效选项: $opt" ;;
            esac
            ;;
    esac
    
    echo ""
done
SB_SCRIPT

chmod +x "$SB_PATH"
ln -sf /usr/local/bin/sb /usr/bin/sb
info "✅ 管理面板已创建,可输入 sb 打开管理面板"
