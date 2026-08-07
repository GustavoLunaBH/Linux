#!/bin/bash
# =============================================================================
# Script: setup-ad-full.sh
# Versão: 7.0 - INSTALAÇÃO COMPLETA DO ZERO
# Descrição: Configuração completa do Active Directory com Samba no Ubuntu 24.04
# Inclui: SSH Root, Auto-complete, Idioma Português, DC Primário/Secundário
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
MODE=""
DOMAIN_NAME=""
REALM_NAME=""
NETBIOS_NAME=""
IP_ADDRESS=""
HOSTNAME=""
FQDN=""
ADMIN_PASSWORD=""
DC1_IP=""
DC1_FQDN=""

# Variáveis do script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/setup-ad-full-$(date +%Y%m%d-%H%M%S).log"
BACKUP_DIR="/root/ad-backup-$(date +%Y%m%d-%H%M%S)"
TEST_LOG="/root/ad-test-$(date +%Y%m%d-%H%M%S).log"
ROOT_PASSWORD=""

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

log_test() {
    echo -e "${MAGENTA}[$(date +'%Y-%m-%d %H:%M:%S')] 🧪 TESTE:${NC} $1" | tee -a "$TEST_LOG" "$LOG_FILE"
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
        echo "Use: sudo ./setup-ad-full.sh"
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
# FUNÇÃO: CONFIGURAR IDIOMA PARA PORTUGUÊS
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
    
    # Configurar timezone para Brasil
    log_info "Configurando fuso horário para Brasília..."
    timedatectl set-timezone America/Sao_Paulo
    
    # Instalar fontes para português
    apt install -y fonts-liberation fonts-dejavu-core 2>/dev/null
    
    log_success "Idioma configurado para Português do Brasil!"
    log_info "Nota: Reinicie o terminal para aplicar as mudanças de idioma."
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
    
    # Backup da configuração
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak 2>/dev/null
    
    # Permitir login root
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null
    sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null
    
    # Adicionar se não existir
    grep -q "^PermitRootLogin" /etc/ssh/sshd_config || echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
    grep -q "^PasswordAuthentication" /etc/ssh/sshd_config || echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
    
    # Reiniciar SSH
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null
    
    log_success "Root habilitado via SSH!"
    log_info "Para acessar: ssh root@$IP_ADDRESS"
}

# =============================================================================
# FUNÇÃO: HABILITAR AUTO-COMPLETE COM TAB
# =============================================================================

setup_autocomplete() {
    print_header "⌨️  CONFIGURANDO AUTO-COMPLETE COM TAB"
    
    log_info "Habilitando auto-complete e melhorias do terminal..."
    
    # Configurar inputrc
    cat > /etc/inputrc << 'EOF'
# Configurações de auto-complete
set show-all-if-ambiguous on
set completion-ignore-case on
set colored-stats on
set menu-complete-display-prefix on
set bell-style none
set editing-mode emacs
set keymap emacs

# Auto-complete com TAB
"\e[Z": menu-complete
set show-all-if-ambiguous on
set completion-ignore-case on
EOF
    
    # Configurar bashrc para todos os usuários
    cat >> /etc/bash.bashrc << 'EOF'
# Auto-complete melhorado
bind 'set show-all-if-ambiguous on'
bind 'set completion-ignore-case on'
bind 'set colored-stats on'

# Histórico com timestamp
export HISTTIMEFORMAT="%F %T "

# Aliases úteis
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'
alias egrep='egrep --color=auto'
alias fgrep='fgrep --color=auto'

# Auto-complete para comandos comuns
complete -c which
complete -c man
complete -c apt
complete -c systemctl
complete -c samba-tool
EOF
    
    # Configurar para root também
    cat >> /root/.bashrc << 'EOF'
# Auto-complete melhorado
bind 'set show-all-if-ambiguous on'
bind 'set completion-ignore-case on'
bind 'set colored-stats on'

# Aliases para AD
alias ad-status='systemctl status samba-ad-dc'
alias ad-users='samba-tool user list'
alias ad-groups='samba-tool group list'
alias ad-test='kinit administrator@RNV.INTRA'
alias ad-backup='/usr/local/bin/backup-ad.sh'
alias ad-logs='tail -f /var/log/samba/log.samba'
alias ad-test-all='/root/test-ad.sh'
alias ad-ports='ss -tulpn | grep -E "135|139|389|445|464|636|3268|3269|88|53"'
alias ad-info='samba-tool domain info 127.0.0.1'
alias ad-health='samba-tool domain health'
alias ad-repl='samba-tool drs showrepl'

# Comandos personalizados
alias update='apt update && apt upgrade -y'
alias install='apt install -y'
alias remove='apt remove -y'
alias clean='apt autoremove -y && apt autoclean'

# Auto-complete para samba-tool
complete -F _samba_tool samba-tool 2>/dev/null
EOF
    
    log_success "Auto-complete com TAB configurado!"
    log_info "Use TAB para completar comandos e caminhos."
}

# =============================================================================
# FUNÇÃO: COLETAR INFORMAÇÕES DO USUÁRIO
# =============================================================================

collect_user_info() {
    print_header "📋 INFORMAÇÕES DE CONFIGURAÇÃO"
    
    echo "Por favor, forneça as informações para configuração do AD:"
    echo ""
    
    # Selecionar modo
    while true; do
        echo "Selecione o modo de operação:"
        echo "  1) Controlador Primário (Primeiro DC da floresta)"
        echo "  2) Controlador Secundário (DC adicional para failover)"
        read -p "Opção (1/2): " MODE
        if [[ "$MODE" == "1" || "$MODE" == "2" ]]; then
            break
        else
            log_error "Opção inválida! Escolha 1 ou 2."
        fi
    done
    
    # Nome do Servidor
    while true; do
        read -p "📍 Nome do Servidor (ex: dc01, adserver, srv-ad): " HOSTNAME
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
    
    # FQDN
    FQDN="${HOSTNAME}.${DOMAIN_NAME}"
    
    # Se for secundário, perguntar informações do DC1
    if [[ "$MODE" == "2" ]]; then
        while true; do
            read -p "🔗 IP do Controlador Primário: " DC1_IP
            if [[ -n "$DC1_IP" ]]; then
                if [[ "$DC1_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    break
                else
                    log_error "IP inválido! Use formato: 192.168.1.10"
                fi
            else
                log_error "IP do DC Primário não pode estar vazio!"
            fi
        done
        
        while true; do
            read -p "🔗 FQDN do Controlador Primário (ex: dc01.empresa.local): " DC1_FQDN
            if [[ -n "$DC1_FQDN" ]]; then
                break
            else
                log_error "FQDN do DC Primário não pode estar vazio!"
            fi
        done
    fi
    
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
    echo "  ┌─────────────────────────────────────────────────────┐"
    printf "  │ %-20s: %-30s │\n" "Modo" "$( [[ "$MODE" == "1" ]] && echo "Primário" || echo "Secundário" )"
    printf "  │ %-20s: %-30s │\n" "Nome do Servidor" "$HOSTNAME"
    printf "  │ %-20s: %-30s │\n" "Domínio DNS" "$DOMAIN_NAME"
    printf "  │ %-20s: %-30s │\n" "Realm Kerberos" "$REALM_NAME"
    printf "  │ %-20s: %-30s │\n" "NetBIOS" "$NETBIOS_NAME"
    printf "  │ %-20s: %-30s │\n" "FQDN" "$FQDN"
    printf "  │ %-20s: %-30s │\n" "IP do Servidor" "$IP_ADDRESS"
    if [[ "$MODE" == "2" ]]; then
        printf "  │ %-20s: %-30s │\n" "IP Primário" "$DC1_IP"
        printf "  │ %-20s: %-30s │\n" "FQDN Primário" "$DC1_FQDN"
    fi
    printf "  │ %-20s: %-30s │\n" "Usuário Admin" "administrator@$REALM_NAME"
    echo "  └─────────────────────────────────────────────────────┘"
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
        expect chrony ntpdate fail2ban
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
# FUNÇÃO: PREPARAR PROVISIONAMENTO
# =============================================================================

prepare_provisioning() {
    print_header "PREPARANDO PROVISIONAMENTO"
    
    log_info "Removendo arquivos conflitantes..."
    
    if [ -f /etc/samba/smb.conf ]; then
        mv /etc/samba/smb.conf "/etc/samba/smb.conf.bak.$(date +%Y%m%d-%H%M%S)"
        log_success "Arquivo smb.conf movido para backup"
    fi
    
    log_info "Parando serviços conflitantes..."
    systemctl stop smbd nmbd winbind 2>/dev/null
    systemctl disable smbd nmbd winbind 2>/dev/null
    systemctl mask smbd nmbd winbind 2>/dev/null
    
    log_success "Ambiente preparado para provisionamento!"
}

# =============================================================================
# FUNÇÃO: PROVISIONAR DOMÍNIO PRIMÁRIO
# =============================================================================

provision_primary() {
    print_header "PROVISIONAMENTO DO DOMÍNIO PRIMÁRIO"
    
    log_info "Realm: $REALM_NAME"
    log_info "Domain: $NETBIOS_NAME"
    log_info "Server Role: dc"
    log_info "DNS Backend: SAMBA_INTERNAL"
    
    log_info "Executando provisionamento (pode levar alguns minutos)..."
    
    if command -v expect &> /dev/null; then
        expect -c "
            set timeout 300
            spawn samba-tool domain provision --use-rfc2307 --interactive
            
            expect \"Realm \\[.*\\]:\" { send \"$REALM_NAME\r\" }
            expect \"Domain \\[.*\\]:\" { send \"$NETBIOS_NAME\r\" }
            expect \"Server Role (dc, member, standalone) \\[dc\\]:\" { send \"dc\r\" }
            expect \"DNS backend (SAMBA_INTERNAL, BIND9_FLATFILE, BIND9_DLZ, NONE) \\[SAMBA_INTERNAL\\]:\" { send \"SAMBA_INTERNAL\r\" }
            expect \"DNS forwarder .*:\" { send \"8.8.8.8\r\" }
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
        cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
    else
        log_error "Falha no provisionamento!"
        exit 1
    fi
}

# =============================================================================
# FUNÇÃO: JOIN NO DOMÍNIO SECUNDÁRIO
# =============================================================================

join_secondary() {
    print_header "JUNTANDO AO DOMÍNIO COMO DC SECUNDÁRIO"
    
    log_info "Verificando conectividade com o DC Primário..."
    
    if ! ping -c 3 $DC1_IP > /dev/null 2>&1; then
        log_error "DC1 não acessível! Verifique a rede."
        exit 1
    fi
    log_success "DC1 acessível"
    
    log_info "Configurando DNS com fallback para DC1..."
    chattr -i /etc/resolv.conf 2>/dev/null
    cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
nameserver $DC1_IP
nameserver 8.8.8.8
search $DOMAIN_NAME
domain $DOMAIN_NAME
EOF
    
    log_info "Removendo arquivos conflitantes..."
    rm -f /etc/samba/smb.conf
    
    log_info "Realizando join no domínio..."
    samba-tool domain join $DOMAIN_NAME DC \
        -U administrator \
        --dns-backend=SAMBA_INTERNAL
    
    if [ -f /var/lib/samba/private/secrets.ldb ]; then
        log_success "Join no domínio concluído com sucesso!"
        cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
    else
        log_error "Falha no join do domínio!"
        exit 1
    fi
}

# =============================================================================
# FUNÇÃO: INICIAR SERVIÇOS
# =============================================================================

start_services() {
    print_header "INICIANDO SERVIÇOS"
    
    log_info "Iniciando samba-ad-dc..."
    systemctl unmask samba-ad-dc 2>/dev/null
    systemctl enable samba-ad-dc 2>/dev/null
    systemctl start samba-ad-dc 2>/dev/null
    
    sleep 5
    
    if systemctl is-active --quiet samba-ad-dc; then
        log_success "Serviço samba-ad-dc está rodando!"
    else
        log_error "Falha ao iniciar samba-ad-dc!"
        systemctl status samba-ad-dc --no-pager
        exit 1
    fi
}

# =============================================================================
# FUNÇÃO: TESTES AUTOMATIZADOS
# =============================================================================

run_tests() {
    print_header "🧪 EXECUTANDO TESTES"
    
    TEST_PASS=0
    TEST_FAIL=0
    TEST_TOTAL=0
    
    # Teste 1: Serviço
    TEST_TOTAL=$((TEST_TOTAL + 1))
    log_test "Verificando serviço samba-ad-dc..."
    if systemctl is-active --quiet samba-ad-dc; then
        log_success "✅ Serviço está ATIVO"
        TEST_PASS=$((TEST_PASS + 1))
    else
        log_error "❌ Serviço NÃO está ativo"
        TEST_FAIL=$((TEST_FAIL + 1))
    fi
    
    # Teste 2: Kerberos
    TEST_TOTAL=$((TEST_TOTAL + 1))
    log_test "Testando autenticação Kerberos..."
    echo "$ADMIN_PASSWORD" | kinit administrator@"$REALM_NAME" > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        log_success "✅ Autenticação Kerberos OK"
        TEST_PASS=$((TEST_PASS + 1))
    else
        log_error "❌ Falha na autenticação Kerberos"
        TEST_FAIL=$((TEST_FAIL + 1))
    fi
    
    # Teste 3: DNS
    TEST_TOTAL=$((TEST_TOTAL + 1))
    log_test "Verificando DNS..."
    if host -t SRV _ldap._tcp.$DOMAIN_NAME > /dev/null 2>&1; then
        log_success "✅ DNS funcionando"
        TEST_PASS=$((TEST_PASS + 1))
    else
        log_error "❌ DNS com problemas"
        TEST_FAIL=$((TEST_FAIL + 1))
    fi
    
    # Teste 4: Usuários
    TEST_TOTAL=$((TEST_TOTAL + 1))
    log_test "Listando usuários..."
    if samba-tool user list 2>/dev/null | grep -q "administrator"; then
        log_success "✅ Usuários OK"
        TEST_PASS=$((TEST_PASS + 1))
    else
        log_error "❌ Falha ao listar usuários"
        TEST_FAIL=$((TEST_FAIL + 1))
    fi
    
    # Resumo
    echo ""
    print_header "📊 RESUMO DOS TESTES"
    echo ""
    echo "  ✅ Testes passaram: $TEST_PASS"
    echo "  ❌ Testes falharam: $TEST_FAIL"
    echo "  📊 Total de testes: $TEST_TOTAL"
    echo "  📈 Taxa de sucesso: $(( (TEST_PASS * 100) / TEST_TOTAL ))%"
    echo ""
    
    if [ $TEST_FAIL -eq 0 ]; then
        log_success "🎉 TODOS OS TESTES PASSARAM!"
    else
        log_warning "⚠️ ALGUNS TESTES FALHARAM"
    fi
}

# =============================================================================
# FUNÇÃO: CONFIGURAR BACKUP
# =============================================================================

configure_backup() {
    print_header "CONFIGURANDO BACKUP"
    
    mkdir -p /backup/ad
    
    cat > /usr/local/bin/backup-ad.sh << EOF
#!/bin/bash
BACKUP_DIR="/backup/ad"
DATE=\$(date +%Y%m%d_%H%M%S)
LOG_FILE="/var/log/backup-ad.log"

mkdir -p \$BACKUP_DIR
echo "=== Backup AD - \$DATE ===" >> \$LOG_FILE

samba-tool domain backup online --server=$FQDN --targetdir=\$BACKUP_DIR --backup-file="ad_backup_\$DATE.ldif" -U administrator 2>/dev/null
tar -czf \$BACKUP_DIR/sysvol_\$DATE.tar.gz -C /var/lib/samba sysvol 2>/dev/null
tar -czf \$BACKUP_DIR/config_\$DATE.tar.gz -C /etc samba krb5.conf 2>/dev/null

find \$BACKUP_DIR -name "*.ldif" -mtime +30 -delete
find \$BACKUP_DIR -name "*.tar.gz" -mtime +30 -delete

echo "Backup concluído!" >> \$LOG_FILE
EOF
    
    chmod +x /usr/local/bin/backup-ad.sh
    (crontab -l 2>/dev/null; echo "0 2 * * * /usr/local/bin/backup-ad.sh") | crontab -
    
    log_success "Backup configurado! Agendamento diário às 2h."
}

# =============================================================================
# FUNÇÃO: CRIAR SCRIPT DE TESTE
# =============================================================================

create_test_script() {
    cat > /root/test-ad.sh << EOF
#!/bin/bash
echo "=== TESTE RÁPIDO DO AD ==="
echo ""

echo "1. Serviço:"
systemctl status samba-ad-dc --no-pager | grep Active
echo ""

echo "2. Kerberos:"
kinit administrator@$REALM_NAME <<< "$ADMIN_PASSWORD" 2>/dev/null && echo "✅ OK" || echo "❌ FALHA"
echo ""

echo "3. DNS:"
host -t SRV _ldap._tcp.$DOMAIN_NAME
echo ""

echo "4. Usuários:"
samba-tool user list | head -5
echo ""

echo "5. Replicação:"
samba-tool drs showrepl | head -10
echo ""
EOF
    
    chmod +x /root/test-ad.sh
    log_success "Script de teste criado em /root/test-ad.sh"
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
    printf "║ %-20s: %-40s ║\n" "Modo" "$( [[ "$MODE" == "1" ]] && echo "Primário" || echo "Secundário" )"
    printf "║ %-20s: %-40s ║\n" "Domínio" "$DOMAIN_NAME"
    printf "║ %-20s: %-40s ║\n" "Servidor" "$FQDN"
    printf "║ %-20s: %-40s ║\n" "IP" "$IP_ADDRESS"
    printf "║ %-20s: %-40s ║\n" "Usuário Admin" "administrator@$REALM_NAME"
    if [[ "$MODE" == "2" ]]; then
        printf "║ %-20s: %-40s ║\n" "DC Primário" "$DC1_FQDN"
    fi
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
    echo "║ 3. Listar usuários:                                            ║"
    echo "║    samba-tool user list                                       ║"
    echo "║                                                                ║"
    echo "║ 4. Executar testes:                                            ║"
    echo "║    /root/test-ad.sh                                            ║"
    echo "║                                                                ║"
    echo "║ 5. Verificar replicação (DC Secundário):                       ║"
    echo "║    samba-tool drs showrepl                                    ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                 CONFIGURAR CLIENTES WINDOWS                    ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    printf "║ DNS: %-55s ║\n" "$IP_ADDRESS"
    printf "║ Domínio: %-52s ║\n" "$DOMAIN_NAME"
    printf "║ Usuário: %-52s ║\n" "administrator"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                    ARQUIVOS IMPORTANTES                        ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    printf "║ Log do Setup: %-45s ║\n" "$LOG_FILE"
    printf "║ Script de Teste: %-43s ║\n" "/root/test-ad.sh"
    printf "║ Script Backup: %-44s ║\n" "/usr/local/bin/backup-ad.sh"
    echo "╚══════════════════════════════════════════════════════════════════╝"
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
    echo "║     🖥️  ACTIVE DIRECTORY - INSTALAÇÃO COMPLETA DO ZERO           ║"
    echo "║     📦 Ubuntu 24.04.4 LTS                                       ║"
    echo "║     🔧 Versão: 7.0 - FULL                                       ║"
    echo "║                                                                  ║"
    echo "║     ✅ SSH Root habilitado                                       ║"
    echo "║     ✅ Auto-complete com TAB                                    ║"
    echo "║     ✅ Idioma Português                                         ║"
    echo "║     ✅ Suporte a DC Primário/Secundário                         ║"
    echo "║                                                                  ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Coletar informações
    collect_user_info
    
    # Configurar tudo
    log_info "Início: $(date)"
    log_info "Log: $LOG_FILE"
    echo ""
    
    # ========================================================================
    # ETAPAS DE CONFIGURAÇÃO
    # ========================================================================
    
    # 1. Idioma
    log_info "▶ 1/11: Configurando idioma Português..."
    configure_language
    pause
    
    # 2. Root SSH
    log_info "▶ 2/11: Configurando Root via SSH..."
    configure_ssh_root
    pause
    
    # 3. Auto-complete
    log_info "▶ 3/11: Configurando Auto-complete com TAB..."
    setup_autocomplete
    pause
    
    # 4. Hostname
    log_info "▶ 4/11: Configurando hostname..."
    configure_hostname_dns
    pause
    
    # 5. Pacotes
    log_info "▶ 5/11: Instalando pacotes..."
    install_packages
    pause
    
    # 6. Kerberos
    log_info "▶ 6/11: Configurando Kerberos..."
    configure_kerberos
    pause
    
    # 7. Preparar
    log_info "▶ 7/11: Preparando ambiente..."
    prepare_provisioning
    pause
    
    # 8. Provisionar ou Join
    if [[ "$MODE" == "1" ]]; then
        log_info "▶ 8/11: Provisionando domínio primário..."
        provision_primary
    else
        log_info "▶ 8/11: Juntando ao domínio como secundário..."
        join_secondary
    fi
    pause
    
    # 9. Iniciar serviços
    log_info "▶ 9/11: Iniciando serviços..."
    start_services
    pause
    
    # 10. Backup
    log_info "▶ 10/11: Configurando backup..."
    configure_backup
    create_test_script
    pause
    
    # 11. Testes
    log_info "▶ 11/11: Executando testes..."
    run_tests
    
    # Resumo
    show_summary
    
    log_success "🎉 CONFIGURAÇÃO COMPLETA FINALIZADA!"
    log_info "Log completo: $LOG_FILE"
    
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
