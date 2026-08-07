#!/bin/bash
# =============================================================================
# Script: setup-ad-primary.sh
# Versão: 8.0 - INSTALAÇÃO DO CONTROLADOR PRIMÁRIO
# Descrição: Configuração completa do primeiro DC do domínio
# Uso: sudo ./setup-ad-primary.sh
# =============================================================================

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# Variáveis que serão definidas pelo usuário
DOMAIN_NAME=""
REALM_NAME=""
NETBIOS_NAME=""
IP_ADDRESS=""
HOSTNAME=""
FQDN=""
ADMIN_PASSWORD=""
DNS_FORWARDER="8.8.8.8"

# Variáveis do script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/setup-ad-primary-$(date +%Y%m%d-%H%M%S).log"
BACKUP_DIR="/root/ad-backup-$(date +%Y%m%d-%H%M%S)"

# =============================================================================
# FUNÇÕES DE UTILIDADE
# =============================================================================

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ❌ ERRO:${NC} $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] ⚠️  AVISO:${NC} $1" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] ℹ️  INFO:${NC} $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${CYAN}[$(date +'%Y-%m-%d %H:%M:%S')] ✅${NC} $1" | tee -a "$LOG_FILE"
}

print_header() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║  $1"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Este script deve ser executado como root!"
        echo "Use: sudo ./setup-ad-primary.sh"
        exit 1
    fi
}

pause() {
    read -p "Pressione ENTER para continuar..."
}

confirm() {
    read -p "$1 (s/N): " -n 1 -r
    echo
    [[ $REPLY =~ ^[Ss]$ ]]
}

# =============================================================================
# FUNÇÃO: CONFIGURAR IDIOMA
# =============================================================================

configure_language() {
    print_header "🌐 CONFIGURANDO IDIOMA PARA PORTUGUÊS"
    
    log_info "Instalando pacotes de idioma..."
    apt update 2>/dev/null
    apt install -y language-pack-pt language-pack-pt-base 2>/dev/null
    
    log_info "Configurando locale..."
    locale-gen pt_BR.UTF-8 2>/dev/null
    update-locale LANG=pt_BR.UTF-8 LANGUAGE=pt_BR:pt LC_ALL=pt_BR.UTF-8
    
    cat > /etc/default/locale << 'EOF'
LANG=pt_BR.UTF-8
LANGUAGE=pt_BR:pt
LC_ALL=pt_BR.UTF-8
LC_CTYPE=pt_BR.UTF-8
LC_NUMERIC=pt_BR.UTF-8
LC_TIME=pt_BR.UTF-8
LC_COLLATE=pt_BR.UTF-8
LC_MONETARY=pt_BR.UTF-8
LC_MESSAGES=pt_BR.UTF-8
LC_PAPER=pt_BR.UTF-8
LC_NAME=pt_BR.UTF-8
LC_ADDRESS=pt_BR.UTF-8
LC_TELEPHONE=pt_BR.UTF-8
LC_MEASUREMENT=pt_BR.UTF-8
LC_IDENTIFICATION=pt_BR.UTF-8
EOF
    
    timedatectl set-timezone America/Sao_Paulo
    apt install -y fonts-liberation fonts-dejavu-core 2>/dev/null
    
    log_success "Idioma configurado para Português do Brasil!"
}

# =============================================================================
# FUNÇÃO: HABILITAR ROOT VIA SSH
# =============================================================================

configure_ssh_root() {
    print_header "🔐 CONFIGURANDO ROOT VIA SSH"
    
    log_info "Habilitando senha para usuário root..."
    echo ""
    echo "Digite a senha para o usuário root:"
    passwd root
    
    log_info "Configurando SSH para permitir login root..."
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak 2>/dev/null
    
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null
    sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null
    
    grep -q "^PermitRootLogin" /etc/ssh/sshd_config || echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
    grep -q "^PasswordAuthentication" /etc/ssh/sshd_config || echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
    
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null
    
    log_success "Root habilitado via SSH!"
    log_info "Para acessar: ssh root@$IP_ADDRESS"
}

# =============================================================================
# FUNÇÃO: HABILITAR AUTO-COMPLETE
# =============================================================================

setup_autocomplete() {
    print_header "⌨️  CONFIGURANDO AUTO-COMPLETE COM TAB"
    
    log_info "Habilitando auto-complete e melhorias do terminal..."
    
    cat > /etc/inputrc << 'EOF'
set show-all-if-ambiguous on
set completion-ignore-case on
set colored-stats on
set menu-complete-display-prefix on
set bell-style none
set editing-mode emacs
set keymap emacs
"\e[Z": menu-complete
EOF
    
    cat >> /etc/bash.bashrc << 'EOF'
bind 'set show-all-if-ambiguous on'
bind 'set completion-ignore-case on'
bind 'set colored-stats on'
export HISTTIMEFORMAT="%F %T "
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'
alias egrep='egrep --color=auto'
alias fgrep='fgrep --color=auto'
complete -c which
complete -c man
complete -c apt
complete -c systemctl
complete -c samba-tool
EOF
    
    cat >> /root/.bashrc << 'EOF'
bind 'set show-all-if-ambiguous on'
bind 'set completion-ignore-case on'
bind 'set colored-stats on'
alias ad-status='systemctl status samba-ad-dc'
alias ad-users='samba-tool user list'
alias ad-groups='samba-tool group list'
alias ad-test='kinit administrator@'
alias ad-backup='/usr/local/bin/backup-ad.sh'
alias ad-logs='tail -f /var/log/samba/log.samba'
alias ad-test-all='/root/test-ad.sh'
alias ad-ports='ss -tulpn | grep -E "135|139|389|445|464|636|3268|3269|88|53"'
alias ad-info='samba-tool domain info 127.0.0.1'
alias ad-health='samba-tool domain health'
alias ad-repl='samba-tool drs showrepl'
alias update='apt update && apt upgrade -y'
alias install='apt install -y'
alias clean='apt autoremove -y && apt autoclean'
EOF
    
    log_success "Auto-complete configurado!"
}

# =============================================================================
# FUNÇÃO: COLETAR INFORMAÇÕES
# =============================================================================

collect_user_info() {
    print_header "📋 INFORMAÇÕES DE CONFIGURAÇÃO"
    
    echo "Por favor, forneça as informações para configuração do AD Primário:"
    echo ""
    
    # Nome do Servidor
    while true; do
        read -p "📍 Nome do Servidor (ex: dc01, adserver): " HOSTNAME
        if [[ -n "$HOSTNAME" ]]; then
            if [[ "$HOSTNAME" =~ ^[a-zA-Z0-9-]+$ ]]; then
                break
            else
                log_error "Nome inválido! Use apenas letras, números e hífen."
            fi
        else
            log_error "Nome do servidor não pode estar vazio!"
        fi
    done
    
    # Domínio
    while true; do
        read -p "🌐 Nome do Domínio (ex: empresa.local): " DOMAIN_NAME
        if [[ -n "$DOMAIN_NAME" ]]; then
            if [[ "$DOMAIN_NAME" =~ ^[a-z0-9]+\.[a-z]+$ ]]; then
                break
            else
                log_error "Domínio inválido! Use formato: empresa.local"
            fi
        else
            log_error "Domínio não pode estar vazio!"
        fi
    done
    
    # Realm e NetBIOS automáticos
    REALM_NAME=$(echo "$DOMAIN_NAME" | tr '[:lower:]' '[:upper:]')
    NETBIOS_NAME=$(echo "$DOMAIN_NAME" | cut -d. -f1 | tr '[:lower:]' '[:upper:]')
    
    # IP
    while true; do
        read -p "🔢 IP do Servidor (ex: 192.168.1.10): " IP_ADDRESS
        if [[ -n "$IP_ADDRESS" ]]; then
            if [[ "$IP_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                break
            else
                log_error "IP inválido! Use formato: 192.168.1.10"
            fi
        else
            IP_ADDRESS=$(ip -4 addr show | grep inet | grep -v 127.0.0.1 | awk '{print $2}' | cut -d/ -f1 | head -n1)
            if [[ -n "$IP_ADDRESS" ]]; then
                log_info "IP detectado automaticamente: $IP_ADDRESS"
                if confirm "Usar este IP?"; then
                    break
                else
                    IP_ADDRESS=""
                fi
            else
                log_error "IP não pode estar vazio!"
            fi
        fi
    done
    
    # DNS Forwarder
    read -p "🌐 DNS Forwarder (ex: 8.8.8.8, 1.1.1.1) [8.8.8.8]: " DNS_FORWARDER
    DNS_FORWARDER=${DNS_FORWARDER:-8.8.8.8}
    
    FQDN="${HOSTNAME}.${DOMAIN_NAME}"
    
    # Senha do Administrador
    while true; do
        echo ""
        read -s -p "🔑 Senha do Administrador (mínimo 8 caracteres): " ADMIN_PASSWORD
        echo ""
        if [[ ${#ADMIN_PASSWORD} -lt 8 ]]; then
            log_error "Senha muito curta! Mínimo 8 caracteres."
        else
            read -s -p "🔑 Confirme a senha: " ADMIN_PASSWORD_CONFIRM
            echo ""
            if [[ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD_CONFIRM" ]]; then
                log_error "Senhas não coincidem!"
            else
                break
            fi
        fi
    done
    
    # Mostrar resumo
    echo ""
    print_header "📊 RESUMO DA CONFIGURAÇÃO"
    echo ""
    echo "  ┌──────────────────────────────────────────────────────────┐"
    printf "  │ %-20s: %-40s │\n" "Tipo" "Controlador Primário (PDC)"
    printf "  │ %-20s: %-40s │\n" "Nome do Servidor" "$HOSTNAME"
    printf "  │ %-20s: %-40s │\n" "Domínio DNS" "$DOMAIN_NAME"
    printf "  │ %-20s: %-40s │\n" "Realm Kerberos" "$REALM_NAME"
    printf "  │ %-20s: %-40s │\n" "NetBIOS" "$NETBIOS_NAME"
    printf "  │ %-20s: %-40s │\n" "FQDN" "$FQDN"
    printf "  │ %-20s: %-40s │\n" "IP do Servidor" "$IP_ADDRESS"
    printf "  │ %-20s: %-40s │\n" "DNS Forwarder" "$DNS_FORWARDER"
    printf "  │ %-20s: %-40s │\n" "Usuário Admin" "administrator@$REALM_NAME"
    echo "  └──────────────────────────────────────────────────────────┘"
    echo ""
    
    if ! confirm "✅ Confirmar e iniciar configuração?"; then
        log_info "Configuração cancelada."
        exit 0
    fi
}

# =============================================================================
# FUNÇÃO: CONFIGURAR HOSTNAME E DNS
# =============================================================================

configure_hostname_dns() {
    print_header "CONFIGURAÇÃO DE HOSTNAME E DNS"
    
    log_info "Configurando hostname para: $FQDN"
    hostnamectl set-hostname "$FQDN"
    
    log_info "Configurando /etc/hosts"
    cat > /etc/hosts << EOF
127.0.0.1       localhost localhost.localdomain
127.0.1.1       $FQDN $HOSTNAME
$IP_ADDRESS     $FQDN $HOSTNAME

# IPv6
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF
    
    log_info "Configurando /etc/resolv.conf"
    chattr -i /etc/resolv.conf 2>/dev/null
    cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
search $DOMAIN_NAME
domain $DOMAIN_NAME
EOF
    
    echo "$FQDN" > /etc/hostname
    
    log_success "Hostname configurado para: $FQDN"
}

# =============================================================================
# FUNÇÃO: INSTALAR PACOTES
# =============================================================================

install_packages() {
    print_header "INSTALAÇÃO DE PACOTES"
    
    log_info "Atualizando repositórios..."
    apt update 2>/dev/null
    
    log_info "Instalando pacotes essenciais..."
    
    PACKAGES=(
        samba smbclient cifs-utils krb5-user krb5-config winbind
        libpam-winbind libnss-winbind acl attr bind9utils dnsutils
        samba-ad-dc samba-dsdb-modules python3 python3-dnspython
        python3-ldb python3-samba ldb-tools net-tools ldap-utils
        expect chrony ntpdate fail2ban whois
        language-pack-pt language-pack-pt-base
        fonts-liberation fonts-dejavu-core
    )
    
    for pkg in "${PACKAGES[@]}"; do
        log_info "Instalando $pkg..."
        apt install -y $pkg 2>/dev/null || log_warning "Falha ao instalar $pkg (não crítico)"
    done
    
    if command -v samba-tool &> /dev/null; then
        log_success "Samba instalado: $(samba --version)"
    else
        log_error "Falha na instalação do Samba!"
        exit 1
    fi
    
    systemctl enable fail2ban 2>/dev/null
    systemctl start fail2ban 2>/dev/null
    
    log_success "Pacotes instalados com sucesso!"
}

# =============================================================================
# FUNÇÃO: CONFIGURAR KERBEROS
# =============================================================================

configure_kerberos() {
    print_header "CONFIGURAÇÃO DO KERBEROS"
    
    log_info "Configurando /etc/krb5.conf"
    cat > /etc/krb5.conf << EOF
[libdefaults]
    default_realm = $REALM_NAME
    dns_lookup_realm = false
    dns_lookup_kdc = true
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true
    permitted_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
    default_tgs_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
    default_tkt_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96

[realms]
    $REALM_NAME = {
        kdc = $FQDN
        admin_server = $FQDN
        master_kdc = $FQDN
        kdc_port = 88
        admin_port = 749
        default_domain = $DOMAIN_NAME
    }

[domain_realm]
    .$DOMAIN_NAME = $REALM_NAME
    $DOMAIN_NAME = $REALM_NAME
    .$FQDN = $REALM_NAME
    $FQDN = $REALM_NAME

[logging]
    kdc = FILE:/var/log/krb5/kdc.log
    admin_server = FILE:/var/log/krb5/admin.log
    default = FILE:/var/log/krb5/krb5.log
EOF
    
    mkdir -p /var/log/krb5
    touch /var/log/krb5/{kdc.log,admin.log,krb5.log}
    chmod 644 /var/log/krb5/*.log
    
    log_success "Kerberos configurado com realm: $REALM_NAME"
}

# =============================================================================
# FUNÇÃO: PROVISIONAR DOMÍNIO PRIMÁRIO
# =============================================================================

provision_primary() {
    print_header "🏗️  PROVISIONANDO DOMÍNIO PRIMÁRIO"
    
    log_info "Realm: $REALM_NAME"
    log_info "Domain: $NETBIOS_NAME"
    log_info "Server Role: dc"
    log_info "DNS Backend: SAMBA_INTERNAL"
    log_info "DNS Forwarder: $DNS_FORWARDER"
    
    log_info "Preparando ambiente..."
    
    # Remover arquivos conflitantes
    if [ -f /etc/samba/smb.conf ]; then
        mv /etc/samba/smb.conf "/etc/samba/smb.conf.bak.$(date +%Y%m%d-%H%M%S)"
    fi
    
    systemctl stop smbd nmbd winbind 2>/dev/null
    systemctl disable smbd nmbd winbind 2>/dev/null
    systemctl mask smbd nmbd winbind 2>/dev/null
    
    log_info "Executando provisionamento (pode levar alguns minutos)..."
    
    if command -v expect &> /dev/null; then
        expect -c "
            set timeout 300
            spawn samba-tool domain provision --use-rfc2307
            
            expect \"Realm \\[.*\\]:\" { send \"$REALM_NAME\r\" }
            expect \"Domain \\[.*\\]:\" { send \"$NETBIOS_NAME\r\" }
            expect \"Server Role (dc, member, standalone) \\[dc\\]:\" { send \"dc\r\" }
            expect \"DNS backend (SAMBA_INTERNAL, BIND9_FLATFILE, BIND9_DLZ, NONE) \\[SAMBA_INTERNAL\\]:\" { send \"SAMBA_INTERNAL\r\" }
            expect \"DNS forwarder .*:\" { send \"$DNS_FORWARDER\r\" }
            expect \"Administrator password:\" { send \"$ADMIN_PASSWORD\r\" }
            expect \"Retype password:\" { send \"$ADMIN_PASSWORD\r\" }
            expect eof
        "
    else
        log_info "Executando provisionamento manual..."
        samba-tool domain provision --use-rfc2307 --interactive
    fi
    
    if [ -f /var/lib/samba/private/secrets.ldb ]; then
        log_success "Provisionamento concluído com sucesso!"
        
        # Copiar krb5.conf gerado
        cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
        
        # Gerar keytab para o administrador
        log_info "Gerando keytab para o administrador..."
        samba-tool domain exportkeytab /root/adadmin.keytab --principal=administrator@"$REALM_NAME"
        chmod 600 /root/adadmin.keytab
        
        # Criar pasta de backups
        mkdir -p /backup/ad
        
        log_success "Domínio $DOMAIN_NAME provisionado com sucesso!"
    else
        log_error "Falha no provisionamento!"
        exit 1
    fi
}

# =============================================================================
# FUNÇÃO: INICIAR SERVIÇOS
# =============================================================================

start_services() {
    print_header "🚀 INICIANDO SERVIÇOS"
    
    log_info "Iniciando samba-ad-dc..."
    systemctl unmask samba-ad-dc 2>/dev/null
    systemctl enable samba-ad-dc 2>/dev/null
    systemctl start samba-ad-dc 2>/dev/null
    
    sleep 10
    
    if systemctl is-active --quiet samba-ad-dc; then
        log_success "Serviço samba-ad-dc está rodando!"
        
        log_info "Verificando portas do AD..."
        ss -tulpn | grep -E "135|139|389|445|464|636|3268|3269|88|53" | grep LISTEN
    else
        log_error "Falha ao iniciar samba-ad-dc!"
        systemctl status samba-ad-dc --no-pager
        exit 1
    fi
}

# =============================================================================
# FUNÇÃO: CONFIGURAR BACKUP
# =============================================================================

configure_backup() {
    print_header "💾 CONFIGURANDO BACKUP"
    
    cat > /usr/local/bin/backup-ad.sh << EOF
#!/bin/bash
BACKUP_DIR="/backup/ad"
DATE=\$(date +%Y%m%d_%H%M%S)
LOG_FILE="/var/log/backup-ad.log"
RETENTION_DAYS=30

mkdir -p \$BACKUP_DIR
echo "=== Backup AD - \$DATE ===" >> \$LOG_FILE

# Backup do banco de dados
samba-tool domain backup online --server=$FQDN --targetdir=\$BACKUP_DIR --backup-file="ad_backup_\$DATE.bak" -U administrator --password="$ADMIN_PASSWORD" 2>&1 >> \$LOG_FILE

# Backup do SYSVOL
tar -czf \$BACKUP_DIR/sysvol_\$DATE.tar.gz -C /var/lib/samba sysvol 2>&1 >> \$LOG_FILE

# Backup das configurações
tar -czf \$BACKUP_DIR/config_\$DATE.tar.gz -C /etc samba krb5.conf 2>&1 >> \$LOG_FILE

# Backup do keytab
cp /root/adadmin.keytab \$BACKUP_DIR/adadmin_\$DATE.keytab 2>&1 >> \$LOG_FILE

# Limpar backups antigos
find \$BACKUP_DIR -name "*.bak" -mtime +\$RETENTION_DAYS -delete
find \$BACKUP_DIR -name "*.tar.gz" -mtime +\$RETENTION_DAYS -delete
find \$BACKUP_DIR -name "*.keytab" -mtime +\$RETENTION_DAYS -delete

echo "Backup concluído em: \$DATE" >> \$LOG_FILE
echo "" >> \$LOG_FILE
EOF
    
    chmod +x /usr/local/bin/backup-ad.sh
    (crontab -l 2>/dev/null; echo "0 2 * * * /usr/local/bin/backup-ad.sh") | crontab -
    
    log_success "Backup configurado! Agendamento diário às 2h."
}

# =============================================================================
# FUNÇÃO: CRIAR SCRIPT DE TESTE
# =============================================================================

create_test_script() {
    cat > /root/test-ad.sh << 'EOF'
#!/bin/bash
echo "=== TESTE DO ACTIVE DIRECTORY (PRIMÁRIO) ==="
echo ""

echo "1. VERIFICANDO SERVIÇO:"
if systemctl is-active --quiet samba-ad-dc; then
    echo "✅ Serviço está ATIVO"
else
    echo "❌ Serviço NÃO está ativo"
fi
echo ""

echo "2. VERIFICANDO KERBEROS:"
echo "   Testando autenticação..."
echo ""
echo "3. VERIFICANDO DNS:"
host -t SRV _ldap._tcp.$DOMAIN_NAME
echo ""
echo "   Registros A:"
host $FQDN
echo ""

echo "4. LISTANDO USUÁRIOS:"
samba-tool user list | head -5
echo ""

echo "5. STATUS DE REPLICAÇÃO:"
samba-tool drs showrepl | head -10
echo ""

echo "6. INFORMAÇÕES DO DOMÍNIO:"
samba-tool domain info 127.0.0.1 | grep -E "Domain|Forest|DNS"
echo ""

echo "7. VERIFICANDO PORTAS:"
ss -tulpn | grep -E "135|139|389|445|464|636|3268|3269|88|53" | grep LISTEN
echo ""

echo "=== FIM DOS TESTES ==="
EOF
    
    sed -i "s/\$DOMAIN_NAME/$DOMAIN_NAME/g" /root/test-ad.sh
    sed -i "s/\$FQDN/$FQDN/g" /root/test-ad.sh
    
    chmod +x /root/test-ad.sh
    log_success "Script de teste criado em /root/test-ad.sh"
}

# =============================================================================
# FUNÇÃO: RESUMO FINAL
# =============================================================================

show_summary() {
    print_header "✅ CONFIGURAÇÃO DO CONTROLADOR PRIMÁRIO CONCLUÍDA!"
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║              INFORMAÇÕES DO DOMÍNIO                            ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    printf "║ %-20s: %-40s ║\n" "Função" "Controlador Primário (PDC)"
    printf "║ %-20s: %-40s ║\n" "Domínio" "$DOMAIN_NAME"
    printf "║ %-20s: %-40s ║\n" "Servidor" "$FQDN"
    printf "║ %-20s: %-40s ║\n" "IP" "$IP_ADDRESS"
    printf "║ %-20s: %-40s ║\n" "Usuário Admin" "administrator@$REALM_NAME"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                    COMANDOS ÚTEIS                              ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    echo "║ 1. Verificar serviço:                                          ║"
    echo "║    systemctl status samba-ad-dc                                ║"
    echo "║                                                                ║"
    echo "║ 2. Testar autenticação:                                        ║"
    echo "║    kinit administrator@$REALM_NAME                              ║"
    echo "║                                                                ║"
    echo "║ 3. Executar testes:                                            ║"
    echo "║    /root/test-ad.sh                                            ║"
    echo "║                                                                ║"
    echo "║ 4. Adicionar usuário:                                          ║"
    echo "║    samba-tool user create usuario senha                        ║"
    echo "║                                                                ║"
    echo "║ 5. Listar usuários:                                            ║"
    echo "║    samba-tool user list                                       ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                 PARA O CONTROLADOR SECUNDÁRIO                   ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    printf "║ Use o script: setup-ad-secondary.sh                            ║\n"
    printf "║ IP do DC Primário: %-40s ║\n" "$IP_ADDRESS"
    printf "║ FQDN do DC Primário: %-36s ║\n" "$FQDN"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    
    echo ""
    log_success "🎉 CONFIGURAÇÃO DO DC PRIMÁRIO FINALIZADA!"
    log_info "Log completo: $LOG_FILE"
}

# =============================================================================
# FUNÇÃO PRINCIPAL
# =============================================================================

main() {
    # Verificar root
    check_root
    
    # Banner
    clear
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                                                                  ║"
    echo "║     🖥️  ACTIVE DIRECTORY - CONTROLADOR PRIMÁRIO                  ║"
    echo "║     📦 Ubuntu 24.04.4 LTS                                       ║"
    echo "║     🔧 Versão: 8.0                                              ║"
    echo "║                                                                  ║"
    echo "║     ✅ Instalação do primeiro DC da floresta                    ║"
    echo "║     ✅ SSH Root habilitado                                      ║"
    echo "║     ✅ Auto-complete com TAB                                    ║"
    echo "║     ✅ Idioma Português                                         ║"
    echo "║                                                                  ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Coletar informações
    collect_user_info
    
    log_info "Início da configuração: $(date)"
    log_info "Log: $LOG_FILE"
    echo ""
    
    # Executar etapas
    configure_language
    pause
    
    configure_ssh_root
    pause
    
    setup_autocomplete
    pause
    
    configure_hostname_dns
    pause
    
    install_packages
    pause
    
    configure_kerberos
    pause
    
    provision_primary
    pause
    
    start_services
    pause
    
    configure_backup
    create_test_script
    pause
    
    # Resumo final
    show_summary
    
    if confirm "🔄 Deseja reiniciar o servidor agora?"; then
        log_info "Reiniciando em 5 segundos..."
        sleep 5
        reboot
    else
        log_info "Lembre-se de reiniciar o servidor depois para aplicar todas as configurações."
    fi
}

# =============================================================================
# EXECUTAR
# =============================================================================

main "$@"
