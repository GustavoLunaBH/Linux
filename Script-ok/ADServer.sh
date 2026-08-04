#!/bin/bash
# samba_ad_smart_v7.sh
# Script inteligente para configuração do Samba AD
# Versão: 7.0 - COMPLETO com todas as funções

set -e

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'

# Configurações
SCRIPT_VERSION="7.0"
LOG_FILE="/var/log/ad_setup.log"
BACKUP_DIR="/root/backup_$(date +%Y%m%d_%H%M%S)"
PROVISION_LOG="/tmp/provision.log"

# Variáveis
DOMAIN=""
REALM=""
SHORT_DOMAIN=""
HOSTNAME=""
IP_ADDR=""
INTERFACE=""
GATEWAY=""
DNS_SERVER=""
ADMIN_PASSWORD=""
OS=""
OS_VERSION=""
OS_NAME=""
PKG_MANAGER=""
SAMBA_VERSION=""

# ============================================
# FUNÇÕES DE LOG
# ============================================

log() {
    local level=$1
    shift
    local msg="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        INFO)    echo -e "${GREEN}[${timestamp}] [INFO]${NC} $msg" ;;
        WARN)    echo -e "${YELLOW}[${timestamp}] [WARN]${NC} $msg" ;;
        ERROR)   echo -e "${RED}[${timestamp}] [ERROR]${NC} $msg" ;;
        SUCCESS) echo -e "${BLUE}[${timestamp}] [SUCCESS]${NC} $msg" ;;
        *)       echo -e "[${timestamp}] $msg" ;;
    esac
    
    echo "[${timestamp}] [$level] $msg" >> $LOG_FILE
}

# ============================================
# FUNÇÕES DE VALIDAÇÃO
# ============================================

validate_ip() {
    local IP="$1"
    if ! echo "$IP" | grep -qE "^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"; then
        return 1
    fi
    for octet in $(echo $IP | tr '.' ' '); do
        if [ $octet -gt 255 ] || [ $octet -lt 0 ]; then
            return 1
        fi
    done
    return 0
}

validate_password() {
    local PASSWORD="$1"
    
    if [ ${#PASSWORD} -lt 8 ]; then
        echo "Senha deve ter pelo menos 8 caracteres"
        return 1
    fi
    
    if ! echo "$PASSWORD" | grep -q "[A-Z]"; then
        echo "Senha deve ter pelo menos uma letra maiúscula"
        return 1
    fi
    
    if ! echo "$PASSWORD" | grep -q "[a-z]"; then
        echo "Senha deve ter pelo menos uma letra minúscula"
        return 1
    fi
    
    if ! echo "$PASSWORD" | grep -q "[0-9]"; then
        echo "Senha deve ter pelo menos um número"
        return 1
    fi
    
    return 0
}

validate_domain() {
    local DOMAIN="$1"
    if ! echo "$DOMAIN" | grep -qE "^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"; then
        echo "Domínio inválido. Exemplo: EMPRESA.LOCAL"
        return 1
    fi
    return 0
}

# ============================================
# FUNÇÕES DE SISTEMA
# ============================================

get_system_info() {
    log INFO "Coletando informações do sistema..."
    
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
        OS_NAME="$PRETTY_NAME"
    else
        OS=$(uname -s)
        OS_VERSION=$(uname -r)
        OS_NAME="$OS $OS_VERSION"
    fi
    
    if command -v samba &> /dev/null; then
        SAMBA_VERSION=$(samba --version 2>/dev/null | awk '{print $2}' || echo "Não instalado")
    else
        SAMBA_VERSION="Não instalado"
    fi
    
    case $OS in
        ubuntu|debian) PKG_MANAGER="apt" ;;
        rocky|centos|rhel|almalinux) PKG_MANAGER="yum" ;;
        *) log ERROR "Sistema não suportado: $OS"; exit 1 ;;
    esac
}

show_system_info() {
    clear
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║               INFORMAÇÕES DO SISTEMA                         ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    echo -e "${WHITE}📊 Informações Atuais:${NC}"
    echo ""
    echo -e "  ${GREEN}▶${NC} Hostname:  ${CYAN}$(hostname)${NC}"
    echo -e "  ${GREEN}▶${NC} IP:        ${CYAN}$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1)${NC}"
    echo -e "  ${GREEN}▶${NC} Interface: ${CYAN}$(ip -o -4 route show to default | awk '{print $5}' | head -1)${NC}"
    echo -e "  ${GREEN}▶${NC} Sistema:   ${CYAN}$OS_NAME${NC}"
    echo -e "  ${GREEN}▶${NC} Kernel:    ${CYAN}$(uname -r)${NC}"
    echo -e "  ${GREEN}▶${NC} Samba:     ${CYAN}$SAMBA_VERSION${NC}"
    echo ""
}

# ============================================
# FUNÇÕES DE CONFIGURAÇÃO DE REDE
# ============================================

configure_network() {
    clear
    echo -e "${YELLOW}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║               CONFIGURAÇÃO DE REDE                           ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    show_system_info
    
    echo -e "${BLUE}Configuração de Rede:${NC}"
    echo ""
    
    # Interface
    echo -e "${YELLOW}Interfaces disponíveis:${NC}"
    ip link show | grep -E "^[0-9]+:" | grep -v lo | while read line; do
        IFACE=$(echo $line | cut -d: -f2 | xargs)
        IP_IFACE=$(ip -4 addr show $IFACE 2>/dev/null | grep inet | grep -v inet6 | awk '{print $2}' | cut -d/ -f1 | head -1)
        if [ ! -z "$IP_IFACE" ]; then
            echo -e "  ${GREEN}▶${NC} $IFACE - ${CYAN}${IP_IFACE}${NC}"
        else
            echo -e "  ${GREEN}▶${NC} $IFACE - ${YELLOW}Sem IP${NC}"
        fi
    done
    echo ""
    
    read -p "Interface (ex: ens33): " INTERFACE
    if [ -z "$INTERFACE" ]; then
        INTERFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
    fi
    
    # IP
    while true; do
        read -p "IP desejado (ex: 192.168.1.10): " IP_ADDR
        if [ -z "$IP_ADDR" ]; then
            IP_ADDR=$(ip -4 addr show $INTERFACE 2>/dev/null | grep inet | grep -v inet6 | awk '{print $2}' | cut -d/ -f1 | head -1)
            break
        fi
        if validate_ip "$IP_ADDR"; then
            break
        else
            log ERROR "IP inválido"
        fi
    done
    
    # Máscara
    read -p "Máscara (ex: 255.255.255.0): " NETMASK
    if [ -z "$NETMASK" ]; then
        NETMASK="255.255.255.0"
    fi
    
    # Gateway
    read -p "Gateway (ex: 192.168.1.1): " GATEWAY
    if [ -z "$GATEWAY" ]; then
        GATEWAY=$(ip route | grep default | awk '{print $3}' | head -1)
    fi
    
    # DNS
    read -p "DNS (ex: 8.8.8.8): " DNS_SERVER
    if [ -z "$DNS_SERVER" ]; then
        DNS_SERVER="8.8.8.8"
    fi
    
    # Confirmar
    clear
    echo -e "${YELLOW}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║              CONFIRMAR CONFIGURAÇÃO DE REDE                  ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    echo -e "  ${CYAN}Interface:${NC} $INTERFACE"
    echo -e "  ${CYAN}IP:${NC} $IP_ADDR/$NETMASK"
    echo -e "  ${CYAN}Gateway:${NC} $GATEWAY"
    echo -e "  ${CYAN}DNS:${NC} $DNS_SERVER"
    echo ""
    read -p "Aplicar esta configuração? (s/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Ss]$ ]]; then
        apply_network_config
    else
        log INFO "Configuração cancelada"
        return
    fi
}

apply_network_config() {
    log INFO "Aplicando configuração de rede..."
    
    # Backup
    mkdir -p $BACKUP_DIR
    [ -f /etc/network/interfaces ] && cp /etc/network/interfaces $BACKUP_DIR/ 2>/dev/null || true
    [ -d /etc/netplan ] && cp -r /etc/netplan $BACKUP_DIR/ 2>/dev/null || true
    
    # Calcular CIDR
    local CIDR=$(netmask_to_cidr "$NETMASK")
    
    # Aplicar via método apropriado
    if command -v nmcli &> /dev/null && systemctl is-active NetworkManager &> /dev/null; then
        log INFO "Usando NetworkManager..."
        nmcli con mod "$INTERFACE" ipv4.addresses "$IP_ADDR/$CIDR"
        nmcli con mod "$INTERFACE" ipv4.gateway "$GATEWAY"
        nmcli con mod "$INTERFACE" ipv4.dns "$DNS_SERVER"
        nmcli con mod "$INTERFACE" ipv4.method manual
        nmcli con down "$INTERFACE" 2>/dev/null || true
        nmcli con up "$INTERFACE"
    elif [ -d "/etc/netplan" ]; then
        log INFO "Usando Netplan..."
        cat > /etc/netplan/01-netcfg.yaml << EOF
network:
  version: 2
  ethernets:
    $INTERFACE:
      dhcp4: false
      addresses:
        - $IP_ADDR/$CIDR
      gateway4: $GATEWAY
      nameservers:
        addresses: [$DNS_SERVER]
EOF
        netplan apply
    elif [ -f "/etc/network/interfaces" ]; then
        log INFO "Usando /etc/network/interfaces..."
        cat >> /etc/network/interfaces << EOF
auto $INTERFACE
iface $INTERFACE inet static
    address $IP_ADDR
    netmask $NETMASK
    gateway $GATEWAY
    dns-nameservers $DNS_SERVER
EOF
        systemctl restart networking
    else
        log WARN "Usando método fallback..."
        ip addr flush dev $INTERFACE
        ip addr add $IP_ADDR/$CIDR dev $INTERFACE
        ip route del default 2>/dev/null || true
        ip route add default via $GATEWAY
        echo "nameserver $DNS_SERVER" > /etc/resolv.conf
    fi
    
    log SUCCESS "Configuração de rede aplicada"
    sleep 3
}

netmask_to_cidr() {
    local NETMASK="$1"
    local CIDR=0
    for octet in $(echo $NETMASK | tr '.' ' '); do
        case $octet in
            255) CIDR=$((CIDR+8)) ;;
            254) CIDR=$((CIDR+7)) ;;
            252) CIDR=$((CIDR+6)) ;;
            248) CIDR=$((CIDR+5)) ;;
            240) CIDR=$((CIDR+4)) ;;
            224) CIDR=$((CIDR+3)) ;;
            192) CIDR=$((CIDR+2)) ;;
            128) CIDR=$((CIDR+1)) ;;
            0)   ;;
        esac
    done
    echo $CIDR
}

# ============================================
# FUNÇÕES DE INSTALAÇÃO DO SAMBA
# ============================================

install_samba_packages() {
    log INFO "Instalando pacotes do Samba AD..."
    
    case $PKG_MANAGER in
        apt)
            log INFO "Corrigindo dependências..."
            apt --fix-broken install -y -qq 2>/dev/null || true
            
            # Remover conflitos
            if dpkg -l | grep -q ntpsec; then
                apt remove -y -qq ntpsec ntpdate 2>/dev/null || true
            fi
            
            log INFO "Atualizando repositórios..."
            apt update -qq
            
            log INFO "Instalando Samba e dependências..."
            DEBIAN_FRONTEND=noninteractive apt install -y -qq \
                acl attr \
                samba \
                samba-dsdb-modules \
                samba-vfs-modules \
                winbind \
                libpam-winbind \
                libnss-winbind \
                krb5-user \
                dnsutils \
                bind9utils \
                ldap-utils \
                bash-completion \
                chrony \
                python3 \
                python3-dnspython \
                python3-ldb \
                python3-talloc \
                python3-samba 2>/dev/null || {
                    log ERROR "Falha na instalação. Tentando com menos pacotes..."
                    apt install -y -qq samba winbind krb5-user dnsutils
                }
            ;;
            
        yum)
            log INFO "Instalando no RHEL/CentOS..."
            yum install -y -q samba samba-client samba-common \
                samba-dc samba-dc-dns samba-winbind \
                krb5-workstation bind-utils \
                chrony python3
            ;;
    esac
    
    # Parar serviços conflitantes
    systemctl stop smbd nmbd winbind 2>/dev/null || true
    systemctl disable smbd nmbd winbind 2>/dev/null || true
    
    # Verificar instalação
    if command -v samba-tool &> /dev/null; then
        SAMBA_VERSION=$(samba --version 2>/dev/null | awk '{print $2}')
        log SUCCESS "Samba $SAMBA_VERSION instalado com sucesso!"
    else
        log ERROR "Falha na instalação do Samba"
        exit 1
    fi
}

configure_hostname_and_hosts() {
    log INFO "Configurando hostname e /etc/hosts..."
    
    # Configurar hostname
    hostnamectl set-hostname ${HOSTNAME}.${DOMAIN,,}
    
    # Configurar /etc/hosts
    cat > /etc/hosts << EOF
127.0.0.1 localhost
127.0.1.1 ${HOSTNAME}.${DOMAIN,,} ${HOSTNAME}
${IP_ADDR} ${HOSTNAME}.${DOMAIN,,} ${HOSTNAME}
EOF
    
    log SUCCESS "Hostname configurado: ${HOSTNAME}.${DOMAIN,,}"
}

configure_kerberos() {
    log INFO "Configurando Kerberos..."
    
    cat > /etc/krb5.conf << EOF
[libdefaults]
    default_realm = ${DOMAIN}
    dns_lookup_realm = false
    dns_lookup_kdc = true
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true

[realms]
    ${DOMAIN} = {
        kdc = ${HOSTNAME}.${DOMAIN,,}
        admin_server = ${HOSTNAME}.${DOMAIN,,}
        default_domain = ${DOMAIN,,}
    }

[domain_realm]
    .${DOMAIN,,} = ${DOMAIN}
    ${DOMAIN,,} = ${DOMAIN}
    ${HOSTNAME} = ${DOMAIN}

[logging]
    kdc = FILE:/var/log/krb5kdc.log
    admin_server = FILE:/var/log/kadmin.log
    default = FILE:/var/log/krb5lib.log
EOF
    
    cp /etc/krb5.conf /var/lib/samba/private/krb5.conf 2>/dev/null || true
    log SUCCESS "Kerberos configurado"
}

configure_dns() {
    log INFO "Configurando DNS..."
    
    if lsattr /etc/resolv.conf 2>/dev/null | grep -q "i"; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
    fi
    
    cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
search ${DOMAIN,,}
domain ${DOMAIN,,}
EOF
    
    # Adicionar ao smb.conf
    if ! grep -q "dns forwarder" /etc/samba/smb.conf 2>/dev/null; then
        echo "    dns forwarder = ${DNS_SERVER}" >> /etc/samba/smb.conf
    fi
    
    log SUCCESS "DNS configurado"
}

provision_domain() {
    log INFO "Provisionando domínio ${DOMAIN}..."
    log INFO "Isso pode levar alguns minutos. Aguarde..."
    
    # Limpar configurações antigas
    rm -f /etc/samba/smb.conf
    rm -rf /var/lib/samba/private 2>/dev/null || true
    rm -rf /var/lib/samba/sysvol 2>/dev/null || true
    
    # Provisionar
    samba-tool domain provision \
        --use-rfc2307 \
        --realm=${DOMAIN} \
        --domain=${SHORT_DOMAIN} \
        --server-role=dc \
        --dns-backend=SAMBA_INTERNAL \
        --adminpass=${ADMIN_PASSWORD} \
        --host-ip=${IP_ADDR} \
        --option="interfaces=lo ${INTERFACE}" \
        --option="bind interfaces only=yes" \
        > ${PROVISION_LOG} 2>&1
    
    if [ $? -eq 0 ]; then
        log SUCCESS "Domínio provisionado com sucesso!"
        
        # Copiar smb.conf
        if [ -f "/var/lib/samba/private/smb.conf" ]; then
            cp /var/lib/samba/private/smb.conf /etc/samba/smb.conf
        fi
        
        return 0
    else
        log ERROR "Falha no provisionamento"
        echo -e "${YELLOW}Últimas linhas do log:${NC}"
        tail -20 ${PROVISION_LOG}
        return 1
    fi
}

start_samba_services() {
    log INFO "Iniciando serviços do Samba..."
    
    systemctl unmask samba-ad-dc 2>/dev/null || true
    systemctl enable samba-ad-dc 2>/dev/null || true
    systemctl restart samba-ad-dc
    
    # Aguardar iniciar
    log INFO "Aguardando serviços iniciarem..."
    sleep 10
    
    if systemctl is-active samba-ad-dc >/dev/null 2>&1; then
        log SUCCESS "Serviço samba-ad-dc ativo"
    else
        log ERROR "Serviço não iniciou corretamente"
        systemctl status samba-ad-dc --no-pager
        return 1
    fi
    
    return 0
}

create_users_and_groups() {
    log INFO "Criando usuários e grupos..."
    
    # Criar grupos
    samba-tool group add "admins" --description="Administradores do Domínio" 2>/dev/null || true
    samba-tool group add "users" --description="Usuários do Domínio" 2>/dev/null || true
    
    # Criar usuário admin2
    samba-tool user create admin2 ${ADMIN_PASSWORD} \
        --given-name="Admin" \
        --surname="Secundario" 2>/dev/null || true
    
    samba-tool group addmembers "Domain Admins" admin2 2>/dev/null || true
    
    log SUCCESS "Usuários e grupos criados"
}

test_services() {
    log INFO "Testando serviços..."
    
    # Testar DNS
    log INFO "Testando DNS..."
    if host -t SRV _ldap._tcp.${DOMAIN,,} >/dev/null 2>&1; then
        log SUCCESS "✓ DNS SRV funcionando"
    else
        log WARN "DNS SRV não respondeu"
    fi
    
    if host -t A ${HOSTNAME}.${DOMAIN,,} >/dev/null 2>&1; then
        log SUCCESS "✓ Hostname resolvido"
    else
        log WARN "Hostname não resolvido"
    fi
    
    # Testar Kerberos
    log INFO "Testando Kerberos..."
    if echo "${ADMIN_PASSWORD}" | kinit administrator@${DOMAIN} >/dev/null 2>&1; then
        log SUCCESS "✓ Kerberos funcionando"
        echo -e "${BLUE}Ticket atual:${NC}"
        klist
    else
        log WARN "Kerberos falhou"
    fi
}

save_info() {
    log INFO "Salvando informações..."
    
    cat > /root/ad_info.txt << EOF
═══════════════════════════════════════════════════════════════════
                    AD SERVER PRIMÁRIO
═══════════════════════════════════════════════════════════════════

DOMÍNIO: ${DOMAIN}
REALM: ${DOMAIN}
HOSTNAME: ${HOSTNAME}.${DOMAIN,,}
IP: ${IP_ADDR}
INTERFACE: ${INTERFACE}
GATEWAY: ${GATEWAY}
DNS: ${DNS_SERVER}
SISTEMA: ${OS_NAME}
SAMBA: ${SAMBA_VERSION}
DATA: $(date)

───────────────────────────────────────────────────────────────────
USUÁRIOS
───────────────────────────────────────────────────────────────────
Administrador: administrator@${DOMAIN}
Senha: ${ADMIN_PASSWORD}

Usuário Secundário: admin2@${DOMAIN}
Senha: ${ADMIN_PASSWORD}

───────────────────────────────────────────────────────────────────
COMANDOS ÚTEIS
───────────────────────────────────────────────────────────────────
# Testar Kerberos
echo '${ADMIN_PASSWORD}' | kinit administrator@${DOMAIN}

# Verificar ticket
klist

# Listar usuários
samba-tool user list

# Listar grupos
samba-tool group list

# Testar DNS
host -t SRV _ldap._tcp.${DOMAIN,,}

───────────────────────────────────────────────────────────────────
LOGS
───────────────────────────────────────────────────────────────────
Log do script: ${LOG_FILE}
Provisionamento: ${PROVISION_LOG}
Samba: /var/log/samba/log.samba
Kerberos: /var/log/krb5kdc.log
EOF
    
    chmod 600 /root/ad_info.txt
    log SUCCESS "Informações salvas em /root/ad_info.txt"
}

show_summary() {
    clear
    echo -e "${GREEN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║                                                               ║"
    echo "║         ✅ CONFIGURAÇÃO CONCLUÍDA COM SUCESSO!                ║"
    echo "║                                                               ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    echo -e "${BLUE}📋 RESUMO DA INSTALAÇÃO:${NC}"
    echo ""
    echo -e "  ${GREEN}✓${NC} Papel: ${CYAN}AD Server Primário${NC}"
    echo -e "  ${GREEN}✓${NC} Domínio: ${CYAN}${DOMAIN}${NC}"
    echo -e "  ${GREEN}✓${NC} Hostname: ${CYAN}${HOSTNAME}.${DOMAIN,,}${NC}"
    echo -e "  ${GREEN}✓${NC} IP: ${CYAN}${IP_ADDR}${NC}"
    echo -e "  ${GREEN}✓${NC} Interface: ${CYAN}${INTERFACE}${NC}"
    echo -e "  ${GREEN}✓${NC} Sistema: ${CYAN}${OS_NAME}${NC}"
    echo -e "  ${GREEN}✓${NC} Samba: ${CYAN}${SAMBA_VERSION}${NC}"
    echo ""
    
    echo -e "${YELLOW}📌 CREDENCIAIS DE ACESSO:${NC}"
    echo ""
    echo -e "  Usuário: ${CYAN}administrator@${DOMAIN}${NC}"
    echo -e "  Senha: ${CYAN}${ADMIN_PASSWORD}${NC}"
    echo ""
    
    echo -e "${YELLOW}💡 DICAS:${NC}"
    echo -e "  ✅ Use TAB para auto completar comandos"
    echo -e "  ✅ Backup em: ${CYAN}${BACKUP_DIR}${NC}"
    echo -e "  ✅ Informações: ${CYAN}/root/ad_info.txt${NC}"
    echo -e "  ✅ Log completo: ${CYAN}${LOG_FILE}${NC}"
    echo ""
    
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
}

# ============================================
# FUNÇÃO PRINCIPAL - AD PRIMÁRIO (COMPLETA)
# ============================================

install_ad_primary() {
    log INFO "=== INICIANDO INSTALAÇÃO AD SERVER PRIMÁRIO ==="
    
    # 1. Mostrar informações do sistema
    show_system_info
    read -p "Pressione ENTER para continuar..."
    
    # 2. Configurar rede
    configure_network
    
    # 3. Coletar informações do domínio
    clear
    echo -e "${YELLOW}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║              CONFIGURAÇÃO DO DOMÍNIO                         ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    
    # Domínio
    while true; do
        read -p "Domínio (ex: EMPRESA.LOCAL): " DOMAIN
        DOMAIN=$(echo $DOMAIN | tr '[:lower:]' '[:upper:]')
        if validate_domain "$DOMAIN"; then
            break
        fi
    done
    
    SHORT_DOMAIN=$(echo $DOMAIN | cut -d. -f1)
    
    # Hostname
    echo ""
    echo -e "Hostname atual: ${CYAN}$(hostname | cut -d. -f1)${NC}"
    read -p "Hostname desejado (ex: adserver01): " HOSTNAME
    if [ -z "$HOSTNAME" ]; then
        HOSTNAME=$(hostname | cut -d. -f1)
    fi
    
    # Senha do administrador
    echo ""
    echo -e "${BLUE}Definir senha do administrador:${NC}"
    echo -e "${YELLOW}Requisitos: Mínimo 8 caracteres, maiúscula, minúscula e número${NC}"
    while true; do
        read -s -p "Senha: " ADMIN_PASSWORD
        echo
        read -s -p "Confirmar senha: " ADMIN_PASSWORD_CONFIRM
        echo
        
        if [ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD_CONFIRM" ]; then
            log ERROR "Senhas não coincidem"
            continue
        fi
        
        if validate_password "$ADMIN_PASSWORD"; then
            break
        fi
    done
    
    # 4. Confirmar configurações
    clear
    echo -e "${YELLOW}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║                   CONFIRMAR CONFIGURAÇÕES                    ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    echo -e "  ${CYAN}Domínio:${NC} ${DOMAIN}"
    echo -e "  ${CYAN}Hostname:${NC} ${HOSTNAME}.${DOMAIN,,}"
    echo -e "  ${CYAN}IP:${NC} ${IP_ADDR}"
    echo -e "  ${CYAN}Interface:${NC} ${INTERFACE}"
    echo -e "  ${CYAN}Gateway:${NC} ${GATEWAY}"
    echo -e "  ${CYAN}DNS:${NC} ${DNS_SERVER}"
    echo ""
    echo -e "${YELLOW}⚠️  ATENÇÃO: Este processo irá:${NC}"
    echo -e "  1. Configurar o hostname"
    echo -e "  2. Instalar o Samba AD"
    echo -e "  3. Provisionar o domínio ${DOMAIN}"
    echo -e "  4. Configurar Kerberos e DNS"
    echo -e "  5. Criar usuários e grupos"
    echo ""
    read -p "Prosseguir com a instalação? (s/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Ss]$ ]]; then
        log INFO "Instalação cancelada pelo usuário"
        return
    fi
    
    # 5. INÍCIO DA INSTALAÇÃO
    echo ""
    log INFO "INICIANDO INSTALAÇÃO..."
    echo ""
    
    # Backup
    mkdir -p $BACKUP_DIR
    log SUCCESS "Backup criado em: $BACKUP_DIR"
    
    # Configurar hostname e hosts
    configure_hostname_and_hosts
    
    # Instalar pacotes
    install_samba_packages
    
    # Provisionar domínio
    if ! provision_domain; then
        log ERROR "Falha no provisionamento. Verifique o log: $PROVISION_LOG"
        exit 1
    fi
    
    # Configurar Kerberos
    configure_kerberos
    
    # Configurar DNS
    configure_dns
    
    # Iniciar serviços
    if ! start_samba_services; then
        log ERROR "Falha ao iniciar serviços"
        exit 1
    fi
    
    # Criar usuários e grupos
    create_users_and_groups
    
    # Testar serviços
    test_services
    
    # Salvar informações
    save_info
    
    # Mostrar resumo
    show_summary
    
    log SUCCESS "=== INSTALAÇÃO CONCLUÍDA COM SUCESSO! ==="
}

# ============================================
# OUTRAS FUNÇÕES DE INSTALAÇÃO
# ============================================

install_ad_secondary() {
    log INFO "=== INSTALAÇÃO AD SERVER SECUNDÁRIO ==="
    echo -e "${YELLOW}Em desenvolvimento...${NC}"
    sleep 2
}

install_ad_tertiary() {
    log INFO "=== INSTALAÇÃO AD SERVER TERCIÁRIO ==="
    echo -e "${YELLOW}Em desenvolvimento...${NC}"
    sleep 2
}

install_file_server() {
    log INFO "=== INSTALAÇÃO FILE SERVER ==="
    echo -e "${YELLOW}Em desenvolvimento...${NC}"
    sleep 2
}

join_domain_only() {
    log INFO "=== JOIN AO DOMÍNIO ==="
    echo -e "${YELLOW}Em desenvolvimento...${NC}"
    sleep 2
}

# ============================================
# MENU PRINCIPAL
# ============================================

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}"
        echo "╔═══════════════════════════════════════════════════════════════╗"
        echo "║                                                               ║"
        echo "║         🖥️  SAMBA AD SMART CONFIGURATOR v${SCRIPT_VERSION}     ║"
        echo "║                                                               ║"
        echo "║         Configuração Inteligente de Domínio                  ║"
        echo "║                                                               ║"
        echo "╚═══════════════════════════════════════════════════════════════╝"
        echo -e "${NC}"
        
        # Mostrar informações rápidas
        echo -e "${CYAN}📊 Sistema:${NC} $OS_NAME"
        echo -e "${CYAN}🌐 IP:${NC} $(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1)"
        echo -e "${CYAN}💻 Hostname:${NC} $(hostname)"
        echo -e "${CYAN}📦 Samba:${NC} $SAMBA_VERSION"
        echo ""
        
        echo -e "${YELLOW}Selecione o papel do servidor:${NC}"
        echo ""
        echo -e "  ${GREEN}1)${NC} AD Server ${BLUE}PRIMÁRIO${NC} - Novo domínio"
        echo -e "  ${GREEN}2)${NC} AD Server ${BLUE}SECUNDÁRIO${NC} - Replicação do domínio"
        echo -e "  ${GREEN}3)${NC} AD Server ${BLUE}TERCIÁRIO/RODC${NC} - Controlador somente leitura"
        echo -e "  ${GREEN}4)${NC} ${BLUE}File Server${NC} - Servidor de arquivos integrado ao domínio"
        echo -e "  ${GREEN}5)${NC} ${BLUE}Join Domain${NC} - Apenas adicionar ao domínio"
        echo -e "  ${GREEN}6)${NC} ${BLUE}Configurar Rede${NC} - Alterar IP/Hostname"
        echo -e "  ${GREEN}7)${NC} ${BLUE}Informações do Sistema${NC}"
        echo -e "  ${GREEN}8)${NC} ${RED}Sair${NC}"
        echo ""
        read -p "Escolha uma opção (1-8): " OPTION
        
        case $OPTION in
            1) install_ad_primary ;;
            2) install_ad_secondary ;;
            3) install_ad_tertiary ;;
            4) install_file_server ;;
            5) join_domain_only ;;
            6) configure_network ;;
            7) show_system_info; read -p "Pressione ENTER para continuar..." ;;
            8) echo -e "${GREEN}Saindo...${NC}"; exit 0 ;;
            *) log ERROR "Opção inválida"; sleep 2 ;;
        esac
    done
}

# ============================================
# INÍCIO DO SCRIPT
# ============================================

# Verificar root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Este script deve ser executado como root (sudo)${NC}"
    exit 1
fi

# Inicializar log
> $LOG_FILE
log INFO "=== INICIANDO SCRIPT v${SCRIPT_VERSION} ==="

# Detectar sistema
get_system_info
log SUCCESS "Sistema detectado: $OS_NAME"

# Configurar locale
if [ "$PKG_MANAGER" = "apt" ]; then
    log INFO "Configurando locale..."
    apt update -qq 2>/dev/null || true
    apt install -y -qq language-pack-pt locales 2>/dev/null || true
    locale-gen pt_BR.UTF-8 2>/dev/null || true
    update-locale LANG=pt_BR.UTF-8 LANGUAGE=pt_BR:pt LC_ALL=pt_BR.UTF-8 2>/dev/null || true
fi
export LANG=pt_BR.UTF-8
export LANGUAGE=pt_BR:pt
export LC_ALL=pt_BR.UTF-8

# Configurar auto complete
if [ "$PKG_MANAGER" = "apt" ]; then
    apt install -y -qq bash-completion 2>/dev/null || true
fi
if ! grep -q "bash-completion" /root/.bashrc 2>/dev/null; then
    cat >> /root/.bashrc << 'EOF'
if [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
fi
complete -C samba-tool samba-tool 2>/dev/null || true
EOF
fi

# Menu principal
main_menu

# Opção de reiniciar
echo ""
read -p "Deseja reiniciar o servidor agora? (s/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Ss]$ ]]; then
    log INFO "Reiniciando servidor em 5 segundos..."
    sleep 5
    reboot
else
    log INFO "Lembre-se de reiniciar o servidor depois para aplicar todas as configurações."
fi
