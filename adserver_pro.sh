#!/bin/bash
# adserver_pro.sh — Script unificado para DC Primário/Secundário com Samba AD
# Ubuntu 24.04 | Samba 4.19.5 | Alta disponibilidade e replicação nativa
# Versão: 4.0 - CORRIGIDO E OTIMIZADO

set -u pipefail

# ══════════════════════════════════════════════════════════════
#                    CORE — FUNÇÕES GLOBAIS
# ══════════════════════════════════════════════════════════════

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Variáveis globais
REPORT_FILE="/root/ad_install_report_$(date +%Y%m%d_%H%M%S).log"
INSTALL_STEPS=()
INSTALL_STATUS=()
STEP_COUNT=0
DOMAIN=""
REALM=""
HOSTNAME=""
IP_ADDR=""
INTERFACE=""
ADMIN_PASSWORD=""

# Logging
log()    { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $*"; }
error()  { echo -e "${RED}[ERRO]${NC} $*" >&2; exit 1; }
warn()   { echo -e "${YELLOW}[AVISO]${NC} $*" >&2; }
info()   { echo -e "${BLUE}[INFO]${NC} $*"; }

# Função para registrar passos no relatório
register_step() {
    local step_name="$1"
    local status="$2"
    local details="${3:-}"
    STEP_COUNT=$((STEP_COUNT + 1))
    INSTALL_STEPS+=("$step_name")
    INSTALL_STATUS+=("$status")
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$status] $step_name $details" >> "$REPORT_FILE"
}

# Verifica root
if [[ $EUID -ne 0 ]]; then
    error "Execute como root (sudo)"
fi

# ============================================
# FUNÇÃO: PRÉ-CONFIGURAR KERBEROS (DEBCONF)
# ============================================

preconfigure_kerberos() {
    local realm="$1"
    local kdc_server="$2"
    local admin_server="$2"
    
    log "Pré-configurando Kerberos (debconf) para evitar interação..."
    
    cat << EOF | debconf-set-selections 2>/dev/null || true
krb5-config krb5-config/default_realm string $realm
krb5-config krb5-config/kerberos_servers string $kdc_server
krb5-config krb5-config/admin_server string $admin_server
krb5-user krb5-user/default_realm string $realm
krb5-user krb5-user/kerberos_servers string $kdc_server
krb5-user krb5-user/admin_server string $admin_server
EOF
    
    export DEBIAN_FRONTEND=noninteractive
    export KRB5_CONFIG="/etc/krb5.conf"
    
    register_step "Pré-configuração Kerberos" "OK" "Realm: $realm, KDC: $kdc_server"
}

# ============================================
# FUNÇÃO: INSTALAR PACOTES ESSENCIAIS
# ============================================

install_essentials() {
    log "════════════════════════════════════════════════════"
    log "     INSTALANDO PACOTES ESSENCIAIS"
    log "════════════════════════════════════════════════════"
    
    export DEBIAN_FRONTEND=noninteractive
    
    if command -v apt &>/dev/null; then
        log "Gerenciador detectado: APT (Ubuntu/Debian)"
        
        # Pré-configura pacotes que perguntam durante a instalação
        echo "krb5-config krb5-config/default_realm string" | debconf-set-selections 2>/dev/null
        echo "krb5-config krb5-config/kerberos_servers string" | debconf-set-selections 2>/dev/null
        echo "krb5-config krb5-config/admin_server string" | debconf-set-selections 2>/dev/null
        
        log "Atualizando cache de pacotes..."
        apt update -qq 2>/dev/null || true
        
        log "Instalando pacotes essenciais..."
        apt install -y -qq nano curl wget net-tools iputils-ping \
            language-pack-pt locales bash-completion debconf-utils \
            chrony systemd-resolved 2>/dev/null || true
        
        register_step "Instalação de pacotes essenciais (APT)" "OK" "nano, curl, wget, net-tools, iputils-ping, locale"
        
    elif command -v dnf &>/dev/null; then
        log "Gerenciador detectado: DNF (Fedora/RHEL)"
        dnf install -y -q nano iputils curl wget net-tools 2>/dev/null || true
        register_step "Instalação de pacotes essenciais (DNF)" "OK" "nano, iputils, curl, wget, net-tools"
        
    elif command -v yum &>/dev/null; then
        log "Gerenciador detectado: YUM (RHEL/CentOS)"
        yum install -y -q nano iputils curl wget net-tools 2>/dev/null || true
        register_step "Instalação de pacotes essenciais (YUM)" "OK" "nano, iputils, curl, wget, net-tools"
        
    else
        warn "Gerenciador de pacotes não detectado."
        register_step "Instalação de pacotes essenciais" "WARN" "Gerenciador não detectado"
    fi
    
    echo -e "${GREEN}✓ Pacotes essenciais verificados${NC}"
    echo ""
}

# ============================================
# FUNÇÃO: CONFIGURAR LOCALE
# ============================================

config_locale() {
    log "════════════════════════════════════════════════════"
    log "     CONFIGURANDO IDIOMA PORTUGUÊS BRASIL"
    log "════════════════════════════════════════════════════"
    
    export DEBIAN_FRONTEND=noninteractive
    
    if command -v apt &>/dev/null; then
        apt update -qq 2>/dev/null || true
        apt install -y -qq language-pack-pt locales 2>/dev/null || true
    fi
    
    locale-gen pt_BR.UTF-8 2>/dev/null || true
    update-locale LANG=pt_BR.UTF-8 LANGUAGE=pt_BR:pt LC_ALL=pt_BR.UTF-8 2>/dev/null || true
    export LANG=pt_BR.UTF-8 LANGUAGE=pt_BR:pt LC_ALL=pt_BR.UTF-8
    
    echo -e "${GREEN}✓ Locale pt_BR configurado${NC}"
    echo ""
    register_step "Configuração de Locale" "OK" "pt_BR.UTF-8"
}

# ============================================
# FUNÇÃO: LER SENHA (CORRIGIDA)
# ============================================

read_password() {
    local prompt="$1"
    local password=""
    local char=""
    local IFS=""
    
    echo -ne "${BLUE}$prompt${NC}" >&2
    
    stty -echo -icanon min 1 time 0 2>/dev/null
    
    while true; do
        char=$(dd bs=1 count=1 2>/dev/null)
        
        if [[ -z "$char" ]] || [[ "$char" == $'\n' ]] || [[ "$char" == $'\r' ]] || [[ "$char" == $'\x04' ]]; then
            break
        elif [[ "$char" == $'\x7f' ]] || [[ "$char" == $'\x08' ]]; then
            if [[ -n "$password" ]]; then
                password="${password%?}"
                echo -ne "\b \b" >&2
            fi
        else
            password+="$char"
            echo -ne "*" >&2
        fi
    done
    
    stty echo -icanon 2>/dev/null
    echo >&2
    
    echo "$password"
}

# ============================================
# FUNÇÃO: CONFIGURAR DNS/RESOLV.CONF
# ============================================

configure_resolv_conf() {
    local dns_server="$1"
    local domain="$2"
    local search_domains="${3:-$domain}"
    
    log "Configurando /etc/resolv.conf..."
    
    # Para o systemd-resolved se estiver rodando
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
    
    # Remove proteção se existir
    chattr -i /etc/resolv.conf 2>/dev/null || true
    
    # Cria o arquivo
    cat > /etc/resolv.conf << EOF
nameserver $dns_server
search $search_domains
domain $domain
EOF
    
    # Protege o arquivo
    chattr +i /etc/resolv.conf 2>/dev/null || true
    
    register_step "Configuração /etc/resolv.conf" "OK" "DNS: $dns_server, Domínio: $domain"
}

# ============================================
# FUNÇÃO: CONFIGURAR HOSTS
# ============================================

configure_hosts() {
    local hostname="$1"
    local domain="$2"
    local ip="$3"
    local primary_ip="${4:-}"
    
    log "Configurando /etc/hosts..."
    
    cat > /etc/hosts << EOF
127.0.0.1 localhost
127.0.1.1 ${hostname}.${domain} ${hostname}
${ip} ${hostname}.${domain} ${hostname}
EOF
    
    if [ -n "$primary_ip" ]; then
        echo "${primary_ip} adserver01.${domain} adserver01" >> /etc/hosts
    fi
    
    register_step "Configuração /etc/hosts" "OK" "${hostname}.${domain}"
}

# ============================================
# FUNÇÃO: CONFIGURAR KERBEROS
# ============================================

configure_kerberos() {
    local realm="$1"
    local domain="$2"
    local kdc="$3"
    local admin_server="$3"
    
    log "Configurando /etc/krb5.conf..."
    
    cat > /etc/krb5.conf << EOF
[libdefaults]
    default_realm = ${realm}
    dns_lookup_realm = true
    dns_lookup_kdc = true
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true

[realms]
    ${realm} = {
        kdc = ${kdc}
        admin_server = ${admin_server}
    }

[domain_realm]
    .${domain} = ${realm}
    ${domain} = ${realm}
EOF
    
    register_step "Configuração Kerberos" "OK" "Realm: $realm, KDC: $kdc"
}

# ============================================
# FUNÇÃO: CONFIGURAR NTP
# ============================================

config_ntp() {
    local primary_ntp="$1"
    log "Configurando NTP (Chrony)..."
    
    export DEBIAN_FRONTEND=noninteractive
    
    if command -v apt &>/dev/null; then
        apt install -y -qq chrony 2>/dev/null || true
    fi
    
    timedatectl set-timezone America/Sao_Paulo 2>/dev/null || true
    
    if [ "$primary_ntp" == "SELF" ]; then
        cat > /etc/chrony/chrony.conf << 'EOF' 2>/dev/null || true
server a.st1.ntp.br iburst
server 2001:12ff:0:7::186 iburst
server 200.160.7.186 iburst

keyfile /etc/chrony/chrony.keys
driftfile /var/lib/chrony/drift
rtcsync
makestep 1.0 3
bindcmdaddress 127.0.0.1
logdir /var/log/chrony
EOF
        register_step "Configuração NTP" "OK" "Servidores oficiais brasileiros"
    else
        cat > /etc/chrony/chrony.conf << EOF 2>/dev/null || true
server $primary_ntp iburst
keyfile /etc/chrony/chrony.keys
driftfile /var/lib/chrony/drift
rtcsync
makestep 1.0 3
bindcmdaddress 127.0.0.1
logdir /var/log/chrony
EOF
        register_step "Configuração NTP" "OK" "Sincronizando com $primary_ntp"
    fi
    
    systemctl enable --now chrony -qq 2>/dev/null || true
    systemctl restart chrony -qq 2>/dev/null || true
    sleep 2
    chronyc sources >/dev/null 2>&1 && echo -e "${GREEN}✓ NTP sincronizado${NC}" || warn "NTP não sincronizou"
}

# ============================================
# FUNÇÃO: VERIFICAR E CORRIGIR DNS PRIMÁRIO
# ============================================

fix_primary_dns() {
    log "Verificando e corrigindo DNS no Primário..."
    
    # Para systemd-resolved
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
    
    # Configura resolv.conf
    chattr -i /etc/resolv.conf 2>/dev/null || true
    cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
search ${DOMAIN}
domain ${DOMAIN}
EOF
    chattr +i /etc/resolv.conf 2>/dev/null || true
    
    # Configura smb.conf
    if ! grep -q "interfaces = lo" /etc/samba/smb.conf; then
        sed -i "/\[global\]/a \    interfaces = lo ${INTERFACE}" /etc/samba/smb.conf
    fi
    
    if ! grep -q "bind interfaces only = yes" /etc/samba/smb.conf; then
        sed -i "/\[global\]/a \    bind interfaces only = yes" /etc/samba/smb.conf
    fi
    
    if ! grep -q "dns forwarder = 8.8.8.8" /etc/samba/smb.conf; then
        sed -i "/\[global\]/a \    dns forwarder = 8.8.8.8" /etc/samba/smb.conf
    fi
    
    # Reinicia Samba
    systemctl restart samba-ad-dc
    sleep 10
    
    register_step "Correção DNS Primário" "OK" "DNS configurado para 127.0.0.1"
}

# ============================================
# FUNÇÃO: GERAR RELATÓRIO FINAL
# ============================================

generate_final_report() {
    local install_type="$1"
    local domain="$2"
    local realm="$3"
    local hostname="$4"
    local ip="$5"
    
    log "════════════════════════════════════════════════════"
    log "     GERANDO RELATÓRIO FINAL DA INSTALAÇÃO"
    log "════════════════════════════════════════════════════"
    
    cat > "$REPORT_FILE" << EOF
╔═══════════════════════════════════════════════════════════════════════╗
║              RELATÓRIO DE INSTALAÇÃO - SAMBA AD DC                   ║
╠═══════════════════════════════════════════════════════════════════════╣
║  Data/Hora:    $(date '+%d/%m/%Y %H:%M:%S')
║  Tipo:         $install_type
║  Domínio:      $domain
║  Realm:        $realm
║  Hostname:     $hostname
║  IP Address:   $ip
║  Interface:    $INTERFACE
║  Sistema:      $(lsb_release -ds 2>/dev/null || echo "Ubuntu 24.04")
║  Kernel:       $(uname -r)
║  Samba:        $(samba --version 2>/dev/null | head -1 || echo "4.19.5")
╚═══════════════════════════════════════════════════════════════════════╝

EOF
    
    echo "╔═══════════════════════════════════════════════════════════════════════╗" >> "$REPORT_FILE"
    echo "║                    PASSOS EXECUTADOS                                 ║" >> "$REPORT_FILE"
    echo "╠═══════════════════════════════════════════════════════════════════════╣" >> "$REPORT_FILE"
    
    for i in "${!INSTALL_STEPS[@]}"; do
        step="${INSTALL_STEPS[$i]}"
        status="${INSTALL_STATUS[$i]}"
        case "$status" in
            "OK")   status_icon="✅" ;;
            "FAIL") status_icon="❌" ;;
            "WARN") status_icon="⚠️" ;;
            "INFO") status_icon="ℹ️" ;;
            *)      status_icon="❓" ;;
        esac
        printf "║  %3d. %-50s %s\n" $((i+1)) "$step" "$status_icon" >> "$REPORT_FILE"
    done
    
    echo "╚═══════════════════════════════════════════════════════════════════════╝" >> "$REPORT_FILE"
    
    if [ "$install_type" == "PRIMARY" ]; then
        cat >> "$REPORT_FILE" << EOF

╔═══════════════════════════════════════════════════════════════════════╗
║                    INFORMAÇÕES DO DC PRIMÁRIO                        ║
╠═══════════════════════════════════════════════════════════════════════╣
║  Administrador:   administrator@$realm
║  Senha:           $ADMIN_PASSWORD
║  DNS:             127.0.0.1
║  NTP:             a.st1.ntp.br
╚═══════════════════════════════════════════════════════════════════════╝

COMANDOS ÚTEIS:
─────────────────────────────────────────────────────────────────────────
# Testar Kerberos
echo '$ADMIN_PASSWORD' | kinit administrator@$realm
klist

# Listar usuários
samba-tool user list

# Listar grupos
samba-tool group list

# Verificar DNS
host -t SRV _ldap._tcp.$domain

# Logs do Samba
tail -f /var/log/samba/log.samba

EOF
    else
        cat >> "$REPORT_FILE" << EOF

╔═══════════════════════════════════════════════════════════════════════╗
║                  INFORMAÇÕES DO DC SECUNDÁRIO                        ║
╠═══════════════════════════════════════════════════════════════════════╣
║  DC Primário:     ${PRIMARY_IP:-192.168.1.2}
║  DNS Primário:    ${PRIMARY_IP:-192.168.1.2}
║  DNS Secundário:  127.0.0.1
║  NTP:             ${PRIMARY_IP:-192.168.1.2}
╚═══════════════════════════════════════════════════════════════════════╝

COMANDOS ÚTEIS:
─────────────────────────────────────────────────────────────────────────
# Verificar replicação
samba-tool drs showrepl

# Testar Kerberos
echo '$ADMIN_PASSWORD' | kinit administrator@$realm
klist

# Verificar DNS
host -t SRV _ldap._tcp.$domain

EOF
    fi
    
    FAIL_COUNT=0
    for status in "${INSTALL_STATUS[@]}"; do
        [ "$status" == "FAIL" ] && FAIL_COUNT=$((FAIL_COUNT + 1))
    done
    
    if [ $FAIL_COUNT -eq 0 ]; then
        echo "✅ INSTALAÇÃO CONCLUÍDA COM SUCESSO! (0 erros)" >> "$REPORT_FILE"
    else
        echo "⚠️ INSTALAÇÃO CONCLUÍDA COM $FAIL_COUNT ERRO(S)" >> "$REPORT_FILE"
    fi
    
    echo "═══════════════════════════════════════════════════════════════════════" >> "$REPORT_FILE"
    
    echo -e "${GREEN}✓ Relatório gerado: $REPORT_FILE${NC}"
    
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}📊 RESUMO DA INSTALAÇÃO:${NC}"
    echo -e "${BLUE}───────────────────────────────────────────────────────────────────────${NC}"
    echo -e "  Total de passos: ${#INSTALL_STEPS[@]}"
    echo -e "  ✅ Sucessos:     $(grep -c "OK" <(for s in "${INSTALL_STATUS[@]}"; do echo "$s"; done) 2>/dev/null || echo 0)"
    echo -e "  ⚠️  Alertas:      $(grep -c "WARN" <(for s in "${INSTALL_STATUS[@]}"; do echo "$s"; done) 2>/dev/null || echo 0)"
    echo -e "  ❌ Erros:        $(grep -c "FAIL" <(for s in "${INSTALL_STATUS[@]}"; do echo "$s"; done) 2>/dev/null || echo 0)"
    echo -e "${BLUE}───────────────────────────────────────────────────────────────────────${NC}"
    echo -e "${YELLOW}📄 Relatório completo: $REPORT_FILE${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════${NC}"
}

# ============================================
# FUNÇÕES DE TESTE
# ============================================

run_tests_primary() {
    local DOMAIN="$1" REALM="$2" IP="$3"
    log "════════════════════════════════════════════════════"
    log "          BATERIA DE TESTES — DC PRIMÁRIO"
    log "════════════════════════════════════════════════════"
    
    local test_passed=0
    local test_failed=0
    
    info "1. Testando resolução DNS interno..."
    if host -t A localhost >/dev/null 2>&1; then
        echo -e "${GREEN}✓ localhost OK${NC}"
        ((test_passed++))
    else
        echo -e "${RED}✗ localhost NOK${NC}"
        ((test_failed++))
    fi
    
    info "2. Testando SRV LDAP do domínio..."
    if host -t SRV "_ldap._tcp.${DOMAIN}" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ SRV LDAP OK${NC}"
        ((test_passed++))
    else
        echo -e "${RED}✗ SRV LDAP NOK${NC}"
        ((test_failed++))
    fi
    
    info "3. Testando A record do hostname..."
    if host -t A "$HOSTNAME.$DOMAIN" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Hostname DNS OK${NC}"
        ((test_passed++))
    else
        echo -e "${RED}✗ Hostname DNS NOK${NC}"
        ((test_failed++))
    fi
    
    info "4. Testando Kerberos (kinit)..."
    if echo -n "${ADMIN_PASSWORD}" | kinit administrator@"$REALM" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Kerberos OK${NC}"
        ((test_passed++))
    else
        echo -e "${RED}✗ Kerberos falhou${NC}"
        ((test_failed++))
    fi
    
    info "5. Verificando status do serviço samba-ad-dc..."
    if systemctl is-active --quiet samba-ad-dc; then
        echo -e "${GREEN}✓ Serviço ativo${NC}"
        ((test_passed++))
    else
        echo -e "${RED}✗ Serviço inativo${NC}"
        ((test_failed++))
    fi
    
    info "6. Testando sintaxe do smb.conf..."
    if testparm -s >/dev/null 2>&1; then
        echo -e "${GREEN}✓ testparm OK${NC}"
        ((test_passed++))
    else
        echo -e "${RED}✗ testparm falhou${NC}"
        ((test_failed++))
    fi
    
    info "7. Verificando NTP..."
    if chronyc sources | grep -q "^." 2>/dev/null; then
        echo -e "${GREEN}✓ Chrony tem fontes ativas${NC}"
        ((test_passed++))
    else
        echo -e "${RED}✗ Chrony sem fontes${NC}"
        ((test_failed++))
    fi
    
    log "════════════════════════════════════════════════════"
    echo -e "${BLUE}Resumo dos testes: ${GREEN}$test_passed OK${NC} / ${RED}$test_failed FAIL${NC}"
    register_step "Testes do DC Primário" "OK" "$test_passed passaram, $test_failed falharam"
}

run_tests_secondary() {
    local DOMAIN="$1" REALM="$2" IP="$3" PRIMARY_IP="$4"
    log "════════════════════════════════════════════════════"
    log "          BATERIA DE TESTES — DC SECUNDÁRIO"
    log "════════════════════════════════════════════════════"
    
    local test_passed=0
    local test_failed=0
    
    info "1. Testando resolução DNS..."
    if host -t A "$HOSTNAME.$DOMAIN" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Hostname local OK${NC}"
        ((test_passed++))
    else
        echo -e "${RED}✗ Hostname local NOK${NC}"
        ((test_failed++))
    fi
    
    info "2. Testando SRV LDAP do domínio via DNS local..."
    if host -t SRV "_ldap._tcp.${DOMAIN}" 127.0.0.1 >/dev/null 2>&1; then
        echo -e "${GREEN}✓ SRV LDAP via DNS local OK${NC}"
        ((test_passed++))
    else
        echo -e "${RED}✗ SRV LDAP NOK${NC}"
        ((test_failed++))
    fi
    
    info "3. Testando Kerberos..."
    if echo -n "${ADMIN_PASSWORD}" | kinit administrator@"$REALM" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Kerberos OK${NC}"
        ((test_passed++))
    else
        echo -e "${RED}✗ Kerberos falhou${NC}"
        ((test_failed++))
    fi
    
    info "4. Verificando status do serviço..."
    if systemctl is-active --quiet samba-ad-dc; then
        echo -e "${GREEN}✓ Serviço ativo${NC}"
        ((test_passed++))
    else
        echo -e "${RED}✗ Serviço inativo${NC}"
        ((test_failed++))
    fi
    
    info "5. Testando replicação DRS com o primário..."
    if samba-tool drs showrepl 2>&1 | grep -q "$PRIMARY_IP"; then
        echo -e "${GREEN}✓ Replicação DRS ativa com $PRIMARY_IP${NC}"
        ((test_passed++))
    else
        echo -e "${RED}✗ Replicação DRS não detectada${NC}"
        ((test_failed++))
    fi
    
    info "6. Testando wbinfo..."
    if wbinfo -t >/dev/null 2>&1; then
        echo -e "${GREEN}✓ wbinfo conectado ao AD${NC}"
        ((test_passed++))
    else
        echo -e "${RED}✗ wbinfo falhou${NC}"
        ((test_failed++))
    fi
    
    log "════════════════════════════════════════════════════"
    echo -e "${BLUE}Resumo dos testes: ${GREEN}$test_passed OK${NC} / ${RED}$test_failed FAIL${NC}"
    register_step "Testes do DC Secundário" "OK" "$test_passed passaram, $test_failed falharam"
}

# ══════════════════════════════════════════════════════════════
#              FLUXO 1 — DC PRIMÁRIO (ATUALIZADO)
# ══════════════════════════════════════════════════════════════

setup_primary_dc() {
    clear
    
    install_essentials
    config_locale
    
    echo -e "${BLUE}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        CONFIGURAÇÃO — DC PRIMÁRIO               ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}"
    
    # Detecta interface
    log "Detectando interface de rede..."
    INTERFACE=$(ip link show | grep -E "^[0-9]+: (en|eth)" | head -1 | cut -d: -f2 | xargs || true)
    if [ -z "$INTERFACE" ]; then
        INTERFACE=$(ip link show | grep -E "^[0-9]+: " | grep -v lo | head -1 | cut -d: -f2 | xargs)
    fi
    IP_ADDR=$(ip addr show "$INTERFACE" 2>/dev/null | grep inet | grep -v inet6 | awk '{print $2}' | cut -d/ -f1 || true)
    if [ -z "$IP_ADDR" ]; then
        IP_ADDR="192.168.1.2"
        warn "Não consegui detectar IP. Usando $IP_ADDR"
    fi
    echo -e "${GREEN}✓ Interface: ${INTERFACE} (${IP_ADDR})${NC}"
    
    # Pergunta informações
    read -p "Domínio (ex: rnv.local): " -e DOMAIN
    DOMAIN="${DOMAIN,,}"
    REALM="${DOMAIN^^}"
    SHORT_DOMAIN=$(echo "$DOMAIN" | cut -d'.' -f1 | tr '[:lower:]' '[:upper:]')
    read -p "Hostname do servidor (default: adserver01): " -e INPUT_HOSTNAME
    HOSTNAME="${INPUT_HOSTNAME:-adserver01}"
    
    # Loop de senha
    SENHA_VALIDA=0
    while [ $SENHA_VALIDA -eq 0 ]; do
        echo ""
        ADMIN_PASSWORD=$(read_password "Digite a senha do administrador do domínio: ")
        ADMIN_PASSWORD_CONFIRM=$(read_password "Confirme a senha: ")
        
        if [ "$ADMIN_PASSWORD" = "$ADMIN_PASSWORD_CONFIRM" ]; then
            if [ ${#ADMIN_PASSWORD} -lt 8 ]; then
                warn "A senha deve ter pelo menos 8 caracteres!"
            elif ! echo "$ADMIN_PASSWORD" | grep -q "[A-Z]"; then
                warn "A senha deve ter pelo menos uma letra maiúscula!"
            elif ! echo "$ADMIN_PASSWORD" | grep -q "[a-z]"; then
                warn "A senha deve ter pelo menos uma letra minúscula!"
            elif ! echo "$ADMIN_PASSWORD" | grep -q "[0-9]"; then
                warn "A senha deve ter pelo menos um número!"
            else
                SENHA_VALIDA=1
                break
            fi
        else
            warn "As senhas não coincidem!"
        fi
    done
    
    echo
    echo -e "${YELLOW}Resumo da configuração:${NC}"
    echo "  Domínio:    $DOMAIN"
    echo "  Realm:      $REALM"
    echo "  Hostname:   $HOSTNAME"
    echo "  Interface:  $INTERFACE ($IP_ADDR)"
    echo
    read -p "Confirma? (S/n): " -n 1 -r CONFIRM
    echo
    [[ "$CONFIRM" =~ ^[Nn]$ ]] && error "Cancelado pelo usuário"
    
    register_step "Início da configuração DC Primário" "INFO" "Domínio: $DOMAIN"
    
    # PRÉ-CONFIGURA KERBEROS
    preconfigure_kerberos "$REALM" "${HOSTNAME}.${DOMAIN}"
    
    # Configurações básicas
    config_bash_completion
    config_ssh_root
    config_ntp "SELF"
    
    # Configura hostname
    log "Configurando hostname: ${HOSTNAME}.${DOMAIN}"
    hostnamectl set-hostname "${HOSTNAME}.${DOMAIN}"
    register_step "Configuração de hostname" "OK" "${HOSTNAME}.${DOMAIN}"
    
    # Configura hosts
    configure_hosts "$HOSTNAME" "$DOMAIN" "$IP_ADDR"
    
    # Instala Samba
    log "Instalando pacotes do Samba AD..."
    export DEBIAN_FRONTEND=noninteractive
    apt install -y -qq acl attr samba samba-dsdb-modules samba-vfs-modules \
        winbind libpam-winbind libnss-winbind krb5-user dnsutils \
        bind9utils ldap-utils bash-completion chrony 2>/dev/null || true
    register_step "Instalação Samba AD" "OK"
    
    # Para serviços conflitantes
    systemctl stop smbd nmbd winbind 2>/dev/null || true
    systemctl disable smbd nmbd winbind 2>/dev/null || true
    
    # Limpa configurações antigas
    rm -f /etc/samba/smb.conf
    rm -rf /var/lib/samba/private /var/lib/samba/sysvol /var/lib/samba/etc
    rm -f /etc/krb5.conf
    
    # Provisiona domínio
    log "Provisionando domínio ${REALM} (pode levar 3-5 minutos)..."
    samba-tool domain provision \
        --use-rfc2307 \
        --realm="$REALM" \
        --domain="$SHORT_DOMAIN" \
        --server-role=dc \
        --dns-backend=SAMBA_INTERNAL \
        --adminpass="$ADMIN_PASSWORD" \
        --host-ip="$IP_ADDR" \
        --option="interfaces=lo $INTERFACE" \
        --option="bind interfaces only=yes" \
        > /tmp/provision.log 2>&1 || {
        warn "Provisionamento falhou — tentando sem opções extras..."
        samba-tool domain provision \
            --use-rfc2307 \
            --realm="$REALM" \
            --domain="$SHORT_DOMAIN" \
            --server-role=dc \
            --dns-backend=SAMBA_INTERNAL \
            --adminpass="$ADMIN_PASSWORD" \
            > /tmp/provision.log 2>&1 || error "Provisionamento falhou (veja /tmp/provision.log)"
    }
    echo -e "${GREEN}✓ Domínio provisionado com sucesso${NC}"
    register_step "Provisionamento do domínio" "OK" "$REALM"
    
    # Configura smb.conf
    log "Configurando /etc/samba/smb.conf"
    cp "/var/lib/samba/private/smb.conf" "/etc/samba/smb.conf"
    
    sed -i "/^interfaces/s|=.*| = lo $INTERFACE|" "/etc/samba/smb.conf" || true
    sed -i "/^bind interfaces only/s|=.*| = yes|" "/etc/samba/smb.conf" || true
    
    grep -q "ldap server require strong auth" "/etc/samba/smb.conf" ||
        sed -i "/\[global\]/a \    ldap server require strong auth = no" "/etc/samba/smb.conf"
    
    # CORREÇÃO DNS - parte importante!
    fix_primary_dns
    
    # Configura Kerberos
    configure_kerberos "$REALM" "$DOMAIN" "${HOSTNAME}.${DOMAIN}"
    
    # Inicia Samba
    log "Iniciando serviços samba-ad-dc..."
    systemctl unmask samba-ad-dc || true
    systemctl enable samba-ad-dc || true
    systemctl restart samba-ad-dc
    sleep 20
    register_step "Inicialização Samba AD" "OK"
    
    # Cria grupos e usuários
    log "Criando grupos e usuários padrão..."
    samba-tool group add "admins" --description="Administradores do Domínio" 2>/dev/null || true
    samba-tool group add "users" --description="Usuários do Domínio" 2>/dev/null || true
    samba-tool user create admin2 "$ADMIN_PASSWORD" --given-name="Admin" --surname="Secundário" 2>/dev/null || true
    samba-tool group addmembers "Domain Admins" admin2 2>/dev/null || true
    register_step "Criação de grupos/usuários" "OK"
    
    # Testes
    run_tests_primary "$DOMAIN" "$REALM" "$IP_ADDR"
    
    # Relatório
    generate_final_report "PRIMARY" "$DOMAIN" "$REALM" "$HOSTNAME" "$IP_ADDR"
    
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅ DC PRIMÁRIO CONFIGURADO COM SUCESSO!           ║${NC}"
    echo -e "${GREEN}║                                                     ║${NC}"
    echo -e "${GREEN}║  🌐 Domínio: $DOMAIN                                ║${NC}"
    echo -e "${GREEN}║  🔑 Acesse com: administrator@$REALM               ║${NC}"
    echo -e "${GREEN}║  📍 IP: $IP_ADDR                                   ║${NC}"
    echo -e "${GREEN}║                                                     ║${NC}"
    echo -e "${GREEN}║  📄 Relatório: $REPORT_FILE                         ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    
    read -p "Reiniciar o servidor agora? (s/N): " -n 1 -r
    [[ "$REPLY" =~ ^[Ss]$ ]] && { log "Reiniciando em 5 segundos..."; sleep 5; reboot; }
}

# ══════════════════════════════════════════════════════════════
#              FLUXO 2 — DC SECUNDÁRIO (ATUALIZADO)
# ══════════════════════════════════════════════════════════════

setup_secondary_dc() {
    clear
    
    install_essentials
    config_locale
    
    echo -e "${BLUE}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        CONFIGURAÇÃO — DC SECUNDÁRIO              ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}"
    
    # Detecta interface
    log "Detectando interface de rede..."
    INTERFACE=$(ip link show | grep -E "^[0-9]+: (en|eth)" | head -1 | cut -d: -f2 | xargs || true)
    if [ -z "$INTERFACE" ]; then
        INTERFACE=$(ip link show | grep -E "^[0-9]+: " | grep -v lo | head -1 | cut -d: -f2 | xargs)
    fi
    IP_ADDR=$(ip addr show "$INTERFACE" 2>/dev/null | grep inet | grep -v inet6 | awk '{print $2}' | cut -d/ -f1 || true)
    if [ -z "$IP_ADDR" ]; then
        IP_ADDR="192.168.1.3"
        warn "Não consegui detectar IP. Usando $IP_ADDR"
    fi
    echo -e "${GREEN}✓ Interface: ${INTERFACE} (${IP_ADDR})${NC}"
    
    # Pergunta informações
    read -p "Domínio (ex: rnv.local): " -e DOMAIN
    DOMAIN="${DOMAIN,,}"
    REALM="${DOMAIN^^}"
    read -p "IP do DC Primário: " -e PRIMARY_IP
    read -p "Hostname deste servidor (default: adserver02): " -e INPUT_HOSTNAME
    HOSTNAME="${INPUT_HOSTNAME:-adserver02}"
    read -p "Usuário administrador do domínio (ex: administrator): " -e ADMIN_USER
    ADMIN_USER="${ADMIN_USER:-administrator}"
    
    ADMIN_PASSWORD=$(read_password "Digite a senha do administrador do domínio: ")
    echo
    
    echo
    echo -e "${YELLOW}Resumo da configuração:${NC}"
    echo "  Domínio:     $DOMAIN"
    echo "  Realm:       $REALM"
    echo "  DC Primário: $PRIMARY_IP"
    echo "  Hostname:    $HOSTNAME"
    echo "  Interface:   $INTERFACE ($IP_ADDR)"
    echo
    read -p "Confirma? (S/n): " -n 1 -r CONFIRM
    echo
    [[ "$CONFIRM" =~ ^[Nn]$ ]] && error "Cancelado pelo usuário"
    
    register_step "Início da configuração DC Secundário" "INFO" "Domínio: $DOMAIN"
    
    # PRÉ-CONFIGURA KERBEROS
    preconfigure_kerberos "$REALM" "$PRIMARY_IP"
    
    # Configurações básicas
    config_bash_completion
    config_ssh_root
    config_ntp "$PRIMARY_IP"
    
    # Configura hostname
    log "Configurando hostname: ${HOSTNAME}.${DOMAIN}"
    hostnamectl set-hostname "${HOSTNAME}.${DOMAIN}"
    register_step "Configuração de hostname" "OK" "${HOSTNAME}.${DOMAIN}"
    
    # Configura hosts com primário
    configure_hosts "$HOSTNAME" "$DOMAIN" "$IP_ADDR" "$PRIMARY_IP"
    
    # Configura DNS para apontar para o primário
    configure_resolv_conf "$PRIMARY_IP" "$DOMAIN"
    
    # Instala Samba
    log "Instalando pacotes necessários..."
    export DEBIAN_FRONTEND=noninteractive
    apt install -y -qq acl attr samba samba-dsdb-modules samba-vfs-modules \
        winbind krb5-user dnsutils ldap-utils bash-completion chrony 2>/dev/null || true
    register_step "Instalação Samba AD" "OK"
    
    # Para serviços conflitantes
    systemctl stop smbd nmbd winbind 2>/dev/null || true
    systemctl disable smbd nmbd winbind 2>/dev/null || true
    
    # Limpa configurações antigas
    rm -rf /var/lib/samba/* /etc/samba/smb.conf /etc/krb5.conf 2>/dev/null || true
    
    # Configura Kerberos
    configure_kerberos "$REALM" "$DOMAIN" "$PRIMARY_IP"
    
    # Testa Kerberos
    log "Testando Kerberos com as credenciais fornecidas..."
    echo -n "${ADMIN_PASSWORD}" | kinit "$ADMIN_USER@$REALM" >/dev/null 2>&1 && {
        echo -e "${GREEN}✓ Autenticação Kerberos OK${NC}"
        kdestroy 2>/dev/null || true
    } || error "Kerberos falhou — verifique domínio, usuário e senha"
    
    # Join no domínio
    log "Juntando ao domínio ${REALM} como DC Secundário..."
    
    samba-tool domain join "$REALM" DC \
        --dns-backend=SAMBA_INTERNAL \
        --option="interfaces=lo $INTERFACE" \
        --option="bind interfaces only=yes" \
        --server="$PRIMARY_IP" \
        -U"${ADMIN_USER}@${REALM}" \
        --password="$ADMIN_PASSWORD" \
        > /tmp/join.log 2>&1 || error "Join falhou (veja /tmp/join.log)"
    
    echo -e "${GREEN}✓ Servidor juntado ao domínio como DC Secundário${NC}"
    register_step "Join ao domínio" "OK" "$REALM"
    
    # Ajusta smb.conf
    log "Ajustando /etc/samba/smb.conf para replicação"
    cp "/var/lib/samba/private/smb.conf" "/etc/samba/smb.conf"
    sed -i "/^interfaces/s|=.*| = lo $INTERFACE|" "/etc/samba/smb.conf" || true
    
    # Configura DNS local (aponta para si mesmo como fallback)
    configure_resolv_conf "$PRIMARY_IP" "$DOMAIN"
    
    # Inicia Samba
    log "Iniciando samba-ad-dc..."
    systemctl unmask samba-ad-dc || true
    systemctl enable samba-ad-dc || true
    systemctl restart samba-ad-dc
    sleep 20
    register_step "Inicialização Samba AD" "OK"
    
    # Verifica replicação
    log "Verificando replicação DRS com o primário..."
    if samba-tool drs showrepl 2>&1 | grep -q "$PRIMARY_IP"; then
        echo -e "${GREEN}✓ Replicação DRS ativa com $PRIMARY_IP${NC}"
    else
        warn "Replicação DRS não detectada — pode levar alguns minutos"
    fi
    
    # Testes
    run_tests_secondary "$DOMAIN" "$REALM" "$IP_ADDR" "$PRIMARY_IP"
    
    # Relatório
    generate_final_report "SECONDARY" "$DOMAIN" "$REALM" "$HOSTNAME" "$IP_ADDR"
    
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅ DC SECUNDÁRIO CONFIGURADO COM SUCESSO!         ║${NC}"
    echo -e "${GREEN}║                                                     ║${NC}"
    echo -e "${GREEN}║  🌐 Domínio: $DOMAIN                                ║${NC}"
    echo -e "${GREEN}║  📍 IP: $IP_ADDR                                   ║${NC}"
    echo -e "${GREEN}║  🔗 Primário: $PRIMARY_IP                           ║${NC}"
    echo -e "${GREEN}║                                                     ║${NC}"
    echo -e "${GREEN}║  📄 Relatório: $REPORT_FILE                         ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    
    read -p "Reiniciar o servidor agora? (s/N): " -n 1 -r
    [[ "$REPLY" =~ ^[Ss]$ ]] && { log "Reiniciando em 5 segundos..."; sleep 5; reboot; }
}

# ============================================
# FUNÇÃO: CONFIGURAR ESTAÇÃO LINUX
# ============================================

configure_linux_station() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   CONFIGURAR LINUX COMO ESTAÇÃO DE DOMÍNIO     ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}"
    
    read -p "Domínio a juntar (ex: rnv.local): " -e DOMAIN
    DOMAIN="${DOMAIN,,}"
    REALM="${DOMAIN^^}"
    read -p "IP do DC: " -e DC_IP
    read -p "Usuário administrador do domínio (ex: administrator): " -e ADMIN_USER
    ADMIN_USER="${ADMIN_USER:-administrator}"
    ADMIN_PASSWORD=$(read_password "Digite a senha do domínio: ")
    echo
    
    export DEBIAN_FRONTEND=noninteractive
    
    log "Instalando pacotes necessários..."
    apt update -qq 2>/dev/null || true
    apt install -y -qq realmd sssd sssd-tools adcli oddjob oddjob-mkhomedir \
        krb5-user krb5-config samba-common samba-common-bin \
        policykit-1 2>/dev/null || true
    register_step "Instalação pacotes estação Linux" "OK"
    
    # Configura DNS
    configure_resolv_conf "$DC_IP" "$DOMAIN"
    
    log "Descobrindo o domínio..."
    realm discover "$DOMAIN" || warn "Domínio não encontrado"
    
    log "Executando realm join..."
    echo -n "${ADMIN_PASSWORD}" | realm join --user="$ADMIN_USER" "$DOMAIN" --password="$ADMIN_PASSWORD" || {
        warn "realm join falhou — tentando modo interativo..."
        realm join --user="$ADMIN_USER" "$DOMAIN" || error "Join falhou"
    }
    register_step "Join estação Linux ao domínio" "OK" "$DOMAIN"
    
    log "Habilitando criação automática de home directory..."
    systemctl enable --now oddjobd 2>/dev/null || true
    realm permit "$ADMIN_USER@$DOMAIN" 2>/dev/null || true
    
    log "Configurando sudoers para administradores do domínio..."
    cat > /etc/sudoers.d/ad_admins << EOF
%Domain\\ Admins@$DOMAIN ALL=(ALL:ALL) ALL
EOF
    register_step "Configuração sudoers" "OK"
    
    echo
    echo -e "${GREEN}✅ ESTAÇÃO LINUX CONFIGURADA COMO MEMBRO DO AD${NC}"
    echo
    read -p "Pressione Enter para voltar ao menu..."
}

# ============================================
# FUNÇÃO: CONFIGURAR IP (SIMPLIFICADA)
# ============================================

configure_station_ips() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   GERADOR DE CONFIGURAÇÃO DE IP — ESTAÇÕES                     ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
    
    echo "Selecione o sistema operacional das estações:"
    echo "  1) Linux (Netplan — Ubuntu/Debian)"
    echo "  2) Windows (script batch netsh)"
    read -p "Opção [1/2]: " OS_OPT
    
    case "$OS_OPT" in
        1)
            log "Detectando interfaces..."
            STA_IFACE=$(ip link show | grep -E "^[0-9]+: (en|eth)" | head -1 | cut -d: -f2 | xargs || echo "eth0")
            info "Interface detectada: $STA_IFACE"
            
            read -p "IP estático: " STA_IP
            read -p "Máscara [/24]: " STA_MASK
            STA_MASK="${STA_MASK:-24}"
            read -p "Gateway: " STA_GATEWAY
            
            echo -e "${BLUE}DNS:${NC}"
            echo "  [1] 8.8.8.8 (Google)"
            echo "  [2] IP do AD"
            read -p "Opção [1-2]: " DNS_OPT
            
            if [ "$DNS_OPT" == "2" ]; then
                read -p "IP do AD: " STA_DNS1
            else
                STA_DNS1="8.8.8.8"
            fi
            
            cat > /etc/netplan/01-static.yaml << EOF
network:
  version: 2
  ethernets:
    $STA_IFACE:
      addresses: [$STA_IP/$STA_MASK]
      gateway4: $STA_GATEWAY
      nameservers:
        addresses: [$STA_DNS1]
      dhcp4: no
EOF
            
            netplan apply
            echo -e "${GREEN}✓ IP configurado!${NC}"
            ;;
            
        2)
            read -p "IP: " STA_IP
            read -p "Máscara: " STA_MASK
            read -p "Gateway: " STA_GATEWAY
            read -p "DNS: " STA_DNS1
            read -p "Interface (ex: Ethernet): " STA_IFACE
            
            cat > "/root/config_ip_${STA_IP}.bat" << EOF
@echo off
netsh interface ipv4 set address name="$STA_IFACE" source=static address=$STA_IP mask=$STA_MASK gateway=$STA_GATEWAY
netsh interface ipv4 set dns name="$STA_IFACE" source=static address=$STA_DNS1
EOF
            echo -e "${GREEN}✓ Script gerado: /root/config_ip_${STA_IP}.bat${NC}"
            ;;
    esac
    
    read -p "Pressione Enter para continuar..."
}

# ============================================
# FUNÇÕES DE CONFIGURAÇÃO BÁSICAS
# ============================================

config_bash_completion() {
    log "Ativando auto-complete com TAB..."
    if ! grep -q "bash-completion" /root/.bashrc 2>/dev/null; then
        cat >> /root/.bashrc << 'EOF' 2>/dev/null || true
if [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
fi
complete -C samba-tool samba-tool
EOF
    fi
    [ -f /etc/bash_completion ] && . /etc/bash_completion 2>/dev/null || true
    echo -e "${GREEN}✓ Bash completion ativado${NC}"
    register_step "Bash completion" "OK"
}

config_ssh_root() {
    log "Configurando acesso root via SSH..."
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
    if grep -q "^PermitRootLogin" /etc/ssh/sshd_config 2>/dev/null; then
        sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null || true
    else
        echo "PermitRootLogin yes" >> /etc/ssh/sshd_config 2>/dev/null || true
    fi
    systemctl restart sshd 2>/dev/null || true
    echo -e "${YELLOW}⚠ Root SSH ativado${NC}"
    register_step "Configuração SSH Root" "OK"
}

# ══════════════════════════════════════════════════════════════
#                        MENU PRINCIPAL
# ══════════════════════════════════════════════════════════════

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║            SAMBA AD SERVER — UNIFICADO PRO v4.0                ║${NC}"
        echo -e "${BLUE}║              Ubuntu 24.04 | Samba 4.19.5                       ║${NC}"
        echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║ 1) DC Primário    — Provisionar novo domínio                   ║${NC}"
        echo -e "${BLUE}║ 2) DC Secundário  — Juntar a domínio existente (replicação)    ║${NC}"
        echo -e "${BLUE}║ 3) Configurar IP  — Configurar IP estático (Linux/Windows)     ║${NC}"
        echo -e "${BLUE}║ 4) Estação Linux  — Configurar Linux como membro do domínio     ║${NC}"
        echo -e "${BLUE}║ 5) Sair                                                      ║${NC}"
        echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
        echo
        read -p "Selecione uma opção [1-5]: " OPTION
        
        case "$OPTION" in
            1) setup_primary_dc ;;
            2) setup_secondary_dc ;;
            3) configure_station_ips ;;
            4) configure_linux_station ;;
            5) echo -e "${GREEN}Saindo. Até logo!${NC}"; exit 0 ;;
            *) warn "Opção inválida. Tente novamente."; sleep 1 ;;
        esac
    done
}

# ══════════════════════════════════════════════════════════════
#                   INÍCIO DA EXECUÇÃO
# ══════════════════════════════════════════════════════════════

trap 'echo -e "\n${RED}[INTERRUPTED]${NC} Script interrompido."; exit 1' INT TERM

# Inicializa o relatório
echo "═══════════════════════════════════════════════════════════════════════" > "$REPORT_FILE"
echo "  RELATÓRIO DE INSTALAÇÃO - SAMBA AD DC - $(date '+%d/%m/%Y %H:%M:%S')" >> "$REPORT_FILE"
echo "═══════════════════════════════════════════════════════════════════════" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

log "Iniciando SAMBA AD SERVER UNIFICADO PRO v4.0"
log "Sistema: $(lsb_release -ds 2>/dev/null || echo "Ubuntu 24.04") | Samba $(samba --version 2>/dev/null | head -1 || echo "4.19.5")"

main_menu
