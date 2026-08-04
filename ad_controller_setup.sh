#!/bin/bash
# ad_controller_setup.sh
# Script unificado para instalação do Samba AD - Versão 2.0
# Suporte: Primário e Secundário com detecção automática

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
INTERFACE="ens33"
DNS_FORWARDER="8.8.8.8"
NTP_SERVER="a.st1.ntp.br"
PRIMARY_DC_IP="192.168.1.2"
PRIMARY_DC_HOSTNAME="adserver01"
SCRIPT_VERSION="2.0"
LOG_FILE="/tmp/ad_setup_$(date +%Y%m%d_%H%M%S).log"
INSTALLATION_TYPE=""
HOSTNAME=""

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

print_banner() {
    clear
    echo -e "${MAGENTA}"
    cat << "EOF"
    ╔══════════════════════════════════════════════════════════════╗
    ║                                                              ║
    ║     █████╗ ██████╗      ███████╗███████╗████████╗██╗   ██╗ ██████╗ 
    ║    ██╔══██╗██╔══██╗     ██╔════╝██╔════╝╚══██╔══╝██║   ██║██╔════╝ 
    ║    ███████║██║  ██║     ███████╗█████╗     ██║   ██║   ██║╚█████╗  
    ║    ██╔══██║██║  ██║     ╚════██║██╔══╝     ██║   ██║   ██║ ╚═══██╗ 
    ║    ██║  ██║██████╔╝     ███████║███████╗   ██║   ╚██████╔╝██████╔╝ 
    ║    ╚═╝  ╚═╝╚═════╝      ╚══════╝╚══════╝   ╚═╝    ╚═════╝ ╚═════╝  
    ║                                                              ║
    ║           INSTALADOR DO CONTROLADOR DE DOMÍNIO               ║
    ║                  Samba AD - Versão ${SCRIPT_VERSION}                        ║
    ╚══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# ============================================
# DETECÇÃO DE SISTEMA
# ============================================

detect_interface() {
    # Detecta a interface de rede principal
    local interfaces=$(ip -o link show | grep -v "lo:" | grep -v "@" | awk -F': ' '{print $2}' | head -1)
    if [ -n "$interfaces" ]; then
        INTERFACE="$interfaces"
        info "Interface detectada: ${INTERFACE}"
    fi
}

detect_ip() {
    # Detecta IP atual da interface
    local current_ip=$(ip -4 addr show ${INTERFACE} | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    if [ -n "$current_ip" ] && [ "$current_ip" != "127.0.0.1" ]; then
        if [ -z "$FIXED_IP" ]; then
            FIXED_IP="$current_ip"
            info "IP detectado: ${FIXED_IP}"
        fi
    fi
}

detect_gateway() {
    local gateway=$(ip route | grep default | awk '{print $3}' | head -1)
    if [ -n "$gateway" ]; then
        FIXED_GATEWAY="$gateway"
        info "Gateway detectado: ${FIXED_GATEWAY}"
    fi
}

detect_domain() {
    local current_domain=$(hostname -d 2>/dev/null | tr '[:lower:]' '[:upper:]')
    if [ -n "$current_domain" ] && [ "$current_domain" != "" ]; then
        DOMAIN="$current_domain"
        REALM="$DOMAIN"
        SHORT_DOMAIN=$(echo $DOMAIN | cut -d. -f1)
        info "Domínio detectado: ${DOMAIN}"
    fi
}

auto_detect() {
    header "DETECTANDO CONFIGURAÇÕES DO SISTEMA"
    detect_interface
    detect_ip
    detect_gateway
    detect_domain
    echo ""
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
    echo -e "   - O servidor será reiniciado ao final da instalação"
    echo -e "   - Certifique-se de ter um backup dos dados importantes"
    echo ""
    echo -e "${WHITE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${WHITE}║                    TIPOS DE INSTALAÇÃO                      ║${NC}"
    echo -e "${WHITE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${GREEN} 1)${NC} ${BOLD}CONTROLADOR PRIMÁRIO${NC}"
    echo -e "     ${CYAN}➜${NC} Primeiro DC do domínio"
    echo -e "     ${CYAN}➜${NC} Cria um novo domínio do zero"
    echo -e "     ${CYAN}➜${NC} Contém todas as funções FSMO"
    echo ""
    echo -e "${GREEN} 2)${NC} ${BOLD}CONTROLADOR SECUNDÁRIO${NC}"
    echo -e "     ${CYAN}➜${NC} DC adicional para redundância"
    echo -e "     ${CYAN}➜${NC} Se junta a um domínio existente"
    echo -e "     ${CYAN}➜${NC} Réplica do banco de dados"
    echo ""
    echo -e "${GREEN} 3)${NC} ${BOLD}MODO AUTOMÁTICO${NC}"
    echo -e "     ${CYAN}➜${NC} Detecta automaticamente o tipo"
    echo -e "     ${CYAN}➜${NC} Usa configurações padrão"
    echo -e "     ${CYAN}➜${NC} Ideal para automação"
    echo ""
    echo -e "${RED} 4)${NC} ${BOLD}SAIR${NC}"
    echo ""
    echo -e "${WHITE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

get_installation_type() {
    while true; do
        read -p "👉 Escolha uma opção [1-4]: " choice
        case $choice in
            1)
                INSTALLATION_TYPE="primary"
                break
                ;;
            2)
                INSTALLATION_TYPE="secondary"
                break
                ;;
            3)
                INSTALLATION_TYPE="auto"
                break
                ;;
            4)
                echo -e "${YELLOW}Instalação cancelada.${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Opção inválida! Tente novamente.${NC}"
                ;;
        esac
    done
}

# ============================================
# COLETA DE CONFIGURAÇÕES
# ============================================

collect_configurations() {
    header "CONFIGURAÇÃO DO DOMÍNIO"
    
    # Configurações comuns
    if [ "$INSTALLATION_TYPE" != "auto" ]; then
        echo -e "${BLUE}Configurações atuais do sistema:${NC}"
        echo -e "  Interface: ${CYAN}${INTERFACE}${NC}"
        echo -e "  IP: ${CYAN}${FIXED_IP:-Não detectado}${NC}"
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
        
        echo -e "${BLUE}Digite a interface de rede [${INTERFACE}]:${NC}"
        read -p "> " INTERFACE_INPUT
        if [ -n "$INTERFACE_INPUT" ]; then
            INTERFACE="$INTERFACE_INPUT"
        fi
        
        echo -e "${BLUE}Digite o IP fixo [${FIXED_IP:-192.168.1.2}]:${NC}"
        read -p "> " IP_INPUT
        if [ -n "$IP_INPUT" ]; then
            FIXED_IP="$IP_INPUT"
        elif [ -z "$FIXED_IP" ]; then
            FIXED_IP="192.168.1.2"
        fi
        
        echo -e "${BLUE}Digite o gateway [${FIXED_GATEWAY}]:${NC}"
        read -p "> " GATEWAY_INPUT
        if [ -n "$GATEWAY_INPUT" ]; then
            FIXED_GATEWAY="$GATEWAY_INPUT"
        fi
        
        # Configurações específicas
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
    else
        # Modo automático - usa valores padrão
        if [ -z "$HOSTNAME" ]; then
            HOSTNAME="adserver01"
        fi
        if [ -z "$FIXED_IP" ]; then
            FIXED_IP="192.168.1.2"
        fi
    fi
    
    # Senha do administrador
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
    
    # Resumo
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
# FUNÇÕES COMPARTILHADAS
# ============================================

fix_system_dns() {
    log "Configurando DNS do sistema..."
    
    # Remover imutável
    chattr -i /etc/resolv.conf 2>/dev/null || true
    chattr -i /etc/resolvconf/resolv.conf.d/head 2>/dev/null || true
    
    # Criar diretório
    mkdir -p /etc/resolvconf/resolv.conf.d 2>/dev/null
    
    # Configurar DNS primário
    local dns_primary="${FIXED_IP}"
    if [ "$INSTALLATION_TYPE" == "secondary" ]; then
        dns_primary="${PRIMARY_DC_IP}"
    fi
    
    # Configurar resolv.conf
    cat > /etc/resolv.conf << EOF
nameserver ${dns_primary}
nameserver 127.0.0.1
nameserver 8.8.8.8
nameserver 1.1.1.1
search ${DOMAIN,,}
domain ${DOMAIN,,}
EOF
    
    # Configurar cabeçalho do resolvconf
    cat > /etc/resolvconf/resolv.conf.d/head << EOF
nameserver ${dns_primary}
nameserver 127.0.0.1
nameserver 8.8.8.8
nameserver 1.1.1.1
search ${DOMAIN,,}
domain ${DOMAIN,,}
EOF
    
    # Desabilitar systemd-resolved
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        systemctl stop systemd-resolved 2>/dev/null
        systemctl disable systemd-resolved 2>/dev/null
        log "systemd-resolved desabilitado"
    fi
    
    # Tornar imutável
    chattr +i /etc/resolv.conf 2>/dev/null || true
    
    # Testar
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
    
    # Se for secundário, usa o primário como NTP
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
    
    # Verificar Samba
    if command -v samba-tool &> /dev/null; then
        success "Samba instalado: $(samba-tool --version 2>/dev/null | head -1)"
    else
        error "Samba não foi instalado corretamente"
    fi
}

# ============================================
# FUNÇÕES PARA INSTALAÇÃO PRIMÁRIA
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
    
    # Adicionar configurações extras
    cat >> /etc/samba/smb.conf << 'EOF'
    server signing = required
    client signing = required
    ntlm auth = disabled
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
    
    # Testar Kerberos
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
    
    # Testar DNS
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
# FUNÇÕES PARA INSTALAÇÃO SECUNDÁRIA
# ============================================

remove_dhcp() {
    header "REMOVENDO DHCP E CONFIGURANDO IP FIXO"
    
    log "Parando todos os serviços DHCP..."
    systemctl stop dhcpcd 2>/dev/null || true
    systemctl disable dhcpcd 2>/dev/null || true
    systemctl stop network-manager 2>/dev/null || true
    systemctl disable network-manager 2>/dev/null || true
    systemctl stop systemd-networkd 2>/dev/null || true
    pkill -f dhclient 2>/dev/null || true
    pkill -f dhcpcd 2>/dev/null || true
    
    log "Removendo IPs antigos e configurando IP fixo..."
    ip addr flush dev ${INTERFACE}
    ip addr add ${FIXED_IP}/24 dev ${INTERFACE}
    ip route add default via ${FIXED_GATEWAY}
    
    log "Configurando netplan..."
    cat > /etc/netplan/01-netcfg.yaml << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${INTERFACE}:
      dhcp4: false
      dhcp6: false
      addresses:
        - ${FIXED_IP}/24
      routes:
        - to: default
          via: ${FIXED_GATEWAY}
      nameservers:
        addresses:
          - ${PRIMARY_DC_IP}
          - 8.8.8.8
        search:
          - ${DOMAIN,,}
EOF
    
    netplan apply 2>/dev/null || true
    sleep 3
    
    # Verificar
    if ip addr show ${INTERFACE} | grep -q "${FIXED_IP}"; then
        success "IP fixo ${FIXED_IP} configurado com sucesso"
    else
        error "Falha ao configurar IP fixo"
    fi
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
    
    # Configurar /etc/hosts
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
    
    # Tentativa 1: Com senha
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
    
    # Tentativa 2: Sem dns-backend
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
    server signing = required
    client signing = required
    ntlm auth = disabled
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
    samba-tool domain listdcs 2>/dev/null || echo "  Aguardando inicialização..."
    echo ""
    
    echo -e "${BLUE}=== Replicação ===${NC}"
    samba-tool drs showrepl 2>/dev/null | head -5 || echo "  Aguardando replicação..."
}

# ============================================
# SCRIPT DE CORREÇÃO DNS
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

# ============================================
# SALVAR INFORMAÇÕES
# ============================================

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
# INSTALAÇÃO PRIMÁRIA COMPLETA
# ============================================

install_primary() {
    log "Iniciando instalação do CONTROLADOR PRIMÁRIO"
    
    # Etapas comuns
    fix_system_dns
    configure_locale
    configure_ntp
    install_packages
    configure_hostname
    
    # Etapas específicas do primário
    provision_domain
    configure_samba_primary
    configure_kerberos_primary
    test_primary_services
    final_tests_primary
    
    # Finalização
    create_fix_dns_script
    save_info
}

# ============================================
# INSTALAÇÃO SECUNDÁRIA COMPLETA
# ============================================

install_secondary() {
    log "Iniciando instalação do CONTROLADOR SECUNDÁRIO"
    
    # Etapas específicas do secundário
    remove_dhcp
    configure_dns_secondary
    configure_locale
    sync_time
    install_packages
    configure_hostname
    configure_kerberos_secondary
    test_connection
    test_kerberos_secondary
    join_domain
    configure_samba_secondary
    verify_secondary
    
    # Finalização
    create_fix_dns_script
    save_info
}

# ============================================
# MODO AUTOMÁTICO
# ============================================

auto_detect_type() {
    log "Detectando tipo de instalação automaticamente..."
    
    # Verifica se já existe um AD na rede
    if host ${DOMAIN,,} &> /dev/null; then
        info "Domínio ${DOMAIN} encontrado na rede"
        INSTALLATION_TYPE="secondary"
        # Tenta detectar o IP do primário
        PRIMARY_DC_IP=$(dig +short ${DOMAIN,,} | head -1)
        if [ -n "$PRIMARY_DC_IP" ]; then
            info "DC Primário detectado: ${PRIMARY_DC_IP}"
        fi
    else
        info "Nenhum domínio encontrado - instalando como primário"
        INSTALLATION_TYPE="primary"
    fi
}

install_auto() {
    log "Iniciando instalação no modo automático..."
    
    # Auto detect
    auto_detect_type
    
    # Coleta mínima de informações
    if [ -z "$HOSTNAME" ]; then
        if [ "$INSTALLATION_TYPE" == "primary" ]; then
            HOSTNAME="adserver01"
        else
            HOSTNAME="adserver02"
        fi
    fi
    
    if [ -z "$FIXED_IP" ]; then
        FIXED_IP="192.168.1.2"
    fi
    
    # Senha padrão (atenção: apenas para automação)
    if [ -z "$ADMIN_PASSWORD" ]; then
        ADMIN_PASSWORD="Samba@2024"
        warning "Usando senha padrão: ${ADMIN_PASSWORD}"
    fi
    
    # Instala
    if [ "$INSTALLATION_TYPE" == "primary" ]; then
        install_primary
    else
        install_secondary
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
    echo -e "${YELLOW}🛠️  COMANDOS ÚTEIS:${NC}"
    echo -e "  ${BLUE}fix-dns${NC} - Corrigir DNS se necessário"
    echo -e "  ${BLUE}kinit ${ADMIN_USER}@${DOMAIN}${NC} - Autenticar no Kerberos"
    echo -e "  ${BLUE}samba-tool domain info 127.0.0.1${NC} - Info do domínio"
    echo ""
    echo -e "${YELLOW}💻 PARA CLIENTES WINDOWS:${NC}"
    echo -e "  Configure o DNS dos clientes para: ${BLUE}${FIXED_IP}${NC}"
    echo -e "  Domínio para adicionar: ${BLUE}${DOMAIN}${NC}"
    echo -e "  Usuário: ${BLUE}${ADMIN_USER}@${DOMAIN}${NC}"
    echo ""
    
    if [ "$INSTALLATION_TYPE" == "secondary" ]; then
        echo -e "${GREEN}📋 INFORMAÇÕES DO SECUNDÁRIO:${NC}"
        echo -e "  ${BLUE}samba-tool drs showrepl${NC} - Verificar replicação"
        echo -e "  ${BLUE}samba-tool domain listdcs${NC} - Listar DCs"
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
        log ""
        log "Para testar o AD:"
        log "  kinit ${ADMIN_USER}@${DOMAIN}"
        log "  klist"
        log "  samba-tool domain info 127.0.0.1"
    fi
}

# ============================================
# INÍCIO DO SCRIPT
# ============================================

# Verificar root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERRO] Este script deve ser executado como root (sudo)${NC}"
    exit 1
fi

# Auto detect inicial
auto_detect

# Mostrar menu e obter tipo de instalação
show_menu
get_installation_type

# Se for modo automático
if [ "$INSTALLATION_TYPE" == "auto" ]; then
    install_auto
    finalize_installation
    exit 0
fi

# Coletar configurações
collect_configurations

# Executar instalação
if [ "$INSTALLATION_TYPE" == "primary" ]; then
    install_primary
else
    install_secondary
fi

# Finalizar
finalize_installation

exit 0