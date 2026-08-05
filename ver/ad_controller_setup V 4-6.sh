#!/bin/bash
# ad_controller_setup.sh
# Script para instalação do Samba AD - Controlador de Domínio
# Versão: 4.6 - Simplificado e Funcional

# ============================================
# CORES
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
# CONFIGURAÇÕES
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
NTP_SERVER="pool.ntp.br"
PRIMARY_DC_IP="192.168.1.2"
PRIMARY_DC_HOSTNAME="adserver01"
SCRIPT_VERSION="4.6"
LOG_FILE="/tmp/ad_setup_$(date +%Y%m%d_%H%M%S).log"
INSTALLATION_TYPE=""
HOSTNAME=""
NETPLAN_FILE=""

# ============================================
# FUNÇÕES BÁSICAS
# ============================================

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERRO]${NC} $1" | tee -a "$LOG_FILE"
    tail -20 "$LOG_FILE"
    exit 1
}

success() {
    echo -e "${GREEN}✓${NC} $1" | tee -a "$LOG_FILE"
}

warning() {
    echo -e "${YELLOW}[AVISO]${NC} $1" | tee -a "$LOG_FILE"
}

header() {
    echo -e "${CYAN}"
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  $1"
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "${NC}"
}

press_enter() {
    echo ""
    read -p "Pressione ENTER para continuar..."
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
# DETECÇÃO DE SISTEMA
# ============================================

detect_interface() {
    INTERFACE=$(ip -o link show | grep -v "lo:" | grep "state UP" | awk -F': ' '{print $2}' | head -1)
    [ -z "$INTERFACE" ] && INTERFACE="ens33"
}

detect_ip() {
    FIXED_IP=$(ip -4 addr show ${INTERFACE} 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
}

detect_gateway() {
    FIXED_GATEWAY=$(ip route | grep default | awk '{print $3}' | head -1)
    [ -z "$FIXED_GATEWAY" ] && FIXED_GATEWAY="192.168.1.1"
}

detect_domain() {
    local current_domain=$(hostname -d 2>/dev/null | tr '[:lower:]' '[:upper:]')
    [ -n "$current_domain" ] && DOMAIN="$current_domain"
}

detect_netplan_file() {
    if [ -f "/etc/netplan/50-cloud-init.yaml" ]; then
        NETPLAN_FILE="/etc/netplan/50-cloud-init.yaml"
    elif [ -f "/etc/netplan/01-netcfg.yaml" ]; then
        NETPLAN_FILE="/etc/netplan/01-netcfg.yaml"
    else
        NETPLAN_FILE="/etc/netplan/01-netcfg.yaml"
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
# REDE
# ============================================

update_netplan() {
    local ip="$1"
    local gateway="$2"
    local dns1="${3:-$ip}"
    local dns2="${4:-8.8.8.8}"
    local search="${5:-${DOMAIN,,}}"
    
    detect_netplan_file
    
    cat > ${NETPLAN_FILE} << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${INTERFACE}:
      dhcp4: false
      addresses:
        - ${ip}/24
      routes:
        - to: default
          via: ${gateway}
      nameservers:
        addresses:
          - ${dns1}
          - ${dns2}
        search:
          - ${search}
EOF
    success "Netplan atualizado: ${NETPLAN_FILE}"
}

apply_netplan() {
    netplan apply 2>/dev/null
    systemctl restart systemd-networkd 2>/dev/null
    sleep 3
    detect_ip
    success "IP aplicado: ${FIXED_IP}"
}

# ============================================
# INSTALAÇÃO
# ============================================

install_packages() {
    log "Instalando pacotes..."
    apt update -qq
    apt install -y -qq samba samba-dsdb-modules samba-vfs-modules \
        winbind libpam-winbind libnss-winbind krb5-user krb5-config \
        dnsutils net-tools acl attr chrony ufw
}

configure_hostname() {
    log "Configurando hostname..."
    hostnamectl set-hostname ${HOSTNAME}.${DOMAIN,,}
    echo "${FIXED_IP} ${HOSTNAME}.${DOMAIN,,} ${HOSTNAME}" >> /etc/hosts
}

configure_dns() {
    log "Configurando DNS..."
    chattr -i /etc/resolv.conf 2>/dev/null || true
    cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
nameserver ${FIXED_IP}
nameserver 8.8.8.8
search ${DOMAIN,,}
domain ${DOMAIN,,}
EOF
    chattr +i /etc/resolv.conf 2>/dev/null || true
}

configure_ntp() {
    log "Configurando NTP..."
    apt install -y chrony
    cat > /etc/chrony/chrony.conf << EOF
server ${NTP_SERVER} iburst
server 0.pool.ntp.org iburst
server 1.pool.ntp.org iburst
makestep 1 3
allow 127.0.0.1
allow 192.168.1.0/24
EOF
    systemctl restart chrony
}

configure_firewall() {
    log "Configurando firewall..."
    for port in 53 88 389 445 135 139 636 3268 3269; do
        ufw allow ${port}/tcp 2>/dev/null
        ufw allow ${port}/udp 2>/dev/null
    done
    ufw allow 22/tcp 2>/dev/null
    success "Firewall configurado"
}

# ============================================
# INSTALAÇÃO PRIMÁRIA
# ============================================

provision_domain() {
    log "Provisionando domínio..."
    systemctl stop smbd nmbd winbind 2>/dev/null || true
    rm -f /etc/samba/smb.conf
    rm -rf /var/lib/samba/private 2>/dev/null || true
    rm -rf /var/lib/samba/sysvol 2>/dev/null || true
    
    samba-tool domain provision \
        --realm=${REALM} \
        --domain=${SHORT_DOMAIN} \
        --server-role=dc \
        --dns-backend=SAMBA_INTERNAL \
        --adminpass=${ADMIN_PASSWORD} \
        --use-rfc2307 \
        --host-ip=${FIXED_IP} \
        --option="interfaces=lo ${INTERFACE}" \
        >>"$LOG_FILE" 2>&1
    
    [ $? -eq 0 ] && success "Domínio provisionado" || error "Falha no provisionamento"
}

configure_samba() {
    log "Configurando Samba..."
    sed -i '/bind interfaces only/d' /etc/samba/smb.conf
    sed -i '/server signing/d' /etc/samba/smb.conf
    sed -i '/client signing/d' /etc/samba/smb.conf
    sed -i '/ntlm auth/d' /etc/samba/smb.conf
    echo "    log level = 2" >> /etc/samba/smb.conf
    echo "    max log size = 10000" >> /etc/samba/smb.conf
    echo "    debug timestamp = yes" >> /etc/samba/smb.conf
    success "Samba configurado"
}

start_samba() {
    log "Iniciando Samba..."
    systemctl unmask samba-ad-dc 2>/dev/null || true
    systemctl enable samba-ad-dc 2>/dev/null || true
    systemctl restart samba-ad-dc
    sleep 5
    systemctl is-active --quiet samba-ad-dc && success "Samba rodando" || error "Falha ao iniciar Samba"
}

install_primary() {
    log "Instalando CONTROLADOR PRIMÁRIO"
    
    install_packages
    configure_hostname
    configure_dns
    configure_ntp
    provision_domain
    configure_samba
    configure_firewall
    start_samba
    
    success "✅ Instalação primária concluída!"
}

# ============================================
# INSTALAÇÃO SECUNDÁRIA
# ============================================

join_domain() {
    log "Juntando ao domínio..."
    
    # Tentar join
    samba-tool domain join ${DOMAIN,,} DC \
        --server=${PRIMARY_DC_IP} \
        --password=${ADMIN_PASSWORD} \
        --dns-backend=SAMBA_INTERNAL \
        --option="interfaces=lo ${INTERFACE}" \
        --use-kerberos=off \
        >>"$LOG_FILE" 2>&1
    
    if [ $? -eq 0 ]; then
        success "Join realizado com sucesso!"
        return 0
    fi
    
    # Tentar sem servidor específico
    samba-tool domain join ${DOMAIN,,} DC \
        --password=${ADMIN_PASSWORD} \
        --dns-backend=SAMBA_INTERNAL \
        --use-kerberos=off \
        >>"$LOG_FILE" 2>&1
    
    if [ $? -eq 0 ]; then
        success "Join realizado com sucesso!"
        return 0
    fi
    
    error "Falha no join. Verifique a senha e conectividade."
}

fix_dns_secondary() {
    log "Registrando DNS..."
    samba-tool dns add 127.0.0.1 ${DOMAIN,,} @ A ${FIXED_IP} -U ${ADMIN_USER} --password=${ADMIN_PASSWORD} 2>/dev/null
    samba-tool dns add 127.0.0.1 ${DOMAIN,,} ${HOSTNAME} A ${FIXED_IP} -U ${ADMIN_USER} --password=${ADMIN_PASSWORD} 2>/dev/null
    samba-tool dns add 127.0.0.1 ${DOMAIN,,} _ldap._tcp SRV "0 100 389 ${HOSTNAME}.${DOMAIN,,}." -U ${ADMIN_USER} --password=${ADMIN_PASSWORD} 2>/dev/null
    samba-tool dns add 127.0.0.1 ${DOMAIN,,} _kerberos._tcp SRV "0 100 88 ${HOSTNAME}.${DOMAIN,,}." -U ${ADMIN_USER} --password=${ADMIN_PASSWORD} 2>/dev/null
    success "DNS registrado"
}

install_secondary() {
    log "Instalando CONTROLADOR SECUNDÁRIO"
    
    install_packages
    configure_hostname
    configure_dns
    configure_ntp
    join_domain
    configure_samba
    configure_firewall
    start_samba
    fix_dns_secondary
    
    success "✅ Instalação secundária concluída!"
}

# ============================================
# COLETA DE CONFIGURAÇÕES
# ============================================

collect_configurations() {
    header "CONFIGURAÇÃO DO DOMÍNIO"
    
    echo -e "IP atual: ${CYAN}${FIXED_IP}${NC}"
    echo -e "Domínio: ${CYAN}${DOMAIN}${NC}"
    echo ""
    
    read -p "Deseja alterar o domínio? (s/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Ss]$ ]]; then
        read -p "Digite o domínio: " DOMAIN
        DOMAIN=$(echo $DOMAIN | tr '[:lower:]' '[:upper:]')
        REALM="$DOMAIN"
        SHORT_DOMAIN=$(echo $DOMAIN | cut -d. -f1)
    fi
    
    read -p "Digite o hostname [adserver01]: " HOSTNAME
    [ -z "$HOSTNAME" ] && HOSTNAME="adserver01"
    
    if [ "$INSTALLATION_TYPE" == "secondary" ]; then
        echo ""
        echo -e "${YELLOW}Configurações do primário:${NC}"
        read -p "IP do primário [${PRIMARY_DC_IP}]: " tmp
        [ -n "$tmp" ] && PRIMARY_DC_IP="$tmp"
        read -p "Hostname do primário [${PRIMARY_DC_HOSTNAME}]: " tmp
        [ -n "$tmp" ] && PRIMARY_DC_HOSTNAME="$tmp"
    fi
    
    echo ""
    while true; do
        read -s -p "Senha do administrador: " ADMIN_PASSWORD
        echo ""
        read -s -p "Confirme a senha: " confirm
        echo ""
        [ ${#ADMIN_PASSWORD} -ge 8 ] && [ "$ADMIN_PASSWORD" == "$confirm" ] && break
        echo -e "${RED}Senha inválida! Min 8 caracteres e devem coincidir.${NC}"
    done
    
    echo ""
    header "RESUMO"
    echo -e "Tipo: ${CYAN}$([ "$INSTALLATION_TYPE" == "primary" ] && echo "PRIMÁRIO" || echo "SECUNDÁRIO")${NC}"
    echo -e "Domínio: ${CYAN}${DOMAIN}${NC}"
    echo -e "Hostname: ${CYAN}${HOSTNAME}.${DOMAIN,,}${NC}"
    echo -e "IP: ${CYAN}${FIXED_IP}${NC}"
    [ "$INSTALLATION_TYPE" == "secondary" ] && echo -e "Primário: ${CYAN}${PRIMARY_DC_HOSTNAME}.${DOMAIN,,} (${PRIMARY_DC_IP})${NC}"
    echo ""
    
    read -p "Continuar? (S/n): " -n 1 -r
    echo
    [[ $REPLY =~ ^[Nn]$ ]] && exit 0
}

# ============================================
# MENU PRINCIPAL
# ============================================

show_menu() {
    print_banner
    
    echo -e "${WHITE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${WHITE}║                    MENU PRINCIPAL                           ║${NC}"
    echo -e "${WHITE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${GREEN} 1)${NC} ${BOLD}CONFIGURAR REDE${NC}"
    echo -e "     ${CYAN}➜${NC} Configurar IP fixo"
    echo ""
    echo -e "${GREEN} 2)${NC} ${BOLD}INSTALAR PRIMÁRIO${NC}"
    echo -e "     ${CYAN}➜${NC} Criar novo domínio"
    echo ""
    echo -e "${GREEN} 3)${NC} ${BOLD}INSTALAR SECUNDÁRIO${NC}"
    echo -e "     ${CYAN}➜${NC} Juntar-se ao domínio"
    echo ""
    echo -e "${RED} 4)${NC} ${BOLD}SAIR${NC}"
    echo ""
    echo -e "${WHITE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ============================================
# MAIN
# ============================================

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERRO] Execute como root${NC}"
    exit 1
fi

detect_all
show_menu

while true; do
    read -p "👉 Escolha [1-4]: " choice
    case $choice in
        1)
            header "CONFIGURAR REDE"
            echo -e "Interface: ${CYAN}${INTERFACE}${NC}"
            echo -e "IP atual: ${CYAN}${FIXED_IP}${NC}"
            echo ""
            read -p "Novo IP [${FIXED_IP}]: " new_ip
            [ -z "$new_ip" ] && new_ip="$FIXED_IP"
            read -p "Gateway [${FIXED_GATEWAY}]: " new_gw
            [ -z "$new_gw" ] && new_gw="$FIXED_GATEWAY"
            
            update_netplan "$new_ip" "$new_gw"
            apply_netplan
            success "Rede configurada: ${FIXED_IP}"
            press_enter
            show_menu
            ;;
        2)
            INSTALLATION_TYPE="primary"
            collect_configurations
            install_primary
            exit 0
            ;;
        3)
            INSTALLATION_TYPE="secondary"
            collect_configurations
            install_secondary
            exit 0
            ;;
        4)
            echo -e "${YELLOW}Saindo...${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Opção inválida${NC}"
            ;;
    esac
done

exit 0