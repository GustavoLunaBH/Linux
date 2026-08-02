#!/bin/bash
# ad_controller_setup.sh
# Script completo para instalação do Samba AD - Controlador de Domínio
# Versão: 2.9 - Corrigido: Senha e funções

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
ADMIN_PASSWORD=""          # Será preenchida durante a execução
FIXED_IP=""
FIXED_GATEWAY="192.168.1.1"
INTERFACE=""
DNS_FORWARDER="8.8.8.8"
NTP_SERVER="a.st1.ntp.br"
PRIMARY_DC_IP="192.168.1.2"
PRIMARY_DC_HOSTNAME="adserver01"
SCRIPT_VERSION="2.9"
LOG_FILE="/tmp/ad_setup_$(date +%Y%m%d_%H%M%S).log"
INSTALLATION_TYPE=""
HOSTNAME=""
NETWORK_CONFIGURED=false
NETPLAN_FILE=""
OS_INFO=""
KERNEL_VERSION=""

# ============================================
# FUNÇÕES PRINCIPAIS
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

# ============================================
# DETECÇÃO DE SISTEMA - FUNÇÕES REUTILIZÁVEIS
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
    if [ -f "/etc/netplan/50-cloud-init.yaml" ]; then
        NETPLAN_FILE="/etc/netplan/50-cloud-init.yaml"
    elif [ -f "/etc/netplan/01-netcfg.yaml" ]; then
        NETPLAN_FILE="/etc/netplan/01-netcfg.yaml"
    elif [ -f "/etc/netplan/00-installer-config.yaml" ]; then
        NETPLAN_FILE="/etc/netplan/00-installer-config.yaml"
    else
        local existing_file=$(ls /etc/netplan/*.yaml 2>/dev/null | head -1)
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

# ============================================
# FUNÇÃO UNIFICADA PARA CRIAR/ATUALIZAR NETPLAN
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
    
    log "Atualizando netplan no arquivo: ${NETPLAN_FILE}"
    
    if [ -f "${NETPLAN_FILE}" ]; then
        cp "${NETPLAN_FILE}" "${NETPLAN_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
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
    
    for file in /etc/netplan/*.yaml; do
        if [ "$file" != "${NETPLAN_FILE}" ] && [ -f "$file" ]; then
            mv "$file" "$file.disabled.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        fi
    done
    
    success "Arquivo ${NETPLAN_FILE} atualizado"
}

apply_netplan() {
    log "Aplicando configurações de rede..."
    
    if netplan try --timeout 5 2>/dev/null; then
        success "Netplan configurado com sucesso!"
    else
        warning "Falha ao aplicar netplan, tentando force..."
        netplan apply 2>/dev/null
    fi
    
    systemctl restart systemd-networkd 2>/dev/null
    systemctl restart systemd-resolved 2>/dev/null
    
    ip addr flush dev ${INTERFACE} 2>/dev/null
    netplan apply 2>/dev/null
    sleep 3
    
    local new_ip=$(ip -4 addr show ${INTERFACE} 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    if [ -n "$new_ip" ]; then
        success "Nova configuração aplicada: ${new_ip}"
        FIXED_IP="$new_ip"
        NETWORK_CONFIGURED=true
        return 0
    else
        error "Falha ao aplicar configuração de rede"
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
# AUTO DETECT
# ============================================

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
# MENU DE CONFIGURAÇÃO DE REDE
# ============================================

configure_network() {
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
    echo -e "${GREEN} 5)${NC} ${BOLD}Aplicar e Reiniciar Rede${NC}"
    echo -e "     ${CYAN}➜${NC} Aplica configurações e reinicia rede"
    echo ""
    echo -e "${GREEN} 6)${NC} ${BOLD}Voltar ao Menu Principal${NC}"
    echo ""
    echo -e "${WHITE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    while true; do
        read -p "👉 Escolha uma opção [1-6]: " choice
        case $choice in
            1) configure_fixed_ip; break ;;
            2) configure_dns_settings; break ;;
            3) show_network_status; break ;;
            4) test_connectivity; break ;;
            5) apply_netplan; break ;;
            6) return 0 ;;
            *) echo -e "${RED}Opção inválida! Tente novamente.${NC}" ;;
        esac
    done
    
    configure_network
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
    
    read -p "Deseja aplicar esta configuração? (S/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        info "Configuração cancelada"
        return
    fi
    
    update_netplan "${FIXED_IP}" "${NETMASK_INPUT}" "${FIXED_GATEWAY}"
    
    success "Configuração salva. Use a Opção 5 para aplicar e reiniciar a rede."
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
    
    read -p "Deseja aplicar esta configuração? (S/n): " -n 1 -r
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
    
    read -p "Pressione ENTER para continuar..."
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
    
    read -p "Pressione ENTER para continuar..."
}

# ============================================
# FUNÇÃO PARA COLETAR CONFIGURAÇÕES
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
    if [ -z "$HOSTNAME" ]; then
        HOSTNAME="$DEFAULT_HOSTNAME"
    fi
    HOSTNAME=$(echo $HOSTNAME | tr '[:upper:]' '[:lower:]')
    
    echo -e "${BLUE}Digite o DNS forwarder [${DNS_FORWARDER}]:${NC}"
    read -p "> " DNS_FORWARDER
    if [ -z "$DNS_FORWARDER" ]; then
        DNS_FORWARDER="8.8.8.8"
    fi
    
    if [ "$INSTALLATION_TYPE" == "secondary" ]; then
        echo ""
        echo -e "${YELLOW}📌 Configurações do DC Primário:${NC}"
        echo -e "${BLUE}Digite o IP do primário [${PRIMARY_DC_IP}]:${NC}"
        read -p "> " PRIMARY_IP_INPUT
        if [ -n "$PRIMARY_IP_INPUT" ]; then
            PRIMARY_DC_IP="$PRIMARY_IP_INPUT"
        fi
        
        echo -e "${BLUE}Digite o hostname do primário [${PRIMARY_DC_HOSTNAME}]:${NC}"
        read -p "> " PRIMARY_HOST_INPUT
        if [ -n "$PRIMARY_HOST_INPUT" ]; then
            PRIMARY_DC_HOSTNAME="$PRIMARY_HOST_INPUT"
        fi
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
# REPLICAÇÃO - FUNÇÕES (MANTIDAS DA VERSÃO ANTERIOR)
# ============================================

# [Aqui manter todas as funções de replicação da versão anterior]
# check_replication_status, force_replication, replicate_from_specific_dc,
# check_replication_differences, check_dns_on_dcs, check_users_on_dcs,
# setup_auto_replication, replication_menu

# ============================================
# FUNÇÕES DE INSTALAÇÃO
# ============================================

fix_system_dns() {
    log "Configurando DNS do sistema..."
    
    chattr -i /etc/resolv.conf 2>/dev/null || true
    chattr -i /etc/resolvconf/resolv.conf.d/head 2>/dev/null || true
    
    mkdir -p /etc/resolvconf/resolv.conf.d 2>/dev/null
    
    local dns_primary="${FIXED_IP}"
    if [ "$INSTALLATION_TYPE" == "secondary" ]; then
        dns_primary="${PRIMARY_DC_IP}"
    fi
    
    cat > /etc/resolv.conf << EOF
nameserver ${dns_primary}
nameserver 127.0.0.1
nameserver 8.8.8.8
nameserver 1.1.1.1
search ${DOMAIN,,}
domain ${DOMAIN,,}
EOF
    
    cat > /etc/resolvconf/resolv.conf.d/head << EOF
nameserver ${dns_primary}
nameserver 127.0.0.1
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
    
    if ping -c 1 8.8.8.8 &> /dev/null; then
        success "DNS configurado e funcionando"
    else
        warning "DNS configurado, mas teste falhou"
    fi
}

configure_locale() {
    log "Configurando locale pt_BR..."
    locale-gen pt_BR.UTF-8 >>"$LOG_FILE" 2>&1
    update-locale LANG=pt_BR.UTF-8 LANGUAGE=pt_BR:pt LC_ALL=pt_BR.UTF-8 >>"$LOG_FILE" 2>&1
    export LANG=pt_BR.UTF-8
    export LANGUAGE=pt_BR:pt
    export LC_ALL=pt_BR.UTF-8
    timedatectl set-timezone America/Sao_Paulo 2>>"$LOG_FILE"
    success "Locale e timezone configurados"
}

configure_ntp() {
    log "Configurando NTP..."
    
    local ntp_servers="${NTP_SERVER}"
    if [ "$INSTALLATION_TYPE" == "secondary" ]; then
        ntp_servers="${PRIMARY_DC_IP} ${NTP_SERVER}"
    fi
    
    cat > /etc/chrony/chrony.conf << EOF
server ${ntp_servers} iburst
server 0.pool.ntp.org iburst
server 1.pool.ntp.org iburst
server 2.pool.ntp.org iburst
driftfile /var/lib/chrony/chrony.drift
logdir /var/log/chrony
makestep 1 3
allow 127.0.0.1
allow 192.168.1.0/24
EOF
    
    systemctl enable chrony >>"$LOG_FILE" 2>&1
    systemctl restart chrony >>"$LOG_FILE" 2>&1
    success "NTP configurado"
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

    if [ "$INSTALLATION_TYPE" == "secondary" ]; then
        cat >> /etc/hosts << EOF
${PRIMARY_DC_IP} ${PRIMARY_DC_HOSTNAME}.${DOMAIN,,} ${PRIMARY_DC_HOSTNAME}
EOF
    fi
    
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
        language-pack-pt locales \
        chrony \
        curl wget htop \
        traceroute mtr nmap tcpdump \
        sshpass ntpdate \
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
    
    if [ $? -eq 0 ]; then
        success "Domínio provisionado com sucesso!"
    else
        error "Falha no provisionamento. Verifique o log: $LOG_FILE"
    fi
}

configure_samba_primary() {
    log "Configurando samba.conf..."
    
    if [ ! -f "/etc/samba/smb.conf" ]; then
        if [ -f "/var/lib/samba/private/smb.conf" ]; then
            cp /var/lib/samba/private/smb.conf /etc/samba/smb.conf
        fi
    fi
    
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
    
    if [ $? -eq 0 ]; then
        success "Serviço samba-ad-dc iniciado"
    else
        error "Falha ao iniciar samba-ad-dc"
    fi
    
    log "Aguardando serviços iniciarem..."
    sleep 10
    
    log "Testando Kerberos..."
    if echo "${ADMIN_PASSWORD}" | kinit ${ADMIN_USER}@${DOMAIN} 2>/dev/null; then
        success "Kerberos funcionando"
        klist
    else
        warning "Kerberos com problemas - tentando novamente..."
        sleep 5
        if echo "${ADMIN_PASSWORD}" | kinit ${ADMIN_USER}@${DOMAIN} 2>/dev/null; then
            success "Kerberos funcionando (segunda tentativa)"
        else
            warning "Kerberos ainda com problemas"
        fi
    fi
    
    log "Testando DNS..."
    if host ${DOMAIN,,} 127.0.0.1 &> /dev/null; then
        success "DNS do domínio funcionando"
    else
        warning "DNS do domínio com problemas"
    fi
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

# ============================================
# INSTALAÇÃO SECUNDÁRIA
# ============================================

remove_dhcp() {
    header "REMOVENDO DHCP E CONFIGURANDO IP FIXO"
    
    stop_dhcp_services
    detect_netplan_file
    
    update_netplan "${FIXED_IP}" "24" "${FIXED_GATEWAY}" "${PRIMARY_DC_IP}" "8.8.8.8" "${DOMAIN,,}"
    apply_netplan
}

configure_dns_secondary() {
    header "CONFIGURANDO DNS"
    
    log "Configurando /etc/resolv.conf..."
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf
    
    cat > /etc/resolv.conf << EOF
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
    
    success "DNS e hosts configurados"
}

sync_time() {
    header "SINCRONIZANDO HORA"
    
    log "Sincronizando com o primário..."
    apt install -y ntpdate 2>/dev/null || true
    
    if ntpdate -u ${PRIMARY_DC_IP} 2>/dev/null; then
        success "Hora sincronizada com o primário"
    else
        ntpdate -u pool.ntp.br 2>/dev/null || true
        info "Hora sincronizada via internet"
    fi
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
        kdc = ${PRIMARY_DC_HOSTNAME}.${DOMAIN,,}
        admin_server = ${PRIMARY_DC_HOSTNAME}.${DOMAIN,,}
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
    else
        error "Primário não acessível - verifique o IP ${PRIMARY_DC_IP}"
    fi
    
    for porta in 445 389 88 53; do
        if nc -zv ${PRIMARY_DC_IP} $porta 2>/dev/null; then
            success "Porta $porta acessível"
        fi
    done
}

test_kerberos_secondary() {
    header "TESTANDO KERBEROS"
    
    log "Autenticando com o primário..."
    kdestroy 2>/dev/null || true
    
    if echo "${ADMIN_PASSWORD}" | kinit ${ADMIN_USER}@${DOMAIN} 2>/dev/null; then
        success "Autenticação Kerberos OK"
        klist 2>/dev/null
    else
        error "Falha na autenticação Kerberos"
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
    
    log "Tentando método alternativo..."
    samba-tool domain join ${DOMAIN,,} DC \
        --server=${PRIMARY_DC_IP} \
        --password=${ADMIN_PASSWORD} \
        --option="interfaces=lo ${INTERFACE}" \
        --option="bind interfaces only=yes" \
        >>"$LOG_FILE" 2>&1
    
    if [ $? -eq 0 ]; then
        success "Join realizado com sucesso!"
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
        cat >> /etc/samba/smb.conf << 'EOF'
    log level = 2
    max log size = 10000
    debug timestamp = yes
    domain master = no
    local master = no
    preferred master = no
    os level = 0
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
    fi
}

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
nameserver 192.168.1.2
nameserver 127.0.0.1
nameserver 8.8.8.8
nameserver 1.1.1.1
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
LOG: ${LOG_FILE}
EOF
    
    chmod 600 /root/ad_info.txt
    success "Informações salvas em /root/ad_info.txt"
}

# ============================================
# FUNÇÃO COMUM DE SETUP
# ============================================

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
    echo -e "     ${CYAN}➜${NC} DC adicional para redundância"
    echo ""
    echo -e "${GREEN} 4)${NC} ${BOLD}GERENCIAR REPLICAÇÃO AD${NC}"
    echo -e "     ${CYAN}➜${NC} Forçar sincronização entre DCs"
    echo ""
    echo -e "${RED} 5)${NC} ${BOLD}SAIR${NC}"
    echo ""
    echo -e "${WHITE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

get_installation_type() {
    while true; do
        read -p "👉 Escolha uma opção [1-5]: " choice
        case $choice in
            1)
                configure_network
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
                # Chamar menu de replicação
                echo -e "${YELLOW}Função de replicação será implementada...${NC}"
                return 0
                ;;
            5)
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
# FUNÇÃO DE FINALIZAÇÃO
# ============================================

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
# FUNÇÃO PRINCIPAL DE INSTALAÇÃO
# ============================================

install_primary() {
    log "Iniciando instalação do CONTROLADOR PRIMÁRIO"
    
    common_setup
    provision_domain
    configure_samba_primary
    configure_kerberos_primary
    test_primary_services
    final_tests_primary
    create_fix_dns_script
    save_info
}

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
    verify_secondary
    create_fix_dns_script
    save_info
}

# ============================================
# INÍCIO DO SCRIPT - MAIN
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
