#!/bin/bash
# =============================================================================
# Script: setup-ad-primary.sh
# Versão: 8.5 - SEMI-AUTOMÁTICO
# Descrição: Configura AD perguntando apenas o essencial
# Uso: sudo ./setup-ad-primary-auto.sh
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

# Variáveis (serão preenchidas pelo usuário)
HOSTNAME=""
DOMAIN_NAME=""
IP_ADDRESS=""
ADMIN_PASSWORD=""
DNS_FORWARDER="8.8.8.8"

# Variáveis automáticas
REALM_NAME=""
NETBIOS_NAME=""
FQDN=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/setup-ad-primary-$(date +%Y%m%d-%H%M%S).log"

# =============================================================================
# FUNÇÕES
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
        echo "Use: sudo ./setup-ad-primary-auto.sh"
        exit 1
    fi
}

confirm() {
    read -p "$1 (s/N): " -n 1 -r
    echo
    [[ $REPLY =~ ^[Ss]$ ]]
}

# =============================================================================
# FUNÇÃO: COLETAR INFORMAÇÕES (APENAS O ESSENCIAL)
# =============================================================================

collect_user_info() {
    print_header "📋 INFORMAÇÕES DE CONFIGURAÇÃO"
    
    echo "Por favor, informe os dados necessários:"
    echo ""
    
    # Nome do Servidor
    while true; do
        read -p "📍 Nome do Servidor (ex: dc01, adserver01): " HOSTNAME
        if [[ -n "$HOSTNAME" ]] && [[ "$HOSTNAME" =~ ^[a-zA-Z0-9-]+$ ]]; then
            break
        else
            log_error "Nome inválido! Use apenas letras, números e hífen."
        fi
    done
    
    # Domínio
    while true; do
        read -p "🌐 Nome do Domínio (ex: empresa.local, rnv.intra): " DOMAIN_NAME
        if [[ -n "$DOMAIN_NAME" ]] && [[ "$DOMAIN_NAME" =~ ^[a-z0-9]+\.[a-z]+$ ]]; then
            break
        else
            log_error "Domínio inválido! Use formato: empresa.local"
        fi
    done
    
    # IP do Servidor
    while true; do
        read -p "🔢 IP do Servidor (ex: 192.168.1.2): " IP_ADDRESS
        if [[ -n "$IP_ADDRESS" ]] && [[ "$IP_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
        else
            log_error "IP inválido! Use formato: 192.168.1.10"
        fi
    done
    
    # DNS Forwarder (opcional)
    read -p "🌐 DNS Forwarder [8.8.8.8]: " DNS_FORWARDER
    DNS_FORWARDER=${DNS_FORWARDER:-8.8.8.8}
    
    # Calcular valores automáticos
    REALM_NAME=$(echo "$DOMAIN_NAME" | tr '[:lower:]' '[:upper:]')
    NETBIOS_NAME=$(echo "$DOMAIN_NAME" | cut -d. -f1 | tr '[:lower:]' '[:upper:]')
    FQDN="${HOSTNAME}.${DOMAIN_NAME}"
    
    # Senha do Root
    echo ""
    log_info "Configurando senha do ROOT..."
    echo "Digite a senha para o usuário root:"
    passwd root
    
    # Senha do Administrador do AD
    echo ""
    while true; do
        read -s -p "🔑 Senha do Administrador do AD (mínimo 8 caracteres): " ADMIN_PASSWORD
        echo ""
        if [[ ${#ADMIN_PASSWORD} -ge 8 ]]; then
            read -s -p "🔑 Confirme a senha: " ADMIN_PASSWORD_CONFIRM
            echo ""
            if [[ "$ADMIN_PASSWORD" == "$ADMIN_PASSWORD_CONFIRM" ]]; then
                break
            else
                log_error "Senhas não coincidem!"
            fi
        else
            log_error "Senha muito curta! Mínimo 8 caracteres."
        fi
    done
    
    # Mostrar resumo
    echo ""
    print_header "📊 RESUMO DA CONFIGURAÇÃO"
    echo ""
    echo "  ┌──────────────────────────────────────────────────────────────┐"
    printf "  │ %-22s: %-40s │\n" "Servidor" "$HOSTNAME"
    printf "  │ %-22s: %-40s │\n" "Domínio" "$DOMAIN_NAME"
    printf "  │ %-22s: %-40s │\n" "Realm" "$REALM_NAME"
    printf "  │ %-22s: %-40s │\n" "NetBIOS" "$NETBIOS_NAME"
    printf "  │ %-22s: %-40s │\n" "FQDN" "$FQDN"
    printf "  │ %-22s: %-40s │\n" "IP" "$IP_ADDRESS"
    printf "  │ %-22s: %-40s │\n" "DNS Forwarder" "$DNS_FORWARDER"
    printf "  │ %-22s: %-40s │\n" "Usuário AD" "administrator@$REALM_NAME"
    echo "  └──────────────────────────────────────────────────────────────┘"
    echo ""
    
    if ! confirm "✅ Confirmar e iniciar configuração?"; then
        log_info "Configuração cancelada."
        exit 0
    fi
}

# =============================================================================
# FUNÇÃO: CONFIGURAR DNS PARA INTERNET
# =============================================================================

configure_dns_internet() {
    print_header "🌐 CONFIGURANDO DNS PARA ACESSAR A INTERNET"
    
    log_info "Configurando DNS para acessar os repositórios..."
    
    chattr -i /etc/resolv.conf 2>/dev/null
    
    cat > /etc/resolv.conf << 'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 8.8.4.4
EOF
    
    log_info "Testando conectividade com a internet..."
    
    if ping -c 3 8.8.8.8 > /dev/null 2>&1; then
        log_success "✅ Conectividade com a internet OK!"
    else
        log_error "❌ Sem conectividade com a internet!"
        log_info "Verifique sua rede física."
        exit 1
    fi
    
    log_info "Testando resolução de DNS..."
    
    if nslookup google.com 8.8.8.8 > /dev/null 2>&1; then
        log_success "✅ Resolução de DNS funcionando!"
    else
        log_warning "⚠️  Resolução de DNS com problemas"
        
        if ping -c 3 google.com > /dev/null 2>&1; then
            log_success "✅ DNS funcionando (ping google.com OK)"
        else
            log_error "❌ DNS NÃO está funcionando!"
            exit 1
        fi
    fi
    
    # Testar acesso aos repositórios
    log_info "Testando acesso aos repositórios Ubuntu..."
    
    if curl -s --connect-timeout 5 https://br.archive.ubuntu.com > /dev/null 2>&1; then
        log_success "✅ Acesso ao repositório Ubuntu OK!"
    else
        log_warning "⚠️  Acesso ao repositório Ubuntu com problemas"
        sed -i 's/br.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list
        sed -i 's/security.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list
    fi
}

# =============================================================================
# FUNÇÃO: INSTALAR PACOTES (COM KERBEROS AUTOMÁTICO)
# =============================================================================

install_packages() {
    print_header "📦 INSTALAÇÃO DE PACOTES"
    
    log_info "Atualizando repositórios..."
    apt update -qq 2>/dev/null
    
    if [ $? -ne 0 ]; then
        log_warning "Problemas na atualização. Usando mirror alternativo..."
        sed -i 's/br.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list
        sed -i 's/security.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list
        apt update -qq 2>/dev/null
    fi
    
    log_info "Instalando pacotes essenciais (Kerberos automático)..."
    log_info "Isso pode levar alguns minutos..."
    
    # Configurar respostas automáticas para o Kerberos
    export DEBIAN_FRONTEND=noninteractive
    
    # Criar arquivo de respostas para o Kerberos
    cat > /tmp/krb5-config << EOF
[libdefaults]
    default_realm = $REALM_NAME
    dns_lookup_realm = false
    dns_lookup_kdc = true
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true

[realms]
    $REALM_NAME = {
        kdc = $HOSTNAME.$DOMAIN_NAME
        admin_server = $HOSTNAME.$DOMAIN_NAME
    }

[domain_realm]
    .$DOMAIN_NAME = $REALM_NAME
    $DOMAIN_NAME = $REALM_NAME
EOF

    # Instalar pacotes
    apt install -y \
        samba \
        samba-ad-dc \
        samba-common-bin \
        samba-dsdb-modules \
        samba-vfs-modules \
        krb5-user \
        krb5-config \
        winbind \
        libpam-winbind \
        libnss-winbind \
        acl \
        attr \
        bind9utils \
        dnsutils \
        python3 \
        python3-dnspython \
        python3-samba \
        ldb-tools \
        net-tools \
        ldap-utils \
        expect \
        chrony \
        fail2ban \
        language-pack-pt \
        language-pack-pt-base \
        bash-completion \
        2>&1 | grep -v "debconf"
    
    # Verificar instalação
    if command -v samba-tool &> /dev/null; then
        log_success "Samba instalado com sucesso!"
        log_info "Versão: $(samba-tool --version 2>/dev/null)"
    else
        log_error "Falha na instalação do Samba!"
        exit 1
    fi
}

# =============================================================================
# FUNÇÃO: CONFIGURAR HOSTNAME E DNS
# =============================================================================

configure_hostname_dns() {
    print_header "🏷️  CONFIGURAÇÃO DE HOSTNAME E DNS"
    
    log_info "Configurando hostname para: $FQDN"
    hostnamectl set-hostname "$FQDN" 2>/dev/null
    echo "$FQDN" > /etc/hostname
    
    log_info "Configurando /etc/hosts"
    cat > /etc/hosts << EOF
127.0.0.1       localhost localhost.localdomain
127.0.1.1       $FQDN $HOSTNAME
$IP_ADDRESS     $FQDN $HOSTNAME

::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF
    
    log_info "Configurando /etc/resolv.conf"
    chattr -i /etc/resolv.conf 2>/dev/null
    cat > /etc/resolv.conf << EOF
nameserver $DNS_FORWARDER
nameserver 8.8.8.8
search $DOMAIN_NAME
domain $DOMAIN_NAME
EOF
    
    log_success "Hostname configurado para: $FQDN"
}

# =============================================================================
# FUNÇÃO: PROVISIONAR DOMÍNIO (AUTOMÁTICO)
# =============================================================================

provision_domain() {
    print_header "🏗️  PROVISIONANDO DOMÍNIO (AUTOMÁTICO)"
    
    log_info "Realm: $REALM_NAME"
    log_info "Domain: $NETBIOS_NAME"
    log_info "DNS Forwarder: $DNS_FORWARDER"
    
    log_info "Preparando ambiente..."
    
    # Remover arquivos conflitantes
    if [ -f /etc/samba/smb.conf ]; then
        mv /etc/samba/smb.conf "/etc/samba/smb.conf.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null
    fi
    
    # Parar serviços
    systemctl stop smbd nmbd winbind 2>/dev/null
    systemctl disable smbd nmbd winbind 2>/dev/null
    systemctl mask smbd nmbd winbind 2>/dev/null
    
    log_info "Executando provisionamento automático..."
    log_info "Isso pode levar alguns minutos..."
    
    # Criar script expect para automatizar o provisionamento
    cat > /tmp/provision.exp << 'EOF'
#!/usr/bin/expect -f
set timeout 300
log_user 1

set realm [lindex $argv 0]
set domain [lindex $argv 1]
set forwarder [lindex $argv 2]
set password [lindex $argv 3]

spawn samba-tool domain provision --use-rfc2307

expect "Realm \\\[.*\\\]:"
send "$realm\r"

expect "Domain \\\[.*\\\]:"
send "$domain\r"

expect "Server Role (dc, member, standalone) \\\[dc\\\]:"
send "dc\r"

expect "DNS backend (SAMBA_INTERNAL, BIND9_FLATFILE, BIND9_DLZ, NONE) \\\[SAMBA_INTERNAL\\\]:"
send "SAMBA_INTERNAL\r"

expect "DNS forwarder .*:"
send "$forwarder\r"

expect "Administrator password:"
send "$password\r"

expect "Retype password:"
send "$password\r"

expect eof
EOF
    
    chmod +x /tmp/provision.exp
    
    # Executar provisionamento automático
    /tmp/provision.exp "$REALM_NAME" "$NETBIOS_NAME" "$DNS_FORWARDER" "$ADMIN_PASSWORD"
    
    # Limpar
    rm -f /tmp/provision.exp
    
    # Verificar
    if [ -f /var/lib/samba/private/secrets.ldb ]; then
        log_success "Provisionamento concluído com sucesso!"
        cp /var/lib/samba/private/krb5.conf /etc/krb5.conf 2>/dev/null
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
    
    sleep 5
    
    if systemctl is-active --quiet samba-ad-dc; then
        log_success "✅ Serviço samba-ad-dc está rodando!"
        
        log_info "Verificando portas..."
        ss -tulpn 2>/dev/null | grep -E ":(135|139|389|445|464|636|3268|3269|88|53)\s" | grep LISTEN || log_warning "Portas não encontradas"
    else
        log_error "❌ Falha ao iniciar samba-ad-dc!"
        systemctl status samba-ad-dc --no-pager
        exit 1
    fi
}

# =============================================================================
# FUNÇÃO: CRIAR SCRIPTS AUXILIARES
# =============================================================================

create_aux_scripts() {
    print_header "📝 CRIANDO SCRIPTS AUXILIARES"
    
    # Script de teste
    cat > /root/test-ad.sh << EOF
#!/bin/bash
echo "=== TESTE DO ACTIVE DIRECTORY ==="
echo ""

echo "1. VERIFICANDO SERVIÇO:"
systemctl status samba-ad-dc --no-pager | grep Active
echo ""

echo "2. VERIFICANDO KERBEROS:"
echo "   Teste: kinit administrator@$REALM_NAME"
echo "   Digite a senha do AD"
echo ""

echo "3. VERIFICANDO DNS:"
host -t SRV _ldap._tcp.$DOMAIN_NAME 2>/dev/null || echo "   ⚠️  SRV não encontrado"
echo ""

echo "4. LISTANDO USUÁRIOS:"
samba-tool user list 2>/dev/null | head -5
echo ""

echo "5. INFORMAÇÕES DO DOMÍNIO:"
samba-tool domain info 127.0.0.1 2>/dev/null | grep -E "Domain|Forest|DNS"
echo ""

echo "=== FIM DOS TESTES ==="
EOF
    
    chmod +x /root/test-ad.sh
    
    # Script de backup
    mkdir -p /backup/ad 2>/dev/null
    
    cat > /usr/local/bin/backup-ad.sh << 'EOF'
#!/bin/bash
BACKUP_DIR="/backup/ad"
DATE=$(date +%Y%m%d_%H%M%S)
LOG_FILE="/var/log/backup-ad.log"

mkdir -p $BACKUP_DIR
echo "=== Backup AD - $DATE ===" >> $LOG_FILE

samba-tool domain backup online --targetdir=$BACKUP_DIR --backup-file="ad_backup_$DATE.bak" 2>&1 >> $LOG_FILE
tar -czf $BACKUP_DIR/sysvol_$DATE.tar.gz -C /var/lib/samba sysvol 2>&1 >> $LOG_FILE

find $BACKUP_DIR -name "*.bak" -mtime +30 -delete 2>/dev/null
find $BACKUP_DIR -name "*.tar.gz" -mtime +30 -delete 2>/dev/null

echo "Backup concluído" >> $LOG_FILE
EOF
    
    chmod +x /usr/local/bin/backup-ad.sh
    
    # Adicionar alias
    echo "alias ad-backup='/usr/local/bin/backup-ad.sh'" >> /root/.bashrc
    
    log_success "Scripts auxiliares criados!"
}

# =============================================================================
# FUNÇÃO: RESUMO FINAL
# =============================================================================

show_summary() {
    print_header "✅ CONFIGURAÇÃO CONCLUÍDA!"
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║              INFORMAÇÕES DO DOMÍNIO                            ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    printf "║ %-20s: %-40s ║\n" "Função" "Controlador Primário (PDC)"
    printf "║ %-20s: %-40s ║\n" "Domínio" "$DOMAIN_NAME"
    printf "║ %-20s: %-40s ║\n" "Servidor" "$FQDN"
    printf "║ %-20s: %-40s ║\n" "IP" "$IP_ADDRESS"
    printf "║ %-20s: %-40s ║\n" "Usuário" "administrator@$REALM_NAME"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    printf "║ %-20s: %-40s ║\n" "Script Teste" "/root/test-ad.sh"
    printf "║ %-20s: %-40s ║\n" "Script Backup" "/usr/local/bin/backup-ad.sh"
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
    echo "║ 4. Listar usuários:                                            ║"
    echo "║    samba-tool user list                                       ║"
    echo "║                                                                ║"
    echo "║ 5. Adicionar usuário:                                          ║"
    echo "║    samba-tool user create usuario senha                        ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    
    echo ""
    log_success "🎉 CONFIGURAÇÃO FINALIZADA!"
}

# =============================================================================
# FUNÇÃO: HABILITAR ROOT VIA SSH
# =============================================================================

configure_ssh_root() {
    print_header "🔐 CONFIGURANDO ROOT VIA SSH"
    
    log_info "Configurando SSH para permitir login root..."
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak 2>/dev/null
    
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null
    sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null
    
    grep -q "^PermitRootLogin" /etc/ssh/sshd_config || echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
    grep -q "^PasswordAuthentication" /etc/ssh/sshd_config || echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
    
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    
    log_success "Root habilitado via SSH!"
}

# =============================================================================
# FUNÇÃO: CONFIGURAR AUTO-COMPLETE
# =============================================================================

setup_autocomplete() {
    print_header "⌨️  CONFIGURANDO AUTO-COMPLETE"
    
    log_info "Configurando auto-complete..."
    
    cat > /etc/inputrc << 'EOF'
set show-all-if-ambiguous on
set completion-ignore-case on
set colored-stats on
set menu-complete-display-prefix on
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
EOF
    
    cat >> /root/.bashrc << 'EOF'
bind 'set show-all-if-ambiguous on'
bind 'set completion-ignore-case on'
bind 'set colored-stats on'
alias ad-status='systemctl status samba-ad-dc'
alias ad-users='samba-tool user list'
alias ad-groups='samba-tool group list'
alias ad-logs='tail -f /var/log/samba/log.samba'
alias ad-ports='ss -tulpn | grep -E "135|139|389|445|464|636|3268|3269|88|53"'
alias ad-info='samba-tool domain info 127.0.0.1'
alias ad-test='/root/test-ad.sh'
alias ad-backup='/usr/local/bin/backup-ad.sh'
alias update='apt update && apt upgrade -y'
alias install='apt install -y'
alias clean='apt autoremove -y && apt autoclean'
EOF
    
    log_success "Auto-complete configurado!"
}

# =============================================================================
# FUNÇÃO: CONFIGURAR IDIOMA
# =============================================================================

configure_language() {
    print_header "🌐 CONFIGURANDO IDIOMA"
    
    log_info "Instalando pacotes de idioma..."
    apt install -y language-pack-pt language-pack-pt-base 2>/dev/null
    
    log_info "Configurando locale..."
    locale-gen pt_BR.UTF-8 2>/dev/null
    update-locale LANG=pt_BR.UTF-8 LANGUAGE=pt_BR:pt LC_ALL=pt_BR.UTF-8 2>/dev/null
    
    cat > /etc/default/locale << 'EOF'
LANG=pt_BR.UTF-8
LANGUAGE=pt_BR:pt
LC_ALL=pt_BR.UTF-8
EOF
    
    timedatectl set-timezone America/Sao_Paulo 2>/dev/null
    
    log_success "Idioma configurado para Português do Brasil!"
}

# =============================================================================
# FUNÇÃO PRINCIPAL
# =============================================================================

main() {
    check_root
    
    clear
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                                                                  ║"
    echo "║     🖥️  ACTIVE DIRECTORY - CONTROLADOR PRIMÁRIO                  ║"
    echo "║     📦 Ubuntu 24.04 LTS                                         ║"
    echo "║     🔧 Versão: 8.5 - SEMI-AUTOMÁTICO                            ║"
    echo "║                                                                  ║"
    echo "║     ✅ Pergunta apenas o essencial                              ║"
    echo "║     ✅ Kerberos automático                                      ║"
    echo "║     ✅ Provisionamento automático                               ║"
    echo "║     ✅ SSH Root habilitado                                      ║"
    echo "║                                                                  ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Etapa 1: Configurar DNS para internet
    configure_dns_internet
    
    # Coletar informações
    collect_user_info
    
    log_info "Início: $(date)"
    log_info "Log: $LOG_FILE"
    echo ""
    
    # Executar etapas
    configure_language
    configure_ssh_root
    setup_autocomplete
    configure_hostname_dns
    install_packages
    provision_domain
    start_services
    create_aux_scripts
    
    # Resumo final
    show_summary
    
    if confirm "🔄 Deseja reiniciar o servidor agora?"; then
        log_info "Reiniciando em 5 segundos..."
        sleep 5
        reboot
    else
        log_info "Lembre-se de reiniciar o servidor depois."
        log_info "Execute: reboot"
    fi
}

# =============================================================================
# EXECUTAR
# =============================================================================

main "$@"
