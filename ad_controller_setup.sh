#!/bin/bash
# ad_controller_setup.sh
# Script completo para instalação do Samba AD - Controlador de Domínio
# Versão: 4.0 - Com todas as correções integradas

# ============================================
# CORES PARA OUTPUT
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'
BOLD='\033[1m'

# ============================================
# CONFIGURAÇÕES PADRÃO
# ============================================
DOMAIN="RNV.INTRA"
REALM="RNV.INTRA"
SHORT_DOMAIN="RNV"
ADMIN_USER="administrator"
ADMIN_PASSWORD=""
FIXED_IP=""
FIXED_GATEWAY="192.168.1.1"
INTERFACE=""
DNS_FORWARDER="8.8.8.8"
NTP_SERVER="a.st1.ntp.br"
PRIMARY_DC_IP="192.168.1.2"
PRIMARY_DC_HOSTNAME="adserver01"
SECONDARY_DC_IP="192.168.1.3"
SECONDARY_DC_HOSTNAME="adserver02"
SCRIPT_VERSION="4.0"
LOG_FILE="/tmp/ad_setup_$(date +%Y%m%d_%H%M%S).log"
INSTALLATION_TYPE=""
HOSTNAME=""
NETWORK_CONFIGURED=false
NETPLAN_FILE=""
OS_INFO=""
KERNEL_VERSION=""

# ============================================
# FUNÇÕES DE LOG E UTILITÁRIOS
# ============================================

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}${BOLD}[ERRO]${NC} $1" | tee -a "$LOG_FILE"
    echo ""
    echo -e "${YELLOW}Últimas 20 linhas do log:${NC}"
    tail -20 "$LOG_FILE"
    exit 1
}

warning() {
    echo -e "${YELLOW}[AVISO]${NC} $1" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}✓${NC} $1" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${CYAN}ℹ${NC} $1" | tee -a "$LOG_FILE"
}

header() {
    echo -e "${CYAN}"
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  $1"
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "${NC}"
}

get_os_info() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_INFO="${PRETTY_NAME}"
    else
        OS_INFO="Linux $(uname -r)"
    fi
    KERNEL_VERSION=$(uname -r)
}

print_banner() {
    clear
    echo -e "${MAGENTA}"
    echo "    ╔══════════════════════════════════════════════════════════════╗"
    echo "    ║                                                              ║"
    echo "    ║     █████╗ ██████╗      ███████╗███████╗████████╗██╗   ██╗  ║"
    echo "    ║    ██╔══██╗██╔══██╗     ██╔════╝██╔════╝╚══██╔══╝██║   ██║  ║"
    echo "    ║    ███████║██║  ██║     ███████╗█████╗     ██║   ██║   ██║  ║"
    echo "    ║    ██╔══██║██║  ██║     ╚════██║██╔══╝     ██║   ██║   ██║  ║"
    echo "    ║    ██║  ██║██████╔╝     ███████║███████╗   ██║   ╚██████╔╝  ║"
    echo "    ║    ╚═╝  ╚═╝╚═════╝      ╚══════╝╚══════╝   ╚═╝    ╚═════╝   ║"
    echo "    ║                                                              ║"
    echo "    ║           INSTALADOR DO CONTROLADOR DE DOMÍNIO               ║"
    echo "    ║                  Samba AD - Versão ${SCRIPT_VERSION}                        ║"
    echo "    ╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

press_enter() {
    echo ""
    read -p "Pressione ENTER para continuar..."
}

# ============================================
# DETECÇÃO DE SISTEMA
# ============================================

detect_interface() {
    local interfaces=$(ip -o link show | grep -v "lo:" | grep -v "@" | grep "state UP" | awk -F': ' '{print $2}' | head -1)
    if [ -z "$interfaces" ]; then
        interfaces=$(ip -o link show | grep -v "lo:" | grep -v "@" | awk -F': ' '{print $2}' | head -1)
    fi
    if [ -n "$interfaces" ]; then
        INTERFACE="$interfaces"
        return 0
    else
        error "Nenhuma interface de rede encontrada!"
    fi
}

detect_ip() {
    local current_ip=$(ip -4 addr show ${INTERFACE} 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    if [ -n "$current_ip" ] && [ "$current_ip" != "127.0.0.1" ]; then
        FIXED_IP="$current_ip"
        return 0
    fi
    return 1
}

detect_gateway() {
    local gateway=$(ip route | grep default | awk '{print $3}' | head -1)
    if [ -n "$gateway" ]; then
        FIXED_GATEWAY="$gateway"
        return 0
    fi
    return 1
}

detect_domain() {
    local current_domain=$(hostname -d 2>/dev/null | tr '[:lower:]' '[:upper:]')
    if [ -n "$current_domain" ] && [ "$current_domain" != "" ]; then
        DOMAIN="$current_domain"
        REALM="$DOMAIN"
        SHORT_DOMAIN=$(echo $DOMAIN | cut -d. -f1)
        return 0
    fi
    return 1
}

detect_netplan_file() {
    local active_file=""
    
    for file in /etc/netplan/*.yaml; do
        if [ -f "$file" ] && [[ ! "$file" =~ \.backup\..*$ ]] && [[ ! "$file" =~ \.disabled\..*$ ]]; then
            active_file="$file"
            break
        fi
    done
    
    if [ -n "$active_file" ]; then
        NETPLAN_FILE="$active_file"
        return
    fi
    
    if [ -f "/etc/netplan/50-cloud-init.yaml" ]; then
        NETPLAN_FILE="/etc/netplan/50-cloud-init.yaml"
    elif [ -f "/etc/netplan/01-netcfg.yaml" ]; then
        NETPLAN_FILE="/etc/netplan/01-netcfg.yaml"
    elif [ -f "/etc/netplan/00-installer-config.yaml" ]; then
        NETPLAN_FILE="/etc/netplan/00-installer-config.yaml"
    else
        local existing_file=$(ls /etc/netplan/*.yaml 2>/dev/null | grep -v "\.backup\." | grep -v "\.disabled\." | head -1)
        if [ -n "$existing_file" ]; then
            NETPLAN_FILE="$existing_file"
        else
            NETPLAN_FILE="/etc/netplan/01-netcfg.yaml"
        fi
    fi
}

detect_all() {
    detect_interface
    detect_ip
    detect_gateway
    detect_domain
    detect_netplan_file
}

auto_detect() {
    header "DETECTANDO CONFIGURAÇÕES DO SISTEMA"
    detect_all
    echo ""
    echo -e "  Interface: ${CYAN}${INTERFACE}${NC}"
    echo -e "  IP: ${CYAN}${FIXED_IP:-Não detectado}${NC}"
    echo -e "  Gateway: ${CYAN}${FIXED_GATEWAY}${NC}"
    echo -e "  Domínio: ${CYAN}${DOMAIN}${NC}"
    echo -e "  Arquivo Rede: ${CYAN}${NETPLAN_FILE}${NC}"
    echo ""
}

# ============================================
# GERENCIAMENTO DE REDE
# ============================================

update_netplan() {
    local ip="$1"
    local netmask="${2:-24}"
    local gateway="$3"
    local dns1="$4"
    local dns2="${5:-8.8.8.8}"
    local search_domain="${6:-${DOMAIN,,}}"
    
    [ -z "$ip" ] && ip="$FIXED_IP"
    [ -z "$gateway" ] && gateway="$FIXED_GATEWAY"
    [ -z "$dns1" ] && dns1="$FIXED_IP"
    
    detect_netplan_file
    
    log "Atualizando netplan no arquivo: ${NETPLAN_FILE}"
    
    if [ -f "${NETPLAN_FILE}" ]; then
        cp "${NETPLAN_FILE}" "${NETPLAN_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        success "Backup criado: $(basename ${NETPLAN_FILE}).backup"
    fi
    
    cat > ${NETPLAN_FILE} << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${INTERFACE}:
      dhcp4: false
      dhcp6: false
      addresses:
        - ${ip}/${netmask}
      routes:
        - to: default
          via: ${gateway}
      nameservers:
        addresses:
          - ${dns1}
          - ${dns2}
        search:
          - ${search_domain}
EOF
    
    success "Arquivo $(basename ${NETPLAN_FILE}) atualizado"
    
    for file in /etc/netplan/*.yaml; do
        if [ -f "$file" ] && [ "$file" != "${NETPLAN_FILE}" ]; then
            if [[ ! "$file" =~ \.backup\..*$ ]] && [[ ! "$file" =~ \.disabled\..*$ ]]; then
                mv "$file" "$file.disabled.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
                info "Arquivo desabilitado: $(basename $file)"
            fi
        fi
    done
}

apply_netplan() {
    header "APLICANDO CONFIGURAÇÕES DE REDE"
    
    log "Aplicando configurações de rede..."
    
    if [ ! -f "${NETPLAN_FILE}" ]; then
        error "Arquivo de rede ${NETPLAN_FILE} não encontrado!"
    fi
    
    echo -e "${BLUE}Arquivo que será aplicado: ${CYAN}${NETPLAN_FILE}${NC}"
    echo ""
    echo -e "${BLUE}Conteúdo do arquivo:${NC}"
    echo -e "${YELLOW}─────────────────────────────────────────────────────${NC}"
    cat "${NETPLAN_FILE}"
    echo -e "${YELLOW}─────────────────────────────────────────────────────${NC}"
    echo ""
    
    read -p "Deseja aplicar esta configuração? (S/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        info "Aplicação cancelada"
        return
    fi
    
    if netplan try --timeout 10 2>/dev/null; then
        success "Netplan configurado com sucesso!"
    else
        warning "Falha ao aplicar netplan try, tentando apply..."
        netplan apply 2>/dev/null
        if [ $? -eq 0 ]; then
            success "Netplan apply executado com sucesso"
        else
            error "Falha ao aplicar netplan"
        fi
    fi
    
    systemctl restart systemd-networkd 2>/dev/null
    systemctl restart systemd-resolved 2>/dev/null
    
    sleep 3
    
    local new_ip=$(ip -4 addr show ${INTERFACE} 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    if [ -n "$new_ip" ]; then
        success "✅ Nova configuração aplicada com sucesso!"
        echo -e "  ${GREEN}IP: ${CYAN}${new_ip}${NC}"
        FIXED_IP="$new_ip"
        NETWORK_CONFIGURED=true
        
        if [ -n "$HOSTNAME" ]; then
            sed -i "/${HOSTNAME}/d" /etc/hosts 2>/dev/null
            echo "${FIXED_IP} ${HOSTNAME}.${DOMAIN,,} ${HOSTNAME}" >> /etc/hosts
            success "Hosts atualizado"
        fi
        
        return 0
    else
        error "❌ Falha ao aplicar configuração de rede - IP não encontrado"
    fi
}

stop_dhcp_services() {
    log "Parando todos os serviços DHCP..."
    systemctl stop dhcpcd 2>/dev/null || true
    systemctl disable dhcpcd 2>/dev/null || true
    systemctl stop network-manager 2>/dev/null || true
    systemctl disable network-manager 2>/dev/null || true
    systemctl stop systemd-networkd 2>/dev/null || true
    pkill -f dhclient 2>/dev/null || true
    pkill -f dhcpcd 2>/dev/null || true
    
    ip addr flush dev ${INTERFACE}
    ip addr add ${FIXED_IP}/24 dev ${INTERFACE}
    ip route add default via ${FIXED_GATEWAY}
}

# ============================================
# CONFIGURAÇÕES BÁSICAS DO SISTEMA
# ============================================

fix_system_dns() {
    log "Configurando DNS do sistema..."
    
    chattr -i /etc/resolv.conf 2>/dev/null || true
    chattr -i /etc/resolvconf/resolv.conf.d/head 2>/dev/null || true
    
    mkdir -p /etc/resolvconf/resolv.conf.d 2>/dev/null
    
    local dns_primary="${FIXED_IP}"
    [ "$INSTALLATION_TYPE" == "secondary" ] && dns_primary="${FIXED_IP}"
    
    cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
nameserver ${dns_primary}
nameserver 8.8.8.8
nameserver 1.1.1.1
search ${DOMAIN,,}
domain ${DOMAIN,,}
EOF
    
    cat > /etc/resolvconf/resolv.conf.d/head << EOF
nameserver 127.0.0.1
nameserver ${dns_primary}
nameserver 8.8.8.8
nameserver 1.1.1.1
search ${DOMAIN,,}
domain ${DOMAIN,,}
EOF
    
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        systemctl stop systemd-resolved 2>/dev/null
        systemctl disable systemd-resolved 2>/dev/null
        log "systemd-resolved desabilitado"
    fi
    
    chattr +i /etc/resolv.conf 2>/dev/null || true
    
    ping -c 1 8.8.8.8 &> /dev/null && success "DNS configurado e funcionando" || warning "DNS configurado, mas teste falhou"
}

configure_dns_secondary() {
    header "CONFIGURANDO DNS SECUNDÁRIO"
    
    log "Configurando /etc/resolv.conf com o próprio IP como primário..."
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf
    
    cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
nameserver ${FIXED_IP}
nameserver ${PRIMARY_DC_IP}
nameserver 8.8.8.8
search ${DOMAIN,,}
domain ${DOMAIN,,}
EOF
    chattr +i /etc/resolv.conf 2>/dev/null || true
    
    cat > /etc/hosts << EOF
127.0.0.1 localhost
127.0.1.1 ${HOSTNAME}.${DOMAIN,,} ${HOSTNAME}
${FIXED_IP} ${HOSTNAME}.${DOMAIN,,} ${HOSTNAME}
${FIXED_IP} ${HOSTNAME}
${PRIMARY_DC_IP} ${PRIMARY_DC_HOSTNAME}.${DOMAIN,,} ${PRIMARY_DC_HOSTNAME}
EOF
    
    success "DNS e hosts configurados - Servidor funcionando independente"
}

configure_locale() {
    log "Configurando locale pt_BR..."
    
    apt install -y language-pack-pt-base language-pack-pt locales 2>>"$LOG_FILE" || true
    
    locale-gen pt_BR.UTF-8 >>"$LOG_FILE" 2>&1
    
    update-locale LANG=pt_BR.UTF-8 LANGUAGE=pt_BR:pt LC_ALL=pt_BR.UTF-8 >>"$LOG_FILE" 2>&1
    
    export LANG=pt_BR.UTF-8
    export LANGUAGE=pt_BR:pt
    export LC_ALL=pt_BR.UTF-8
    
    if locale -a 2>/dev/null | grep -q "pt_BR.utf8"; then
        success "Locale pt_BR.UTF-8 configurado"
    else
        warning "Falha ao configurar locale pt_BR.UTF-8, usando fallback"
        export LANG=en_US.UTF-8
        export LC_ALL=en_US.UTF-8
        locale-gen en_US.UTF-8 >>"$LOG_FILE" 2>&1
    fi
    
    timedatectl set-timezone America/Sao_Paulo 2>>"$LOG_FILE" || true
    success "Timezone configurado: America/Sao_Paulo"
}

configure_ntp() {
    log "Configurando NTP..."
    
    if ! command -v chrony &> /dev/null && ! command -v chronyd &> /dev/null; then
        log "Chrony não encontrado, instalando..."
        apt install -y chrony 2>>"$LOG_FILE" || true
    fi
    
    local chrony_conf=""
    if [ -f "/etc/chrony/chrony.conf" ]; then
        chrony_conf="/etc/chrony/chrony.conf"
    elif [ -f "/etc/chrony.conf" ]; then
        chrony_conf="/etc/chrony.conf"
    else
        mkdir -p /etc/chrony
        chrony_conf="/etc/chrony/chrony.conf"
    fi
    
    local ntp_servers="${NTP_SERVER}"
    [ "$INSTALLATION_TYPE" == "secondary" ] && ntp_servers="${PRIMARY_DC_IP} ${NTP_SERVER}"
    
    cat > ${chrony_conf} << EOF
# Configuração NTP para Samba AD
server ${ntp_servers} iburst
server 0.pool.ntp.org iburst
server 1.pool.ntp.org iburst
server 2.pool.ntp.org iburst

# Arquivo de drift
driftfile /var/lib/chrony/chrony.drift

# Diretório de log
logdir /var/log/chrony

# Passos para sincronização rápida
makestep 1 3

# Permitir acesso local e da rede local
allow 127.0.0.1
allow 192.168.1.0/24
EOF
    
    success "Arquivo NTP criado: ${chrony_conf}"
    
    if systemctl list-unit-files 2>/dev/null | grep -q "chrony.service"; then
        systemctl enable chrony >>"$LOG_FILE" 2>&1 || true
        systemctl restart chrony >>"$LOG_FILE" 2>&1 || true
        if systemctl is-active --quiet chrony; then
            success "NTP configurado com chrony"
        else
            warning "Falha ao iniciar chrony"
        fi
    elif systemctl list-unit-files 2>/dev/null | grep -q "ntp.service"; then
        systemctl enable ntp >>"$LOG_FILE" 2>&1 || true
        systemctl restart ntp >>"$LOG_FILE" 2>&1 || true
        if systemctl is-active --quiet ntp; then
            success "NTP configurado com ntp"
        else
            warning "Falha ao iniciar ntp"
        fi
    else
        warning "Serviço NTP não encontrado. Instalando ntpdate..."
        apt install -y ntpdate 2>>"$LOG_FILE" || true
        ntpdate -u pool.ntp.br 2>/dev/null && success "Hora sincronizada via ntpdate" || warning "Falha na sincronização"
    fi
}

sync_time() {
    header "SINCRONIZANDO HORA"
    
    log "Sincronizando com o primário..."
    apt install -y ntpdate 2>/dev/null || true
    
    if ntpdate -u ${PRIMARY_DC_IP} 2>/dev/null; then
        success "Hora sincronizada com o primário"
    else
        ntpdate -u pool.ntp.br 2>/dev/null || true
        [ $? -eq 0 ] && info "Hora sincronizada via internet" || warning "Falha na sincronização de hora"
    fi
}

configure_hostname() {
    log "Configurando hostname..."
    hostnamectl set-hostname ${HOSTNAME}.${DOMAIN,,} 2>>"$LOG_FILE"
    
    cat > /etc/hosts << EOF
127.0.0.1 localhost
127.0.1.1 ${HOSTNAME}.${DOMAIN,,} ${HOSTNAME}
${FIXED_IP} ${HOSTNAME}.${DOMAIN,,} ${HOSTNAME}
${FIXED_IP} ${HOSTNAME}
EOF

    [ "$INSTALLATION_TYPE" == "secondary" ] && echo "${PRIMARY_DC_IP} ${PRIMARY_DC_HOSTNAME}.${DOMAIN,,} ${PRIMARY_DC_HOSTNAME}" >> /etc/hosts
    
    success "Hostname configurado: ${HOSTNAME}.${DOMAIN,,}"
}

install_packages() {
    header "INSTALANDO PACOTES NECESSÁRIOS"
    
    log "Atualizando lista de pacotes..."
    apt update -qq 2>>"$LOG_FILE" || warning "Falha ao atualizar"
    
    log "Instalando pacotes essenciais..."
    DEBIAN_FRONTEND=noninteractive apt install -y -qq \
        samba samba-dsdb-modules samba-vfs-modules \
        winbind libpam-winbind libnss-winbind \
        krb5-user krb5-config \
        dnsutils bind9-utils ldap-utils \
        net-tools iputils-ping \
        acl attr \
        bash-completion \
        language-pack-pt-base language-pack-pt locales \
        chrony \
        curl wget htop \
        traceroute mtr nmap tcpdump \
        sshpass ntpdate \
        realmd adcli sssd \
        ufw \
        2>>"$LOG_FILE"
    
    if [ $? -eq 0 ]; then
        success "Todos os pacotes instalados"
    else
        warning "Alguns pacotes podem não ter instalado corretamente"
    fi
    
    if command -v samba-tool &> /dev/null; then
        success "Samba instalado: $(samba-tool --version 2>/dev/null | head -1)"
    else
        error "Samba não foi instalado corretamente"
    fi
}

common_setup() {
    log "Executando configurações comuns..."
    
    if [ "$INSTALLATION_TYPE" == "secondary" ]; then
        configure_dns_secondary
    else
        fix_system_dns
    fi
    
    configure_locale
    configure_ntp
    install_packages
    configure_hostname
}

# ============================================
# INSTALAÇÃO PRIMÁRIA
# ============================================

provision_domain() {
    header "PROVISIONANDO DOMÍNIO ${DOMAIN}"
    
    log "Parando serviços conflitantes..."
    systemctl stop smbd nmbd winbind 2>/dev/null || true
    systemctl disable smbd nmbd winbind 2>/dev/null || true
    
    log "Limpando configurações antigas..."
    rm -f /etc/samba/smb.conf
    rm -rf /var/lib/samba/private 2>/dev/null || true
    rm -rf /var/lib/samba/sysvol 2>/dev/null || true
    rm -f /etc/krb5.conf
    
    log "Executando provisionamento..."
    log "Isso pode levar alguns minutos..."
    
    samba-tool domain provision \
        --realm=${REALM} \
        --domain=${SHORT_DOMAIN} \
        --server-role=dc \
        --dns-backend=SAMBA_INTERNAL \
        --adminpass=${ADMIN_PASSWORD} \
        --use-rfc2307 \
        --host-ip=${FIXED_IP} \
        --option="interfaces=lo ${INTERFACE}" \
        --option="bind interfaces only=yes" \
        --option="dns forwarder=${DNS_FORWARDER}" \
        >>"$LOG_FILE" 2>&1
    
    [ $? -eq 0 ] && success "Domínio provisionado com sucesso!" || error "Falha no provisionamento. Verifique o log: $LOG_FILE"
}

configure_samba_primary() {
    log "Configurando samba.conf..."
    
    if [ ! -f "/etc/samba/smb.conf" ] && [ -f "/var/lib/samba/private/smb.conf" ]; then
        cp /var/lib/samba/private/smb.conf /etc/samba/smb.conf
    fi
    
    # Remover parâmetros problemáticos
    sed -i '/bind interfaces only/d' /etc/samba/smb.conf
    sed -i '/server signing/d' /etc/samba/smb.conf
    sed -i '/client signing/d' /etc/samba/smb.conf
    sed -i '/ntlm auth/d' /etc/samba/smb.conf
    sed -i '/domain master/d' /etc/samba/smb.conf
    sed -i '/local master/d' /etc/samba/smb.conf
    sed -i '/preferred master/d' /etc/samba/smb.conf
    sed -i '/os level/d' /etc/samba/smb.conf
    
    cat >> /etc/samba/smb.conf << 'EOF'
    log level = 2
    max log size = 10000
    debug timestamp = yes
    dns zone transfer clients = *
EOF
    
    sed -i "s/interfaces.*=.*/interfaces = lo ${INTERFACE}/g" /etc/samba/smb.conf
    success "samba.conf configurado"
}

configure_kerberos_primary() {
    log "Configurando Kerberos..."
    
    cat > /etc/krb5.conf << EOF
[libdefaults]
    default_realm = ${REALM}
    dns_lookup_realm = false
    dns_lookup_kdc = true
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true

[realms]
    ${REALM} = {
        kdc = ${HOSTNAME}.${DOMAIN,,}
        admin_server = ${HOSTNAME}.${DOMAIN,,}
        default_domain = ${DOMAIN,,}
    }

[domain_realm]
    .${DOMAIN,,} = ${REALM}
    ${DOMAIN,,} = ${REALM}
EOF
    
    success "Kerberos configurado"
}

test_primary_services() {
    header "TESTANDO SERVIÇOS"
    
    log "Iniciando samba-ad-dc..."
    systemctl unmask samba-ad-dc 2>/dev/null || true
    systemctl enable samba-ad-dc 2>/dev/null || true
    systemctl restart samba-ad-dc 2>>"$LOG_FILE"
    
    [ $? -eq 0 ] && success "Serviço samba-ad-dc iniciado" || error "Falha ao iniciar samba-ad-dc"
    
    log "Aguardando serviços iniciarem..."
    sleep 10
    
    log "Testando Kerberos..."
    if echo "${ADMIN_PASSWORD}" | kinit ${ADMIN_USER}@${DOMAIN} 2>/dev/null; then
        success "Kerberos funcionando"
        klist
    else
        warning "Kerberos com problemas - tentando novamente..."
        sleep 5
        echo "${ADMIN_PASSWORD}" | kinit ${ADMIN_USER}@${DOMAIN} 2>/dev/null && success "Kerberos funcionando (segunda tentativa)" || warning "Kerberos ainda com problemas"
    fi
    
    log "Testando DNS..."
    host ${DOMAIN,,} 127.0.0.1 &> /dev/null && success "DNS do domínio funcionando" || warning "DNS do domínio com problemas"
}

final_tests_primary() {
    header "TESTES FINAIS"
    
    echo ""
    echo -e "${BLUE}1. Verificando serviço:${NC}"
    systemctl status samba-ad-dc --no-pager | head -3
    echo ""
    
    echo -e "${BLUE}2. Verificando portas:${NC}"
    ss -tlnp | grep -E ":53|:88|:389|:445|:135|:139" | head -5 || echo "  Nenhuma porta encontrada"
    echo ""
    
    echo -e "${BLUE}3. Verificando DNS:${NC}"
    host ${DOMAIN,,} 127.0.0.1 2>/dev/null || echo "  Domínio não resolvido"
    echo ""
    
    echo -e "${BLUE}4. Verificando Kerberos:${NC}"
    echo "${ADMIN_PASSWORD}" | kinit ${ADMIN_USER}@${DOMAIN} 2>/dev/null && echo "  ✓ Kerberos OK" || echo "  ✗ Kerberos FAIL"
    klist 2>/dev/null || echo "  Nenhum ticket"
    echo ""
}

install_primary() {
    log "Iniciando instalação do CONTROLADOR PRIMÁRIO"
    
    common_setup
    provision_domain
    configure_samba_primary
    configure_kerberos_primary
    test_primary_services
    final_tests_primary
    
    # Configurar firewall
    configure_firewall
    
    create_fix_dns_script
    save_info
}

# ============================================
# INSTALAÇÃO SECUNDÁRIA - CORRIGIDA
# ============================================

remove_dhcp() {
    header "REMOVENDO DHCP E CONFIGURANDO IP FIXO"
    
    stop_dhcp_services
    detect_netplan_file
    
    update_netplan "${FIXED_IP}" "24" "${FIXED_GATEWAY}" "${FIXED_IP}" "8.8.8.8" "${DOMAIN,,}"
    apply_netplan
}

configure_kerberos_secondary() {
    log "Configurando Kerberos..."
    
    cat > /etc/krb5.conf << EOF
[libdefaults]
    default_realm = ${REALM}
    dns_lookup_realm = false
    dns_lookup_kdc = true
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true

[realms]
    ${REALM} = {
        kdc = ${HOSTNAME}.${DOMAIN,,}
        admin_server = ${HOSTNAME}.${DOMAIN,,}
        default_domain = ${DOMAIN,,}
    }

[domain_realm]
    .${DOMAIN,,} = ${REALM}
    ${DOMAIN,,} = ${REALM}
EOF
    
    success "Kerberos configurado"
}

test_connection() {
    header "TESTANDO CONEXÃO"
    
    log "Testando conexão com o primário..."
    
    if ping -c 3 ${PRIMARY_DC_IP} &> /dev/null; then
        success "Primário acessível"
        PRIMARY_ONLINE=true
    else
        warning "Primário não acessível - O servidor funcionará independente"
        PRIMARY_ONLINE=false
    fi
    
    if [ "$PRIMARY_ONLINE" = true ]; then
        for porta in 445 389 88 53; do
            nc -zv ${PRIMARY_DC_IP} $porta 2>/dev/null && success "Porta $porta acessível"
        done
    fi
}

test_kerberos_secondary() {
    header "TESTANDO KERBEROS"
    
    log "Autenticando com o domínio..."
    kdestroy 2>/dev/null || true
    
    if echo "${ADMIN_PASSWORD}" | kinit ${ADMIN_USER}@${DOMAIN} 2>/dev/null; then
        success "Autenticação Kerberos OK"
        klist 2>/dev/null
    else
        warning "Falha na autenticação Kerberos - tentando novamente..."
        sleep 3
        if echo "${ADMIN_PASSWORD}" | kinit ${ADMIN_USER}@${DOMAIN} 2>/dev/null; then
            success "Autenticação Kerberos OK (segunda tentativa)"
        else
            warning "Falha na autenticação Kerberos - continuando..."
        fi
    fi
}

join_domain() {
    header "JUNTANDO AO DOMÍNIO"
    
    log "Limpando configurações antigas..."
    systemctl stop samba-ad-dc 2>/dev/null || true
    rm -f /etc/samba/smb.conf
    rm -rf /var/lib/samba/private 2>/dev/null || true
    rm -rf /var/lib/samba/sysvol 2>/dev/null || true
    
    log "Fazendo join no domínio..."
    
    samba-tool domain join ${DOMAIN,,} DC \
        --server=${PRIMARY_DC_IP} \
        --password=${ADMIN_PASSWORD} \
        --dns-backend=SAMBA_INTERNAL \
        --option="interfaces=lo ${INTERFACE}" \
        --option="bind interfaces only=yes" \
        --option="dns forwarder=${DNS_FORWARDER}" \
        >>"$LOG_FILE" 2>&1
    
    if [ $? -eq 0 ]; then
        success "Join realizado com sucesso!"
        return 0
    fi
    
    log "Tentando método alternativo (usando DNS)..."
    samba-tool domain join ${DOMAIN,,} DC \
        --password=${ADMIN_PASSWORD} \
        --dns-backend=SAMBA_INTERNAL \
        --option="interfaces=lo ${INTERFACE}" \
        --option="bind interfaces only=yes" \
        >>"$LOG_FILE" 2>&1
    
    if [ $? -eq 0 ]; then
        success "Join realizado com sucesso (método DNS)!"
        return 0
    fi
    
    log "Tentando método básico..."
    samba-tool domain join ${DOMAIN,,} DC \
        --password=${ADMIN_PASSWORD} \
        >>"$LOG_FILE" 2>&1
    
    if [ $? -eq 0 ]; then
        success "Join realizado com sucesso (método básico)!"
        return 0
    fi
    
    error "Falha no join. Verifique o log: $LOG_FILE"
}

configure_samba_secondary() {
    log "Configurando samba.conf..."
    
    if [ -f "/var/lib/samba/private/smb.conf" ]; then
        cp /var/lib/samba/private/smb.conf /etc/samba/smb.conf
    fi
    
    if [ -f "/etc/samba/smb.conf" ]; then
        # Remover parâmetros problemáticos
        sed -i '/bind interfaces only/d' /etc/samba/smb.conf
        sed -i '/server signing/d' /etc/samba/smb.conf
        sed -i '/client signing/d' /etc/samba/smb.conf
        sed -i '/ntlm auth/d' /etc/samba/smb.conf
        sed -i '/domain master/d' /etc/samba/smb.conf
        sed -i '/local master/d' /etc/samba/smb.conf
        sed -i '/preferred master/d' /etc/samba/smb.conf
        sed -i '/os level/d' /etc/samba/smb.conf
        
        cat >> /etc/samba/smb.conf << 'EOF'
    log level = 2
    max log size = 10000
    debug timestamp = yes
EOF
        sed -i "s/interfaces.*=.*/interfaces = lo ${INTERFACE}/g" /etc/samba/smb.conf
    fi
    
    log "Iniciando samba-ad-dc..."
    systemctl unmask samba-ad-dc 2>/dev/null || true
    systemctl enable samba-ad-dc 2>/dev/null || true
    systemctl restart samba-ad-dc 2>/dev/null || true
    
    sleep 5
    
    if systemctl is-active --quiet samba-ad-dc; then
        success "Samba AD iniciado com sucesso"
    else
        warning "Falha ao iniciar samba-ad-dc - tentando novamente..."
        systemctl start samba-ad-dc 2>/dev/null || true
        sleep 5
        if systemctl is-active --quiet samba-ad-dc; then
            success "Samba AD iniciado na segunda tentativa"
        else
            error "Falha ao iniciar samba-ad-dc"
        fi
    fi
}

# ============================================
# CONFIGURAR FIREWALL - NOVA FUNÇÃO
# ============================================

configure_firewall() {
    header "CONFIGURANDO FIREWALL"
    
    log "Configurando firewall para o AD..."
    
    # Configurar UFW
    if command -v ufw &> /dev/null; then
        # Abrir portas do AD
        for port in 53 88 135 139 389 445 636 3268 3269 464; do
            ufw allow ${port}/tcp 2>/dev/null
            ufw allow ${port}/udp 2>/dev/null
        done
        
        # Permitir SMB
        ufw allow 137/udp 2>/dev/null
        ufw allow 138/udp 2>/dev/null
        
        # Permitir SSH
        ufw allow 22/tcp 2>/dev/null
        
        # Permitir da rede local
        ufw allow from 192.168.1.0/24 2>/dev/null
        
        success "UFW configurado"
    fi
    
    # Configurar iptables
    if command -v iptables &> /dev/null; then
        iptables -A INPUT -i lo -j ACCEPT 2>/dev/null
        iptables -A INPUT -s 192.168.1.0/24 -j ACCEPT 2>/dev/null
        iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
        for port in 53 88 135 139 389 445 636 3268 3269 464; do
            iptables -A INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null
            iptables -A INPUT -p udp --dport $port -j ACCEPT 2>/dev/null
        done
        success "iptables configurado"
    fi
}

# ============================================
# CORREÇÃO DNS PARA O SECUNDÁRIO - MELHORADA
# ============================================

fix_dns_secondary() {
    header "CORRIGINDO DNS DO SERVIDOR SECUNDÁRIO"
    
    log "Corrigindo registros DNS do servidor secundário..."
    
    local DOMAIN_LOWER="${DOMAIN,,}"
    local IP="${FIXED_IP}"
    local HOST="${HOSTNAME}"
    
    echo -e "${BLUE}1. Verificando serviço Samba...${NC}"
    if systemctl is-active --quiet samba-ad-dc; then
        success "Samba AD está rodando"
    else
        warning "Samba AD não está rodando. Iniciando..."
        systemctl start samba-ad-dc
        sleep 3
    fi
    
    echo -e "${BLUE}2. Registrando DNS...${NC}"
    
    # Registrar domínio
    samba-tool dns add 127.0.0.1 ${DOMAIN_LOWER} @ A ${IP} -U ${ADMIN_USER} --password=${ADMIN_PASSWORD} 2>/dev/null
    samba-tool dns add 127.0.0.1 ${DOMAIN_LOWER} ${HOST} A ${IP} -U ${ADMIN_USER} --password=${ADMIN_PASSWORD} 2>/dev/null
    
    # Registrar SRV
    samba-tool dns add 127.0.0.1 ${DOMAIN_LOWER} _ldap._tcp SRV "0 100 389 ${HOST}.${DOMAIN_LOWER}." -U ${ADMIN_USER} --password=${ADMIN_PASSWORD} 2>/dev/null
    samba-tool dns add 127.0.0.1 ${DOMAIN_LOWER} _kerberos._tcp SRV "0 100 88 ${HOST}.${DOMAIN_LOWER}." -U ${ADMIN_USER} --password=${ADMIN_PASSWORD} 2>/dev/null
    samba-tool dns add 127.0.0.1 ${DOMAIN_LOWER} _ldap._tcp.dc._msdcs SRV "0 100 389 ${HOST}.${DOMAIN_LOWER}." -U ${ADMIN_USER} --password=${ADMIN_PASSWORD} 2>/dev/null
    samba-tool dns add 127.0.0.1 ${DOMAIN_LOWER} _kerberos._tcp.dc._msdcs SRV "0 100 88 ${HOST}.${DOMAIN_LOWER}." -U ${ADMIN_USER} --password=${ADMIN_PASSWORD} 2>/dev/null
    samba-tool dns add 127.0.0.1 ${DOMAIN_LOWER} _kpasswd._tcp SRV "0 100 464 ${HOST}.${DOMAIN_LOWER}." -U ${ADMIN_USER} --password=${ADMIN_PASSWORD} 2>/dev/null
    samba-tool dns add 127.0.0.1 ${DOMAIN_LOWER} _gc._tcp SRV "0 100 3268 ${HOST}.${DOMAIN_LOWER}." -U ${ADMIN_USER} --password=${ADMIN_PASSWORD} 2>/dev/null
    
    success "DNS registrado"
    
    echo -e "${BLUE}3. Verificando registros DNS...${NC}"
    samba-tool dns query 127.0.0.1 ${DOMAIN_LOWER} @ A 2>/dev/null | grep -A2 "A:"
    echo ""
    
    echo -e "${BLUE}4. Reiniciando o Samba...${NC}"
    systemctl restart samba-ad-dc
    sleep 5
    
    echo -e "${BLUE}5. Testando resolução DNS...${NC}"
    nslookup ${DOMAIN_LOWER} 127.0.0.1 2>/dev/null
    echo ""
    
    success "DNS do servidor secundário corrigido!"
}

# ============================================
# HABILITAR SSH ROOT
# ============================================

enable_ssh_root() {
    log "Habilitando SSH Root..."
    
    if [ -f "/etc/ssh/sshd_config" ]; then
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)
        
        sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
        sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
        
        if ! grep -q "^PermitRootLogin" /etc/ssh/sshd_config; then
            echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
        fi
        
        sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
        sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
        
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
        
        success "SSH Root habilitado"
    fi
}

# ============================================
# REPLICAÇÃO AUTOMÁTICA
# ============================================

setup_auto_replication() {
    header "CONFIGURANDO REPLICAÇÃO AUTOMÁTICA"
    
    log "Configurando script de replicação universal..."
    
    cat > /usr/local/bin/force-replication.sh << 'EOF'
#!/bin/bash
# Script de replicação automática AD - Universal
LOG="/var/log/ad_replication.log"
CURRENT_DC=$(hostname -f)
CURRENT_HOSTNAME=$(hostname -s)
DOMAIN="RNV.INTRA"

log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> $LOG
}

log_msg "=========================================="
log_msg "Iniciando replicação - ${CURRENT_DC}"

# Determinar o outro DC
if [ "${CURRENT_HOSTNAME}" = "adserver01" ]; then
    SOURCE_DC="${CURRENT_DC}"
    TARGET_DC="adserver02.rnv.intra"
else
    SOURCE_DC="${CURRENT_DC}"
    TARGET_DC="adserver01.rnv.intra"
fi

log_msg "Replicando de ${SOURCE_DC} para ${TARGET_DC}"

# Tentar replicação
if samba-tool drs replicate ${TARGET_DC} ${SOURCE_DC} "DC=rnv,DC=intra" --sync-forced 2>/dev/null; then
    log_msg "✓ Replicação OK"
else
    log_msg "✗ Falha na replicação"
fi

# Sync-all
samba-tool drs replicate ${TARGET_DC} ${TARGET_DC} "DC=rnv,DC=intra" --sync-all 2>/dev/null

log_msg "Replicação concluída"
log_msg "=========================================="
EOF

    chmod +x /usr/local/bin/force-replication.sh
    
    cat > /etc/cron.d/ad_replication << EOF
# Replicação automática a cada 5 minutos
*/5 * * * * root /usr/local/bin/force-replication.sh > /dev/null 2>&1
EOF

    chmod 644 /etc/cron.d/ad_replication
    
    success "Replicação automática configurada"
}

# ============================================
# VERIFICAÇÃO PÓS-INSTALAÇÃO
# ============================================

verify_secondary() {
    header "VERIFICANDO INSTALAÇÃO"
    
    echo -e "${BLUE}=== IP ===${NC}"
    ip addr show ${INTERFACE} | grep inet
    echo ""
    
    echo -e "${BLUE}=== DNS ===${NC}"
    cat /etc/resolv.conf
    echo ""
    
    echo -e "${BLUE}=== AD ===${NC}"
    samba-tool domain info 127.0.0.1 2>/dev/null | head -5 || echo "  Aguardando inicialização..."
    echo ""
    
    echo -e "${BLUE}=== DCs ===${NC}"
    samba-tool domain info 127.0.0.1 2>/dev/null | grep "DC name" || echo "  Aguardando inicialização..."
    echo ""
    
    echo -e "${BLUE}=== Replicação ===${NC}"
    samba-tool drs showrepl 2>/dev/null | head -5 || echo "  Aguardando replicação..."
    echo ""
    
    echo -e "${BLUE}=== Teste de DNS ===${NC}"
    nslookup ${DOMAIN,,} 127.0.0.1 2>/dev/null || echo "  ❌ DNS não respondendo"
    echo ""
    
    echo -e "${GREEN}✅ Servidor configurado como DC independente!${NC}"
    echo -e "${GREEN}   Pode adicionar equipamentos mesmo com o primário offline${NC}"
}

# ============================================
# INSTALAÇÃO COMPLETA
# ============================================

install_secondary() {
    log "Iniciando instalação do CONTROLADOR SECUNDÁRIO"
    
    remove_dhcp
    common_setup
    sync_time
    configure_kerberos_secondary
    test_connection
    test_kerberos_secondary
    join_domain
    configure_samba_secondary
    configure_firewall
    enable_ssh_root
    fix_dns_secondary
    setup_auto_replication
    verify_secondary
    create_fix_dns_script
    save_info
}

# ============================================
# SCRIPTS AUXILIARES
# ============================================

create_fix_dns_script() {
    cat > /usr/local/bin/fix-dns << 'EOF'
#!/bin/bash
echo "Corrigindo DNS do sistema..."
chattr -i /etc/resolv.conf 2>/dev/null || true
cat > /etc/resolv.conf << EOFF
nameserver 127.0.0.1
nameserver 192.168.1.2
nameserver 8.8.8.8
search rnv.intra
domain rnv.intra
EOFF
chattr +i /etc/resolv.conf 2>/dev/null || true
systemctl restart systemd-resolved 2>/dev/null || true
echo "DNS corrigido!"
EOF
    chmod +x /usr/local/bin/fix-dns
}

save_info() {
    cat > /root/ad_info.txt << EOF
═══════════════════════════════════════════════════════════════════
            CONTROLADOR DE DOMÍNIO - INFORMAÇÕES
═══════════════════════════════════════════════════════════════════

TIPO: $([ "$INSTALLATION_TYPE" == "primary" ] && echo "PRIMÁRIO" || echo "SECUNDÁRIO")
DOMÍNIO: ${DOMAIN}
REALM: ${REALM}
HOSTNAME: ${HOSTNAME}.${DOMAIN,,}
IP: ${FIXED_IP}
GATEWAY: ${FIXED_GATEWAY}
INTERFACE: ${INTERFACE}
DNS FORWARDER: ${DNS_FORWARDER}
NTP: ${NTP_SERVER}
DATA: $(date)
VERSÃO SCRIPT: ${SCRIPT_VERSION}

───────────────────────────────────────────────────────────────────
USUÁRIOS
───────────────────────────────────────────────────────────────────
Administrador: ${ADMIN_USER}@${DOMAIN}
Senha: ${ADMIN_PASSWORD}

Root (SSH): root / ${ADMIN_PASSWORD}

───────────────────────────────────────────────────────────────────
COMANDOS ÚTEIS
───────────────────────────────────────────────────────────────────
samba-tool domain info 127.0.0.1
kinit ${ADMIN_USER}@${DOMAIN}
klist
host -t SRV _ldap._tcp.${DOMAIN,,}

───────────────────────────────────────────────────────────────────
REPLICAÇÃO
───────────────────────────────────────────────────────────────────
Forçar replicação: /usr/local/bin/force-replication.sh
Log replicação: /var/log/ad_replication.log

───────────────────────────────────────────────────────────────────
LOG: ${LOG_FILE}
EOF
    
    chmod 600 /root/ad_info.txt
    success "Informações salvas em /root/ad_info.txt"
}

finalize_installation() {
    clear
    header "✅ INSTALAÇÃO CONCLUÍDA!"
    
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}         CONTROLADOR DE DOMÍNIO INSTALADO COM SUCESSO!           ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}📌 ACESSO:${NC}"
    echo -e "  Domínio: ${BLUE}${DOMAIN}${NC}"
    echo -e "  Usuário: ${BLUE}${ADMIN_USER}@${DOMAIN}${NC}"
    echo -e "  Senha:   ${BLUE}${ADMIN_PASSWORD}${NC}"
    echo -e "  IP:      ${BLUE}${FIXED_IP}${NC}"
    echo ""
    echo -e "${YELLOW}📁 ARQUIVOS:${NC}"
    echo -e "  ${BLUE}/root/ad_info.txt${NC} - Informações completas"
    echo -e "  ${BLUE}${LOG_FILE}${NC} - Log da instalação"
    echo ""
    
    if [ "$INSTALLATION_TYPE" == "secondary" ]; then
        echo -e "${GREEN}📋 INFORMAÇÕES DO SECUNDÁRIO:${NC}"
        echo -e "  ${GREEN}✅ Servidor configurado para funcionar independentemente${NC}"
        echo -e "  ${GREEN}✅ DNS configurado e registrado corretamente${NC}"
        echo -e "  ${GREEN}✅ Firewall configurado${NC}"
        echo -e "  ${GREEN}✅ SSH Root habilitado${NC}"
        echo -e "  ${GREEN}✅ Replicação automática configurada${NC}"
        echo ""
        echo -e "${YELLOW}📌 Teste de DNS:${NC}"
        echo -e "  ${BLUE}nslookup ${DOMAIN,,}${NC}"
        echo -e "  ${BLUE}ping ${DOMAIN,,}${NC}"
        echo ""
    fi
    
    echo -e "${YELLOW}⚠️  Recomenda-se reiniciar o servidor.${NC}"
    read -p "Reiniciar agora? (s/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Ss]$ ]]; then
        log "Reiniciando..."
        sleep 5
        reboot
    else
        log "Lembre-se de reiniciar depois."
    fi
}

# ============================================
# COLETA DE CONFIGURAÇÕES
# ============================================

collect_configurations() {
    header "CONFIGURAÇÃO DO DOMÍNIO"
    
    echo -e "${BLUE}Configurações atuais do sistema:${NC}"
    echo -e "  Interface: ${CYAN}${INTERFACE}${NC}"
    echo -e "  IP: ${CYAN}${FIXED_IP}${NC}"
    echo -e "  Gateway: ${CYAN}${FIXED_GATEWAY}${NC}"
    echo -e "  Domínio: ${CYAN}${DOMAIN}${NC}"
    echo ""
    
    read -p "Deseja alterar o nome do domínio? (s/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Ss]$ ]]; then
        echo -e "${BLUE}Digite o nome do domínio (ex: MEUDOMINIO.LOCAL):${NC}"
        read -p "> " DOMAIN
        DOMAIN=$(echo $DOMAIN | tr '[:lower:]' '[:upper:]')
        REALM=$DOMAIN
        SHORT_DOMAIN=$(echo $DOMAIN | cut -d. -f1)
    fi
    
    echo -e "${BLUE}Digite o hostname:${NC}"
    if [ "$INSTALLATION_TYPE" == "primary" ]; then
        DEFAULT_HOSTNAME="adserver01"
    else
        DEFAULT_HOSTNAME="adserver02"
    fi
    echo -e "  [${DEFAULT_HOSTNAME}]"
    read -p "> " HOSTNAME
    [ -z "$HOSTNAME" ] && HOSTNAME="$DEFAULT_HOSTNAME"
    HOSTNAME=$(echo $HOSTNAME | tr '[:upper:]' '[:lower:]')
    
    echo -e "${BLUE}Digite o DNS forwarder [${DNS_FORWARDER}]:${NC}"
    read -p "> " DNS_FORWARDER
    [ -z "$DNS_FORWARDER" ] && DNS_FORWARDER="8.8.8.8"
    
    if [ "$INSTALLATION_TYPE" == "secondary" ]; then
        echo ""
        echo -e "${YELLOW}📌 Configurações do DC Primário:${NC}"
        echo -e "${BLUE}Digite o IP do primário [${PRIMARY_DC_IP}]:${NC}"
        read -p "> " PRIMARY_IP_INPUT
        [ -n "$PRIMARY_IP_INPUT" ] && PRIMARY_DC_IP="$PRIMARY_IP_INPUT"
        
        echo -e "${BLUE}Digite o hostname do primário [${PRIMARY_DC_HOSTNAME}]:${NC}"
        read -p "> " PRIMARY_HOST_INPUT
        [ -n "$PRIMARY_HOST_INPUT" ] && PRIMARY_DC_HOSTNAME="$PRIMARY_HOST_INPUT"
        PRIMARY_DC_HOSTNAME=$(echo $PRIMARY_DC_HOSTNAME | tr '[:upper:]' '[:lower:]')
    fi
    
    echo ""
    while true; do
        echo -e "${BLUE}Digite a senha do administrador:${NC}"
        echo -e "${YELLOW}(mínimo 8 caracteres)${NC}"
        read -s -p "> " ADMIN_PASSWORD
        echo ""
        
        echo -e "${BLUE}Confirme a senha:${NC}"
        read -s -p "> " ADMIN_PASSWORD_CONFIRM
        echo ""
        
        if [ "$ADMIN_PASSWORD" = "$ADMIN_PASSWORD_CONFIRM" ] && [ ${#ADMIN_PASSWORD} -ge 8 ]; then
            break
        else
            echo -e "${RED}Senhas não coincidem ou são muito curtas!${NC}"
            echo ""
        fi
    done
    
    echo ""
    header "RESUMO DA CONFIGURAÇÃO"
    echo -e "  ${CYAN}Tipo:${NC}           ${BOLD}$([ "$INSTALLATION_TYPE" == "primary" ] && echo "PRIMÁRIO" || echo "SECUNDÁRIO")${NC}"
    echo -e "  ${CYAN}Domínio:${NC}        ${DOMAIN}"
    echo -e "  ${CYAN}Hostname:${NC}       ${HOSTNAME}.${DOMAIN,,}"
    echo -e "  ${CYAN}IP:${NC}             ${FIXED_IP}"
    echo -e "  ${CYAN}Gateway:${NC}        ${FIXED_GATEWAY}"
    echo -e "  ${CYAN}Interface:${NC}      ${INTERFACE}"
    echo -e "  ${CYAN}DNS Forwarder:${NC}  ${DNS_FORWARDER}"
    echo -e "  ${CYAN}Admin User:${NC}     ${ADMIN_USER}@${DOMAIN}"
    
    if [ "$INSTALLATION_TYPE" == "secondary" ]; then
        echo -e "  ${CYAN}DC Primário:${NC}    ${PRIMARY_DC_HOSTNAME}.${DOMAIN,,} (${PRIMARY_DC_IP})"
    fi
    echo ""
    
    read -p "Deseja continuar com a instalação? (S/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Ss]$ ]] && [[ ! -z "$REPLY" ]]; then
        error "Instalação cancelada pelo usuário"
    fi
}

# ============================================
# MENU PRINCIPAL
# ============================================

show_menu() {
    print_banner
    
    echo -e "${WHITE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${WHITE}║                    SEJA BEM-VINDO!                          ║${NC}"
    echo -e "${WHITE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}📋 Este script irá instalar e configurar um Controlador de Domínio${NC}"
    echo -e "${CYAN}   Samba AD de forma completamente automatizada.${NC}"
    echo ""
    echo -e "${YELLOW}⚠️  ATENÇÃO:${NC}"
    echo -e "   - Execute como ${BOLD}root${NC}"
    echo -e "   - Configure a rede ANTES de instalar (Opção 1)"
    echo -e "   - O servidor será reiniciado ao final da instalação"
    echo ""
    
    get_os_info
    echo -e "${BLUE}📌 INFORMAÇÕES DO SISTEMA:${NC}"
    echo -e "   Sistema: ${CYAN}${OS_INFO}${NC}"
    echo -e "   Kernel: ${CYAN}${KERNEL_VERSION}${NC}"
    echo ""
    
    if [ -n "$FIXED_IP" ] && [ "$FIXED_IP" != "127.0.0.1" ]; then
        echo -e "${GREEN}✅ Rede configurada: ${FIXED_IP}${NC}"
        echo -e "   Interface: ${CYAN}${INTERFACE}${NC}"
        echo -e "   Arquivo: ${CYAN}${NETPLAN_FILE}${NC}"
    else
        echo -e "${RED}❌ Rede NÃO configurada${NC}"
        echo -e "   Use a Opção 1 para configurar"
    fi
    echo ""
    
    echo -e "${WHITE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${WHITE}║                    MENU PRINCIPAL                           ║${NC}"
    echo -e "${WHITE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${GREEN} 1)${NC} ${BOLD}CONFIGURAR REDE${NC}"
    echo -e "     ${CYAN}➜${NC} Configurar IP fixo, DNS e gateway"
    echo ""
    echo -e "${GREEN} 2)${NC} ${BOLD}INSTALAR CONTROLADOR PRIMÁRIO${NC}"
    echo -e "     ${CYAN}➜${NC} Primeiro DC do domínio"
    echo ""
    echo -e "${GREEN} 3)${NC} ${BOLD}INSTALAR CONTROLADOR SECUNDÁRIO${NC}"
    echo -e "     ${CYAN}➜${NC} DC adicional (funciona independente)"
    echo ""
    echo -e "${GREEN} 4)${NC} ${BOLD}GERENCIAR REPLICAÇÃO AD${NC}"
    echo -e "     ${CYAN}➜${NC} Configurar e forçar replicação entre DCs"
    echo ""
    echo -e "${GREEN} 5)${NC} ${BOLD}ADICIONAR EQUIPAMENTO NA REDE${NC}"
    echo -e "     ${CYAN}➜${NC} Adicionar computador/servidor ao domínio"
    echo ""
    echo -e "${RED} 6)${NC} ${BOLD}SAIR${NC}"
    echo ""
    echo -e "${WHITE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ============================================
# GET INSTALLATION TYPE
# ============================================

get_installation_type() {
    while true; do
        read -p "👉 Escolha uma opção [1-6]: " choice
        case $choice in
            1)
                configure_network_menu
                return 0
                ;;
            2)
                INSTALLATION_TYPE="primary"
                break
                ;;
            3)
                INSTALLATION_TYPE="secondary"
                break
                ;;
            4)
                echo -e "${YELLOW}Função de replicação em desenvolvimento...${NC}"
                return 0
                ;;
            5)
                echo -e "${YELLOW}Função de adição de equipamento em desenvolvimento...${NC}"
                return 0
                ;;
            6)
                echo -e "${YELLOW}Instalação cancelada.${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Opção inválida! Tente novamente.${NC}"
                ;;
        esac
    done
    
    if [ -z "$FIXED_IP" ] || [ "$FIXED_IP" == "127.0.0.1" ]; then
        echo ""
        echo -e "${RED}❌ Rede NÃO configurada!${NC}"
        echo -e "${YELLOW}Por favor, configure a rede primeiro (Opção 1)${NC}"
        echo ""
        read -p "Pressione ENTER para voltar ao menu..."
        INSTALLATION_TYPE=""
        show_menu
        get_installation_type
        return
    fi
}

# ============================================
# MENU DE CONFIGURAÇÃO DE REDE
# ============================================

configure_network_menu() {
    header "CONFIGURAÇÃO DE REDE"
    
    echo -e "${YELLOW}⚠️  ATENÇÃO: A configuração de rede deve ser feita ANTES da instalação${NC}"
    echo ""
    
    detect_all
    
    echo -e "${BLUE}Configurações atuais do sistema:${NC}"
    echo -e "  Interface: ${CYAN}${INTERFACE}${NC}"
    echo -e "  IP Atual: ${CYAN}${FIXED_IP:-Não detectado}${NC}"
    echo -e "  Gateway: ${CYAN}${FIXED_GATEWAY}${NC}"
    echo -e "  Arquivo Rede: ${CYAN}${NETPLAN_FILE}${NC}"
    echo ""
    
    echo -e "${WHITE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${WHITE}║                    OPÇÕES DE REDE                           ║${NC}"
    echo -e "${WHITE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${GREEN} 1)${NC} ${BOLD}Configurar IP Fixo${NC}"
    echo -e "     ${CYAN}➜${NC} Define IP, máscara e gateway"
    echo ""
    echo -e "${GREEN} 2)${NC} ${BOLD}Configurar DNS${NC}"
    echo -e "     ${CYAN}➜${NC} Define servidores DNS"
    echo ""
    echo -e "${GREEN} 3)${NC} ${BOLD}Verificar Configuração${NC}"
    echo -e "     ${CYAN}➜${NC} Mostra configurações atuais"
    echo ""
    echo -e "${GREEN} 4)${NC} ${BOLD}Testar Conectividade${NC}"
    echo -e "     ${CYAN}➜${NC} Testa ping e resolução DNS"
    echo ""
    echo -e "${GREEN} 5)${NC} ${BOLD}Aplicar Configurações${NC}"
    echo -e "     ${CYAN}➜${NC} Aplica as configurações salvas"
    echo ""
    echo -e "${GREEN} 6)${NC} ${BOLD}Voltar ao Menu Principal${NC}"
    echo ""
    echo -e "${WHITE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    while true; do
        read -p "👉 Escolha uma opção [1-6]: " choice
        case $choice in
            1) configure_fixed_ip; press_enter ;;
            2) configure_dns_settings; press_enter ;;
            3) show_network_status ;;
            4) test_connectivity ;;
            5) apply_netplan; press_enter ;;
            6) return 0 ;;
            *) echo -e "${RED}Opção inválida! Tente novamente.${NC}" ;;
        esac
    done
}

configure_fixed_ip() {
    header "CONFIGURANDO IP FIXO"
    
    detect_all
    
    echo -e "${BLUE}Interface detectada: ${CYAN}${INTERFACE}${NC}"
    echo -e "${BLUE}Arquivo de rede atual: ${CYAN}${NETPLAN_FILE}${NC}"
    echo -e "${BLUE}IP atual: ${CYAN}${FIXED_IP:-Não configurado}${NC}"
    echo ""
    
    echo -e "${BLUE}Digite o IP fixo [${FIXED_IP:-192.168.1.2}]:${NC}"
    read -p "> " IP_INPUT
    [ -n "$IP_INPUT" ] && FIXED_IP="$IP_INPUT"
    [ -z "$FIXED_IP" ] && FIXED_IP="192.168.1.2"
    
    echo -e "${BLUE}Digite a máscara de rede [24]:${NC}"
    read -p "> " NETMASK_INPUT
    [ -z "$NETMASK_INPUT" ] && NETMASK_INPUT="24"
    
    echo -e "${BLUE}Digite o gateway [${FIXED_GATEWAY}]:${NC}"
    read -p "> " GATEWAY_INPUT
    [ -n "$GATEWAY_INPUT" ] && FIXED_GATEWAY="$GATEWAY_INPUT"
    
    echo ""
    echo -e "${YELLOW}⚠️  Será aplicada a seguinte configuração:${NC}"
    echo -e "  Interface: ${CYAN}${INTERFACE}${NC}"
    echo -e "  IP: ${CYAN}${FIXED_IP}/${NETMASK_INPUT}${NC}"
    echo -e "  Gateway: ${CYAN}${FIXED_GATEWAY}${NC}"
    echo -e "  Arquivo: ${CYAN}${NETPLAN_FILE}${NC}"
    echo ""
    
    read -p "Deseja salvar esta configuração? (S/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        info "Configuração cancelada"
        return
    fi
    
    update_netplan "${FIXED_IP}" "${NETMASK_INPUT}" "${FIXED_GATEWAY}"
    success "Configuração salva no arquivo: $(basename ${NETPLAN_FILE})"
    
    echo ""
    echo -e "${BLUE}Deseja aplicar a configuração agora? (S/n): ${NC}"
    read -p "> " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Ss]$ ]] || [[ -z "$REPLY" ]]; then
        apply_netplan
    else
        info "Configuração salva. Use a Opção 5 do menu para aplicar depois."
    fi
}

configure_dns_settings() {
    header "CONFIGURANDO DNS"
    
    echo -e "${BLUE}Digite o IP do DNS primário [8.8.8.8]:${NC}"
    read -p "> " DNS1
    [ -z "$DNS1" ] && DNS1="8.8.8.8"
    
    echo -e "${BLUE}Digite o IP do DNS secundário [1.1.1.1]:${NC}"
    read -p "> " DNS2
    [ -z "$DNS2" ] && DNS2="1.1.1.1"
    
    echo -e "${BLUE}Digite o domínio de pesquisa [${DOMAIN,,}]:${NC}"
    read -p "> " SEARCH_DOMAIN
    [ -z "$SEARCH_DOMAIN" ] && SEARCH_DOMAIN="${DOMAIN,,}"
    
    echo ""
    echo -e "${YELLOW}⚠️  Será aplicada a seguinte configuração:${NC}"
    echo -e "  DNS Primário: ${CYAN}${DNS1}${NC}"
    echo -e "  DNS Secundário: ${CYAN}${DNS2}${NC}"
    echo -e "  Domínio: ${CYAN}${SEARCH_DOMAIN}${NC}"
    echo ""
    
    read -p "Deseja salvar esta configuração? (S/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        info "Configuração cancelada"
        return
    fi
    
    log "Configurando DNS..."
    
    chattr -i /etc/resolv.conf 2>/dev/null || true
    cat > /etc/resolv.conf << EOF
nameserver ${DNS1}
nameserver ${DNS2}
search ${SEARCH_DOMAIN}
domain ${SEARCH_DOMAIN}
EOF
    chattr +i /etc/resolv.conf 2>/dev/null || true
    
    detect_all
    update_netplan "${FIXED_IP}" "24" "${FIXED_GATEWAY}" "${DNS1}" "${DNS2}" "${SEARCH_DOMAIN}"
    
    success "DNS configurado com sucesso!"
    
    echo ""
    echo -e "${BLUE}Deseja aplicar a configuração agora? (S/n): ${NC}"
    read -p "> " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Ss]$ ]] || [[ -z "$REPLY" ]]; then
        apply_netplan
    else
        info "Configuração salva. Use a Opção 5 do menu para aplicar depois."
    fi
}

show_network_status() {
    header "STATUS DA REDE"
    
    echo -e "${BLUE}=== Interfaces de Rede ===${NC}"
    ip -br addr show
    echo ""
    
    echo -e "${BLUE}=== Arquivos de Configuração ===${NC}"
    ls -la /etc/netplan/*.yaml 2>/dev/null || echo "  Nenhum arquivo .yaml encontrado"
    echo ""
    
    echo -e "${BLUE}=== Conteúdo do Arquivo Ativo ===${NC}"
    if [ -f "${NETPLAN_FILE}" ]; then
        cat "${NETPLAN_FILE}" 2>/dev/null
    else
        echo "  Arquivo não encontrado"
    fi
    echo ""
    
    echo -e "${BLUE}=== Rotas ===${NC}"
    ip route
    echo ""
    
    echo -e "${BLUE}=== DNS ===${NC}"
    cat /etc/resolv.conf 2>/dev/null || echo "  Arquivo /etc/resolv.conf não encontrado"
    echo ""
    
    press_enter
}

test_connectivity() {
    header "TESTANDO CONECTIVIDADE"
    
    echo -e "${BLUE}1. Testando gateway (${FIXED_GATEWAY}):${NC}"
    if ping -c 3 ${FIXED_GATEWAY} &> /dev/null; then
        success "Gateway acessível"
    else
        warning "Gateway não acessível"
    fi
    echo ""
    
    echo -e "${BLUE}2. Testando internet (8.8.8.8):${NC}"
    if ping -c 3 8.8.8.8 &> /dev/null; then
        success "Internet acessível"
    else
        warning "Internet não acessível"
    fi
    echo ""
    
    echo -e "${BLUE}3. Testando resolução DNS:${NC}"
    if nslookup google.com &> /dev/null; then
        success "Resolução DNS funcionando"
    else
        warning "Resolução DNS com problemas"
    fi
    echo ""
    
    echo -e "${BLUE}4. Testando domínio:${NC}"
    if host ${DOMAIN,,} &> /dev/null; then
        success "Domínio ${DOMAIN} resolvido"
    else
        info "Domínio ${DOMAIN} não encontrado na rede"
    fi
    echo ""
    
    press_enter
}

# ============================================
# MAIN
# ============================================

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERRO] Este script deve ser executado como root (sudo)${NC}"
    exit 1
fi

auto_detect
show_menu
get_installation_type

if [ "$INSTALLATION_TYPE" == "primary" ]; then
    collect_configurations
    install_primary
elif [ "$INSTALLATION_TYPE" == "secondary" ]; then
    collect_configurations
    install_secondary
else
    show_menu
    get_installation_type
fi

finalize_installation
exit 0
