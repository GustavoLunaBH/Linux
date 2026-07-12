#!/bin/bash
# samba_ad_smart.sh
# Script inteligente para configuração do Samba AD
# Versão: 4.0 - Multi-funcional
# Suporte: AD Primário, Secundário, Terciário, File Server, Join Domain

set -e

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Configurações padrão
DOMAIN="RNV.LOCAL"
REALM="RNV.LOCAL"
SHORT_DOMAIN="RNV"
DNS_FORWARDER="8.8.8.8"
ADMIN_USER="administrator"
SCRIPT_VERSION="4.0"
LOG_FILE="/var/log/ad_setup.log"

# ============================================
# FUNÇÕES PRINCIPAIS
# ============================================

# Função de log melhorada
log() {
    local level=$1
    shift
    local msg="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        INFO)    echo -e "${GREEN}[${timestamp}] [INFO]${NC} $msg" ;;
        WARN)    echo -e "${YELLOW}[${timestamp}] [WARN]${NC} $msg" ;;
        ERROR)   echo -e "${RED}[${timestamp}] [ERROR]${NC} $msg" ;;
        DEBUG)   echo -e "${CYAN}[${timestamp}] [DEBUG]${NC} $msg" ;;
        SUCCESS) echo -e "${BLUE}[${timestamp}] [SUCCESS]${NC} $msg" ;;
        *)       echo -e "[${timestamp}] $msg" ;;
    esac
    
    echo "[${timestamp}] [$level] $msg" >> $LOG_FILE
}

# Verificar se é root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log ERROR "Este script deve ser executado como root (sudo)"
        exit 1
    fi
}

# Detectar sistema operacional
detect_os() {
    log INFO "Detectando sistema operacional..."
    
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
        
        log INFO "Sistema: $OS $OS_VERSION"
        
        case $OS in
            ubuntu|debian)
                PKG_MANAGER="apt"
                INSTALL_CMD="apt install -y -qq"
                UPDATE_CMD="apt update -qq"
                ;;
            rocky|centos|rhel|almalinux)
                PKG_MANAGER="yum"
                INSTALL_CMD="yum install -y -q"
                UPDATE_CMD="yum update -q"
                ;;
            *)
                log ERROR "Sistema operacional não suportado: $OS"
                exit 1
                ;;
        esac
    else
        log ERROR "Não foi possível detectar o sistema operacional"
        exit 1
    fi
}

# Detectar interface de rede
detect_interface() {
    log INFO "Detectando interface de rede..."
    
    # Tentar encontrar interface com IP configurado
    INTERFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
    
    if [ -z "$INTERFACE" ]; then
        INTERFACE=$(ip link show | grep -E "^[0-9]+: (en|eth|ens|eno)" | head -1 | cut -d: -f2 | xargs)
    fi
    
    if [ -z "$INTERFACE" ]; then
        INTERFACE=$(ip link show | grep -E "^[0-9]+: " | grep -v lo | head -1 | cut -d: -f2 | xargs)
    fi
    
    if [ -z "$INTERFACE" ]; then
        log ERROR "Nenhuma interface de rede detectada"
        exit 1
    fi
    
    # Obter IP
    IP_ADDR=$(ip addr show $INTERFACE 2>/dev/null | grep inet | grep -v inet6 | awk '{print $2}' | cut -d/ -f1 | head -1)
    
    if [ -z "$IP_ADDR" ]; then
        log WARN "Não foi possível obter IP da interface $INTERFACE"
        read -p "Digite o IP do servidor: " IP_ADDR
    fi
    
    log SUCCESS "Interface: $INTERFACE | IP: $IP_ADDR"
}

# Configurar locale
configure_locale() {
    log INFO "Configurando locale..."
    
    case $PKG_MANAGER in
        apt)
            apt install -y -qq language-pack-pt locales
            locale-gen pt_BR.UTF-8
            ;;
        yum)
            yum install -y -q glibc-langpack-pt
            ;;
    esac
    
    update-locale LANG=pt_BR.UTF-8 LANGUAGE=pt_BR:pt LC_ALL=pt_BR.UTF-8
    export LANG=pt_BR.UTF-8
    export LANGUAGE=pt_BR:pt
    export LC_ALL=pt_BR.UTF-8
    
    log SUCCESS "Locale configurado"
}

# Configurar auto complete
configure_autocomplete() {
    log INFO "Configurando auto complete..."
    
    case $PKG_MANAGER in
        apt)
            apt install -y -qq bash-completion
            ;;
        yum)
            yum install -y -q bash-completion
            ;;
    esac
    
    if ! grep -q "bash-completion" /root/.bashrc; then
        cat >> /root/.bashrc << 'EOF'
if [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
fi
complete -C samba-tool samba-tool
EOF
    fi
    
    log SUCCESS "Auto complete configurado"
}

# ============================================
# FUNÇÕES DE VALIDAÇÃO
# ============================================

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

validate_ip() {
    local IP="$1"
    
    if ! echo "$IP" | grep -qE "^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"; then
        echo "IP inválido"
        return 1
    fi
    
    return 0
}

# ============================================
# FUNÇÕES DE DESCOBERTA
# ============================================

discover_domain_info() {
    log INFO "Tentando descobrir informações do domínio..."
    
    # Tentar descobrir via DNS
    if host -t SRV _ldap._tcp.$DOMAIN >/dev/null 2>&1; then
        DOMAIN_INFO=$(host -t SRV _ldap._tcp.$DOMAIN | grep -oP '(?<=server ).*?(?=\.)')
        DC_SERVER=$(echo $DOMAIN_INFO | cut -d. -f1)
        log SUCCESS "Domínio encontrado via DNS: $DOMAIN"
        log INFO "DC principal: $DC_SERVER"
        DOMAIN_DISCOVERED=1
    elif nslookup -type=SRV _ldap._tcp.$DOMAIN >/dev/null 2>&1; then
        DOMAIN_DISCOVERED=1
    else
        DOMAIN_DISCOVERED=0
        log WARN "Não foi possível descobrir o domínio automaticamente"
    fi
}

check_dc_health() {
    local DC_IP="$1"
    log INFO "Verificando saúde do DC: $DC_IP"
    
    # Testar LDAP
    if nc -zv $DC_IP 389 2>/dev/null; then
        log SUCCESS "LDAP funcionando"
        LDAP_OK=1
    else
        log WARN "LDAP não responde"
        LDAP_OK=0
    fi
    
    # Testar Kerberos
    if nc -zv $DC_IP 88 2>/dev/null; then
        log SUCCESS "Kerberos funcionando"
        KERBEROS_OK=1
    else
        log WARN "Kerberos não responde"
        KERBEROS_OK=0
    fi
    
    # Testar DNS
    if nc -zu $DC_IP 53 2>/dev/null; then
        log SUCCESS "DNS funcionando"
        DNS_OK=1
    else
        log WARN "DNS não responde"
        DNS_OK=0
    fi
}

# ============================================
# FUNÇÕES DE INSTALAÇÃO POR PAPEL
# ============================================

install_ad_primary() {
    log INFO "=== INSTALAÇÃO AD SERVER PRIMÁRIO ==="
    
    # Configurações
    read -p "Domínio (ex: EMPRESA.LOCAL): " DOMAIN
    DOMAIN=$(echo $DOMAIN | tr '[:lower:]' '[:upper:]')
    REALM=$DOMAIN
    SHORT_DOMAIN=$(echo $DOMAIN | cut -d. -f1)
    
    read -p "Hostname (ex: adserver01): " HOSTNAME
    
    # Senha do administrador
    while true; do
        read -s -p "Senha do Administrador: " ADMIN_PASSWORD
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
    
    # Configurar hostname
    hostnamectl set-hostname ${HOSTNAME}.${DOMAIN,,}
    log SUCCESS "Hostname configurado"
    
    # Configurar /etc/hosts
    cat > /etc/hosts << EOF
127.0.0.1 localhost
127.0.1.1 ${HOSTNAME}.${DOMAIN,,} ${HOSTNAME}
${IP_ADDR} ${HOSTNAME}.${DOMAIN,,} ${HOSTNAME}
EOF
    
    # Instalar pacotes
    install_samba_packages
    
    # Provisionar domínio
    log INFO "Provisionando domínio $DOMAIN..."
    
    samba-tool domain provision \
        --use-rfc2307 \
        --realm=${REALM} \
        --domain=${SHORT_DOMAIN} \
        --server-role=dc \
        --dns-backend=SAMBA_INTERNAL \
        --adminpass=${ADMIN_PASSWORD} \
        --host-ip=${IP_ADDR} \
        --option="interfaces=lo ${INTERFACE}" \
        --option="bind interfaces only=yes"
    
    if [ $? -eq 0 ]; then
        log SUCCESS "Domínio provisionado com sucesso"
    else
        log ERROR "Falha no provisionamento"
        exit 1
    fi
    
    # Configurar serviços
    configure_samba_services
    
    # Configurar Kerberos
    configure_kerberos "$DOMAIN" "$HOSTNAME"
    
    # Configurar DNS
    configure_dns
    
    # Criar usuários e grupos
    create_users_and_groups "$ADMIN_PASSWORD"
    
    # Salvar informações
    save_primary_info "$DOMAIN" "$REALM" "$HOSTNAME" "$ADMIN_PASSWORD"
    
    log SUCCESS "AD Server Primário configurado com sucesso!"
    show_summary "$DOMAIN" "$REALM" "$HOSTNAME" "$ADMIN_PASSWORD" "primary"
}

install_ad_secondary() {
    log INFO "=== INSTALAÇÃO AD SERVER SECUNDÁRIO ==="
    
    # Coletar informações do domínio
    read -p "Domínio (ex: EMPRESA.LOCAL): " DOMAIN
    DOMAIN=$(echo $DOMAIN | tr '[:lower:]' '[:upper:]')
    REALM=$DOMAIN
    SHORT_DOMAIN=$(echo $DOMAIN | cut -d. -f1)
    
    read -p "Hostname (ex: adserver02): " HOSTNAME
    
    read -p "IP do AD Primário: " PRIMARY_DC_IP
    
    # Testar conectividade com o DC primário
    log INFO "Verificando conectividade com o DC primário..."
    if ! ping -c 3 $PRIMARY_DC_IP >/dev/null 2>&1; then
        log ERROR "Não foi possível acessar o DC primário em $PRIMARY_DC_IP"
        exit 1
    fi
    
    # Perguntar se deseja replicar ou promover
    echo ""
    echo "Opções:"
    echo "1) Replicar domínio (novo DC secundário)"
    echo "2) Promover de membro para DC"
    read -p "Escolha (1/2): " REPLICA_OPTION
    
    # Senha do administrador do domínio
    read -s -p "Senha do administrador do domínio: " ADMIN_PASSWORD
    echo
    
    # Verificar autenticação
    log INFO "Verificando autenticação no domínio..."
    if ! echo "$ADMIN_PASSWORD" | kinit $ADMIN_USER@$REALM 2>/dev/null; then
        log ERROR "Falha na autenticação. Verifique senha e conectividade."
        exit 1
    fi
    kdestroy
    
    # Instalar pacotes
    install_samba_packages
    
    case $REPLICA_OPTION in
        1)
            # Replicar domínio
            log INFO "Replicando domínio do DC primário..."
            
            samba-tool domain join ${REALM} DC \
                --realm=${REALM} \
                -U${ADMIN_USER}%${ADMIN_PASSWORD} \
                --dns-backend=SAMBA_INTERNAL \
                --option="interfaces=lo ${INTERFACE}" \
                --option="bind interfaces only=yes"
            ;;
        2)
            # Promover de membro
            log INFO "Promovendo de membro para DC..."
            
            samba-tool domain join ${REALM} DC \
                --realm=${REALM} \
                -U${ADMIN_USER}%${ADMIN_PASSWORD} \
                --dns-backend=SAMBA_INTERNAL \
                --option="interfaces=lo ${INTERFACE}" \
                --option="bind interfaces only=yes"
            ;;
        *)
            log ERROR "Opção inválida"
            exit 1
            ;;
    esac
    
    if [ $? -eq 0 ]; then
        log SUCCESS "Join ao domínio realizado com sucesso"
    else
        log ERROR "Falha no join ao domínio"
        exit 1
    fi
    
    # Configurar serviços
    configure_samba_services
    
    # Configurar Kerberos
    configure_kerberos "$DOMAIN" "$HOSTNAME"
    
    # Configurar DNS
    configure_dns
    
    # Salvar informações
    save_secondary_info "$DOMAIN" "$REALM" "$HOSTNAME" "$PRIMARY_DC_IP"
    
    log SUCCESS "AD Server Secundário configurado com sucesso!"
    show_summary "$DOMAIN" "$REALM" "$HOSTNAME" "$ADMIN_PASSWORD" "secondary"
}

install_ad_tertiary() {
    log INFO "=== INSTALAÇÃO AD SERVER TERCIÁRIO (RODC) ==="
    
    # Coletar informações
    read -p "Domínio (ex: EMPRESA.LOCAL): " DOMAIN
    DOMAIN=$(echo $DOMAIN | tr '[:lower:]' '[:upper:]')
    REALM=$DOMAIN
    SHORT_DOMAIN=$(echo $DOMAIN | cut -d. -f1)
    
    read -p "Hostname (ex: adserver03): " HOSTNAME
    
    read -p "IP do AD Primário: " PRIMARY_DC_IP
    read -p "IP do AD Secundário (opcional): " SECONDARY_DC_IP
    
    # Senha do administrador
    read -s -p "Senha do administrador do domínio: " ADMIN_PASSWORD
    echo
    
    # Verificar autenticação
    log INFO "Verificando autenticação..."
    if ! echo "$ADMIN_PASSWORD" | kinit $ADMIN_USER@$REALM 2>/dev/null; then
        log ERROR "Falha na autenticação"
        exit 1
    fi
    kdestroy
    
    # Instalar pacotes
    install_samba_packages
    
    # Provisionar RODC
    log INFO "Provisionando RODC..."
    
    samba-tool domain join ${REALM} RODC \
        --realm=${REALM} \
        -U${ADMIN_USER}%${ADMIN_PASSWORD} \
        --dns-backend=SAMBA_INTERNAL \
        --option="interfaces=lo ${INTERFACE}" \
        --option="bind interfaces only=yes"
    
    if [ $? -eq 0 ]; then
        log SUCCESS "RODC configurado com sucesso"
    else
        log ERROR "Falha na configuração do RODC"
        exit 1
    fi
    
    # Configurar serviços
    configure_samba_services
    
    # Configurar Kerberos
    configure_kerberos "$DOMAIN" "$HOSTNAME"
    
    # Configurar DNS
    configure_dns
    
    log SUCCESS "AD Server Terciário (RODC) configurado com sucesso!"
    show_summary "$DOMAIN" "$REALM" "$HOSTNAME" "$ADMIN_PASSWORD" "tertiary"
}

install_file_server() {
    log INFO "=== INSTALAÇÃO FILE SERVER ==="
    
    # Coletar informações
    read -p "Domínio (ex: EMPRESA.LOCAL): " DOMAIN
    DOMAIN=$(echo $DOMAIN | tr '[:lower:]' '[:upper:]')
    REALM=$DOMAIN
    
    read -p "Hostname (ex: fileserver01): " HOSTNAME
    
    read -p "IP do AD Server: " AD_SERVER_IP
    
    # Senha do administrador
    read -s -p "Senha do administrador do domínio: " ADMIN_PASSWORD
    echo
    
    # Verificar autenticação
    log INFO "Verificando autenticação no domínio..."
    if ! echo "$ADMIN_PASSWORD" | kinit $ADMIN_USER@$REALM 2>/dev/null; then
        log ERROR "Falha na autenticação"
        exit 1
    fi
    kdestroy
    
    # Configurar hostname
    hostnamectl set-hostname ${HOSTNAME}.${DOMAIN,,}
    log SUCCESS "Hostname configurado"
    
    # Configurar /etc/hosts
    cat > /etc/hosts << EOF
127.0.0.1 localhost
127.0.1.1 ${HOSTNAME}.${DOMAIN,,} ${HOSTNAME}
${IP_ADDR} ${HOSTNAME}.${DOMAIN,,} ${HOSTNAME}
${AD_SERVER_IP} adserver01.${DOMAIN,,} adserver01
EOF
    
    # Instalar pacotes
    log INFO "Instalando pacotes do File Server..."
    case $PKG_MANAGER in
        apt)
            apt update -qq
            apt install -y -qq samba smbclient cifs-utils \
                winbind libpam-winbind libnss-winbind \
                nfs-common nfs-kernel-server
            ;;
        yum)
            yum update -q
            yum install -y -q samba samba-client samba-common \
                cifs-utils nfs-utils
            ;;
    esac
    
    # Joinar ao domínio
    log INFO "Juntando ao domínio $DOMAIN..."
    
    samba-tool domain join ${REALM} MEMBER \
        -U${ADMIN_USER}%${ADMIN_PASSWORD}
    
    if [ $? -eq 0 ]; then
        log SUCCESS "Membro do domínio configurado"
    else
        log ERROR "Falha no join ao domínio"
        exit 1
    fi
    
    # Configurar Samba para File Server
    cat > /etc/samba/smb.conf << EOF
[global]
    workgroup = ${SHORT_DOMAIN}
    realm = ${REALM}
    security = ADS
    kerberos method = system keytab
    server string = File Server %h
    netbios name = ${HOSTNAME^^}
    
    # Winbind
    winbind use default domain = yes
    winbind offline logon = false
    winbind enum users = yes
    winbind enum groups = yes
    winbind refresh tickets = yes
    winbind cache time = 300
    
    # ID Mapping
    idmap config * : backend = tdb
    idmap config * : range = 100000-199999
    idmap config ${SHORT_DOMAIN} : backend = rid
    idmap config ${SHORT_DOMAIN} : range = 200000-299999
    
    # Logs
    log level = 2
    max log size = 1000
    
    # Protocols
    server signing = auto
    client signing = auto
    server min protocol = SMB2_02
    
    # Performance
    server multi channel support = yes
    aio read size = 1
    aio write size = 1
    vfs objects = dfs_sam4
    
    # Home directories
    template shell = /bin/bash
    template homedir = /home/%D/%U

# Compartilhamentos
[homes]
    comment = Home Directories
    browseable = no
    writable = yes
    create mask = 0700
    directory mask = 0700
    valid users = %S

[public]
    comment = Public Share
    path = /srv/samba/public
    browseable = yes
    read only = no
    guest ok = yes
    create mask = 0666
    directory mask = 0777

[shared]
    comment = Shared Files
    path = /srv/samba/shared
    browseable = yes
    read only = no
    guest ok = no
    valid users = @"Domain Users"
    create mask = 0664
    directory mask = 0775
EOF
    
    # Criar diretórios
    mkdir -p /srv/samba/public
    mkdir -p /srv/samba/shared
    
    chown -R root:"domain users" /srv/samba/shared
    chmod 2775 /srv/samba/shared
    chmod 1777 /srv/samba/public
    
    # Configurar Kerberos
    configure_kerberos "$DOMAIN" "$HOSTNAME"
    
    # Iniciar serviços
    systemctl enable smbd nmbd winbind
    systemctl restart smbd nmbd winbind
    
    log SUCCESS "File Server configurado com sucesso!"
    echo ""
    echo "Compartilhamentos criados:"
    echo "  - \\\\${HOSTNAME}\\public (acesso público)"
    echo "  - \\\\${HOSTNAME}\\shared (acesso apenas usuários do domínio)"
    echo "  - \\\\${HOSTNAME}\\username (home directory do usuário)"
}

join_domain_only() {
    log INFO "=== JOIN AO DOMÍNIO ==="
    
    # Coletar informações
    read -p "Domínio (ex: EMPRESA.LOCAL): " DOMAIN
    DOMAIN=$(echo $DOMAIN | tr '[:lower:]' '[:upper:]')
    REALM=$DOMAIN
    SHORT_DOMAIN=$(echo $DOMAIN | cut -d. -f1)
    
    read -p "Hostname (ex: workstation01): " HOSTNAME
    
    read -p "IP do AD Server: " AD_SERVER_IP
    
    # Senha do administrador
    read -s -p "Senha do administrador do domínio: " ADMIN_PASSWORD
    echo
    
    # Configurar hostname
    hostnamectl set-hostname ${HOSTNAME}.${DOMAIN,,}
    log SUCCESS "Hostname configurado"
    
    # Configurar /etc/hosts
    cat > /etc/hosts << EOF
127.0.0.1 localhost
127.0.1.1 ${HOSTNAME}.${DOMAIN,,} ${HOSTNAME}
${IP_ADDR} ${HOSTNAME}.${DOMAIN,,} ${HOSTNAME}
${AD_SERVER_IP} adserver01.${DOMAIN,,} adserver01
EOF
    
    # Configurar DNS
    echo "nameserver ${AD_SERVER_IP}" > /etc/resolv.conf
    echo "search ${DOMAIN,,}" >> /etc/resolv.conf
    echo "domain ${DOMAIN,,}" >> /etc/resolv.conf
    
    # Instalar pacotes
    log INFO "Instalando pacotes para join ao domínio..."
    case $PKG_MANAGER in
        apt)
            apt update -qq
            apt install -y -qq samba smbclient cifs-utils \
                winbind libpam-winbind libnss-winbind
            ;;
        yum)
            yum update -q
            yum install -y -q samba samba-client samba-common \
                samba-winbind cifs-utils
            ;;
    esac
    
    # Joinar ao domínio
    log INFO "Juntando ao domínio $DOMAIN..."
    
    echo "$ADMIN_PASSWORD" | net ads join -U$ADMIN_USER
    
    if [ $? -eq 0 ]; then
        log SUCCESS "Membro do domínio configurado"
    else
        log ERROR "Falha no join ao domínio"
        exit 1
    fi
    
    # Configurar winbind
    configure_winbind "$DOMAIN"
    
    log SUCCESS "Máquina adicionada ao domínio com sucesso!"
}

# ============================================
# FUNÇÕES AUXILIARES
# ============================================

install_samba_packages() {
    log INFO "Instalando pacotes do Samba AD..."
    
    case $PKG_MANAGER in
        apt)
            DEBIAN_FRONTEND=noninteractive apt install -y -qq \
                acl attr samba samba-dsdb-modules \
                samba-vfs-modules winbind libpam-winbind \
                libnss-winbind kinit krb5-user dnsutils \
                bind9utils ldap-utils bash-completion \
                ntp chrony
            ;;
        yum)
            yum install -y -q samba samba-client samba-common \
                samba-dc samba-dc-dns samba-winbind \
                krb5-workstation bind-utils \
                ntp ntpdate
            ;;
    esac
    
    # Parar serviços conflitantes
    systemctl stop smbd nmbd winbind 2>/dev/null || true
    systemctl disable smbd nmbd winbind 2>/dev/null || true
    
    log SUCCESS "Pacotes instalados"
}

configure_samba_services() {
    log INFO "Configurando serviços do Samba..."
    
    systemctl unmask samba-ad-dc 2>/dev/null || true
    systemctl enable samba-ad-dc 2>/dev/null || true
    systemctl restart samba-ad-dc
    
    log SUCCESS "Serviços configurados"
}

configure_kerberos() {
    local DOMAIN="$1"
    local HOSTNAME="$2"
    
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
    
    log SUCCESS "DNS configurado"
}

configure_winbind() {
    local DOMAIN="$1"
    local SHORT_DOMAIN=$(echo $DOMAIN | cut -d. -f1)
    
    log INFO "Configurando winbind..."
    
    cat > /etc/samba/smb.conf << EOF
[global]
    workgroup = ${SHORT_DOMAIN}
    realm = ${DOMAIN}
    security = ADS
    kerberos method = system keytab
    
    winbind use default domain = yes
    winbind offline logon = false
    winbind enum users = yes
    winbind enum groups = yes
    winbind refresh tickets = yes
    
    idmap config * : backend = tdb
    idmap config * : range = 100000-199999
    idmap config ${SHORT_DOMAIN} : backend = rid
    idmap config ${SHORT_DOMAIN} : range = 200000-299999
    
    template shell = /bin/bash
    template homedir = /home/%D/%U
EOF
    
    # Configurar NSS
    if [ -f /etc/nsswitch.conf ]; then
        sed -i 's/^\(passwd:.*\)/\1 winbind/' /etc/nsswitch.conf
        sed -i 's/^\(group:.*\)/\1 winbind/' /etc/nsswitch.conf
    fi
    
    # Iniciar serviços
    systemctl enable winbind nmbd smbd
    systemctl restart winbind nmbd smbd
    
    log SUCCESS "Winbind configurado"
}

create_users_and_groups() {
    local ADMIN_PASSWORD="$1"
    
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

save_primary_info() {
    local DOMAIN="$1"
    local REALM="$2"
    local HOSTNAME="$3"
    local ADMIN_PASSWORD="$4"
    
    cat > /root/ad_info.txt << EOF
═══════════════════════════════════════════════════════════════════
                    AD SERVER PRIMÁRIO
═══════════════════════════════════════════════════════════════════

DOMÍNIO: ${DOMAIN}
REALM: ${REALM}
HOSTNAME: ${HOSTNAME}
IP: ${IP_ADDR}
INTERFACE: ${INTERFACE}
DATA: $(date)

───────────────────────────────────────────────────────────────────
USUÁRIOS
───────────────────────────────────────────────────────────────────
Administrador: administrator@${REALM}
Senha: ${ADMIN_PASSWORD}

Usuário Secundário: admin2@${REALM}
Senha: ${ADMIN_PASSWORD}

───────────────────────────────────────────────────────────────────
COMANDOS ÚTEIS
───────────────────────────────────────────────────────────────────
# Testar Kerberos
echo '${ADMIN_PASSWORD}' | kinit administrator@${REALM}

# Verificar ticket
klist

# Listar usuários
samba-tool user list

# Listar grupos
samba-tool group list

# DNS Test
host -t SRV _ldap._tcp.${DOMAIN,,}

───────────────────────────────────────────────────────────────────
LOGS
───────────────────────────────────────────────────────────────────
/var/log/samba/log.samba
/var/log/krb5kdc.log
/var/log/samba/log.winbind
EOF
    
    chmod 600 /root/ad_info.txt
}

save_secondary_info() {
    local DOMAIN="$1"
    local REALM="$2"
    local HOSTNAME="$3"
    local PRIMARY_DC_IP="$4"
    
    cat > /root/ad_secondary_info.txt << EOF
═══════════════════════════════════════════════════════════════════
                    AD SERVER SECUNDÁRIO
═══════════════════════════════════════════════════════════════════

DOMÍNIO: ${DOMAIN}
REALM: ${REALM}
HOSTNAME: ${HOSTNAME}
IP: ${IP_ADDR}
INTERFACE: ${INTERFACE}
PRIMARY DC: ${PRIMARY_DC_IP}
DATA: $(date)

───────────────────────────────────────────────────────────────────
COMANDOS ÚTEIS
───────────────────────────────────────────────────────────────────
# Verificar replicação
samba-tool drs showrepl

# Forçar replicação
samba-tool drs replicate ${HOSTNAME} adserver01 ${DOMAIN}

───────────────────────────────────────────────────────────────────
LOGS
───────────────────────────────────────────────────────────────────
/var/log/samba/log.samba
/var/log/samba/log.winbind
EOF
    
    chmod 600 /root/ad_secondary_info.txt
}

show_summary() {
    local DOMAIN="$1"
    local REALM="$2"
    local HOSTNAME="$3"
    local ADMIN_PASSWORD="$4"
    local ROLE="$5"
    
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
    echo -e "  ${GREEN}✓${NC} Papel: ${CYAN}$ROLE${NC}"
    echo -e "  ${GREEN}✓${NC} Domínio: ${CYAN}${DOMAIN}${NC}"
    echo -e "  ${GREEN}✓${NC} Hostname: ${CYAN}${HOSTNAME}.${DOMAIN,,}${NC}"
    echo -e "  ${GREEN}✓${NC} IP: ${CYAN}${IP_ADDR}${NC}"
    echo -e "  ${GREEN}✓${NC} Interface: ${CYAN}${INTERFACE}${NC}"
    
    if [ "$ROLE" = "primary" ]; then
        echo ""
        echo -e "${YELLOW}📌 CREDENCIAIS DE ACESSO:${NC}"
        echo ""
        echo -e "  Usuário: ${CYAN}administrator@${REALM}${NC}"
        echo -e "  Senha: ${CYAN}${ADMIN_PASSWORD}${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}💡 DICAS:${NC}"
    echo -e "  ✅ Use TAB para auto completar comandos"
    echo -e "  ✅ Sistema em Português Brasil"
    echo -e "  ✅ Arquivo de informações: ${CYAN}/root/ad_info.txt${NC}"
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
}

# ============================================
# FUNÇÃO PRINCIPAL
# ============================================

main_menu() {
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
    
    echo -e "${YELLOW}Selecione o papel do servidor:${NC}"
    echo ""
    echo "  ${GREEN}1)${NC} AD Server ${BLUE}PRIMÁRIO${NC} - Novo domínio"
    echo "  ${GREEN}2)${NC} AD Server ${BLUE}SECUNDÁRIO${NC} - Replicação do domínio"
    echo "  ${GREEN}3)${NC} AD Server ${BLUE}TERCIÁRIO/RODC${NC} - Controlador somente leitura"
    echo "  ${GREEN}4)${NC} ${BLUE}File Server${NC} - Servidor de arquivos integrado ao domínio"
    echo "  ${GREEN}5)${NC} ${BLUE}Join Domain${NC} - Apenas adicionar ao domínio"
    echo "  ${GREEN}6)${NC} ${RED}Sair${NC}"
    echo ""
    read -p "Escolha uma opção (1-6): " OPTION
    
    case $OPTION in
        1) install_ad_primary ;;
        2) install_ad_secondary ;;
        3) install_ad_tertiary ;;
        4) install_file_server ;;
        5) join_domain_only ;;
        6) echo "Saindo..."; exit 0 ;;
        *) log ERROR "Opção inválida"; sleep 2; main_menu ;;
    esac
}

# ============================================
# INÍCIO DO SCRIPT
# ============================================

# Limpar log anterior
> $LOG_FILE

# Verificações iniciais
check_root
detect_os
detect_interface
configure_locale
configure_autocomplete

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
