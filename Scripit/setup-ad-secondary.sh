#!/bin/bash
# =============================================================================
# Script: setup-ad-secondary.sh
# Versão: 1.4 - CORRIGIDO DEFINITIVO
# Descrição: Configuração do Controlador Secundário (join no domínio)
# Uso: sudo ./setup-ad-secondary.sh
# =============================================================================

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# =============================================================================
# CONFIGURACOES FIXAS (ALTERE AQUI SE NECESSARIO)
# =============================================================================

# Dados do AD (preencher antes de executar)
HOSTNAME="adserver02"
DOMAIN_NAME="rnv.intra"
IP_ADDRESS="192.168.1.3"
DC1_IP="192.168.1.2"
DC1_FQDN="adserver01.rnv.intra"
ADMIN_PASSWORD="Senha@123456"
DNS_FORWARDER="8.8.8.8"

# Variaveis automaticas
REALM_NAME=$(echo "$DOMAIN_NAME" | tr '[:lower:]' '[:upper:]')
FQDN="${HOSTNAME}.${DOMAIN_NAME}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/setup-ad-secondary-$(date +%Y%m%d-%H%M%S).log"

# =============================================================================
# FUNCOES
# =============================================================================

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERRO:${NC} $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] AVISO:${NC} $1" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO:${NC} $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${CYAN}[$(date +'%Y-%m-%d %H:%M:%S')] SUCESSO:${NC} $1" | tee -a "$LOG_FILE"
}

print_header() {
    echo ""
    echo "====================================================================="
    echo "  $1"
    echo "====================================================================="
    echo ""
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Este script deve ser executado como root!"
        echo "Use: sudo ./setup-ad-secondary.sh"
        exit 1
    fi
}

confirm() {
    read -p "$1 (s/N): " -n 1 -r
    echo
    [[ $REPLY =~ ^[Ss]$ ]]
}

# =============================================================================
# FUNCAO: CONFIGURAR DNS
# =============================================================================

configure_dns() {
    print_header "CONFIGURANDO DNS"
    
    log_info "Removendo bloqueio do resolv.conf..."
    chattr -i /etc/resolv.conf 2>/dev/null
    
    log_info "Configurando DNS..."
    cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver $DC1_IP
search $DOMAIN_NAME
domain $DOMAIN_NAME
EOF
    
    log_info "Testando conectividade..."
    if ping -c 2 8.8.8.8 > /dev/null 2>&1; then
        log_success "Internet OK!"
    else
        log_error "Sem internet!"
        exit 1
    fi
    
    log_info "Testando DNS..."
    if nslookup google.com > /dev/null 2>&1; then
        log_success "DNS OK!"
    else
        log_warning "DNS com problemas, mas continuando..."
    fi
}

# =============================================================================
# FUNCAO: CONFIGURAR HOSTNAME E HOSTS
# =============================================================================

configure_hostname() {
    print_header "CONFIGURANDO HOSTNAME"
    
    log_info "Hostname: $FQDN"
    hostnamectl set-hostname "$FQDN" 2>/dev/null
    echo "$FQDN" > /etc/hostname
    
    log_info "Configurando /etc/hosts..."
    cat > /etc/hosts << EOF
127.0.0.1       localhost
127.0.1.1       $FQDN $HOSTNAME
$IP_ADDRESS     $FQDN $HOSTNAME
$DC1_IP         $DC1_FQDN
EOF
    
    log_success "Hostname configurado!"
}

# =============================================================================
# FUNCAO: VERIFICAR DC PRIMARIO
# =============================================================================

check_dc1() {
    print_header "VERIFICANDO DC PRIMARIO"
    
    log_info "DC Primario: $DC1_FQDN ($DC1_IP)"
    
    log_info "Testando ping..."
    if ! ping -c 2 $DC1_IP > /dev/null 2>&1; then
        log_error "DC1 nao acessivel!"
        exit 1
    fi
    log_success "DC1 acessivel"
    
    log_info "Testando resolucao DNS do DC1..."
    if host $DC1_FQDN > /dev/null 2>&1; then
        log_success "DNS do DC1 OK"
    else
        log_warning "DNS do DC1 nao resolve, adicionando ao hosts..."
        echo "$DC1_IP $DC1_FQDN" >> /etc/hosts
    fi
    
    log_info "Testando portas do AD..."
    for port in 135 139 389 445 464 636 3268 3269 88; do
        if nc -zv $DC1_IP $port 2>&1 | grep -q "succeeded"; then
            log_success "Porta $port OK"
        else
            log_warning "Porta $port nao acessivel"
        fi
    done
}

# =============================================================================
# FUNCAO: INSTALAR PACOTES
# =============================================================================

install_packages() {
    print_header "INSTALANDO PACOTES"
    
    log_info "Atualizando repositorios..."
    apt update -qq 2>/dev/null
    
    if [ $? -ne 0 ]; then
        log_warning "Usando mirror alternativo..."
        sed -i 's/br.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list
        apt update -qq 2>/dev/null
    fi
    
    log_info "Instalando pacotes..."
    export DEBIAN_FRONTEND=noninteractive
    
    apt install -y \
        samba \
        samba-ad-dc \
        samba-common-bin \
        samba-dsdb-modules \
        krb5-user \
        krb5-config \
        winbind \
        libpam-winbind \
        libnss-winbind \
        acl \
        attr \
        dnsutils \
        python3 \
        python3-samba \
        net-tools \
        ldap-utils \
        expect \
        chrony \
        2>&1 | grep -v "debconf"
    
    if command -v samba-tool &> /dev/null; then
        log_success "Samba instalado!"
        log_info "Versao: $(samba --version 2>/dev/null | head -1)"
    else
        log_error "Falha na instalacao do Samba!"
        exit 1
    fi
}

# =============================================================================
# FUNCAO: JOIN NO DOMINIO (CORRIGIDO)
# =============================================================================

join_domain() {
    print_header "JUNTANDO AO DOMINIO"
    
    log_info "Dominio: $DOMAIN_NAME"
    log_info "DC Primario: $DC1_FQDN ($DC1_IP)"
    log_info "Senha: ********"
    
    log_info "Parando servicos conflitantes..."
    systemctl stop smbd nmbd winbind 2>/dev/null
    systemctl disable smbd nmbd winbind 2>/dev/null
    systemctl mask smbd nmbd winbind 2>/dev/null
    
    if [ -f /etc/samba/smb.conf ]; then
        rm -f /etc/samba/smb.conf
    fi
    
    log_info "Testando autenticacao com DC1..."
    echo "$ADMIN_PASSWORD" | kinit administrator@"$REALM_NAME" 2>/dev/null
    
    if [ $? -eq 0 ]; then
        log_success "Autenticacao OK!"
    else
        log_warning "Falha na autenticacao, mas continuando..."
    fi
    
    log_info "Realizando join no dominio..."
    log_info "Isso pode levar alguns segundos..."
    
    # Metodo 1: Join com pipe (mais confiavel)
    echo "$ADMIN_PASSWORD" | samba-tool domain join $DOMAIN_NAME DC \
        -U administrator \
        --dns-backend=SAMBA_INTERNAL 2>&1 | tee -a "$LOG_FILE"
    
    # Verificar se funcionou
    if [ -f /var/lib/samba/private/secrets.ldb ]; then
        log_success "Join no dominio concluido com sucesso!"
        
        if [ -f /var/lib/samba/private/krb5.conf ]; then
            cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
        fi
        
        samba-tool domain exportkeytab /root/adadmin.keytab \
            --principal=administrator@"$REALM_NAME" 2>/dev/null
        chmod 600 /root/adadmin.keytab 2>/dev/null
        
        return 0
    fi
    
    # Metodo 2: Tentar com expect se falhou
    log_warning "Primeira tentativa falhou. Tentando com expect..."
    
    cat > /tmp/join.exp << 'EOF'
#!/usr/bin/expect -f
set timeout 60
set domain [lindex $argv 0]
set user [lindex $argv 1]
set password [lindex $argv 2]

log_user 1

spawn samba-tool domain join $domain DC -U $user --dns-backend=SAMBA_INTERNAL

expect {
    "Password" {
        send "$password\r"
        exp_continue
    }
    "ERROR" {
        puts "ERRO no join"
        exit 1
    }
    eof {
        puts "Join finalizado"
    }
}
EOF
    
    chmod +x /tmp/join.exp
    /tmp/join.exp "$DOMAIN_NAME" "administrator" "$ADMIN_PASSWORD"
    rm -f /tmp/join.exp
    
    # Verificar novamente
    if [ -f /var/lib/samba/private/secrets.ldb ]; then
        log_success "Join no dominio concluido (metodo 2)!"
        return 0
    fi
    
    log_error "Falha no join do dominio!"
    log_info "Tente manualmente:"
    echo ""
    echo "  samba-tool domain join $DOMAIN_NAME DC -U administrator --dns-backend=SAMBA_INTERNAL"
    echo "  (digite a senha quando solicitado)"
    echo ""
    
    exit 1
}

# =============================================================================
# FUNCAO: INICIAR SERVICOS
# =============================================================================

start_services() {
    print_header "INICIANDO SERVICOS"
    
    log_info "Iniciando samba-ad-dc..."
    systemctl unmask samba-ad-dc 2>/dev/null
    systemctl enable samba-ad-dc 2>/dev/null
    systemctl start samba-ad-dc 2>/dev/null
    
    sleep 5
    
    if systemctl is-active --quiet samba-ad-dc; then
        log_success "Samba AD DC rodando!"
        
        log_info "Portas abertas:"
        ss -tulpn 2>/dev/null | grep -E ":(135|139|389|445|464|636|3268|3269|88)\s" | grep LISTEN || log_warning "Nenhuma porta AD encontrada"
    else
        log_error "Falha ao iniciar samba-ad-dc!"
        systemctl status samba-ad-dc --no-pager
        exit 1
    fi
}

# =============================================================================
# FUNCAO: VERIFICAR REPLICACAO
# =============================================================================

check_replication() {
    print_header "VERIFICANDO REPLICACAO"
    
    log_info "Autenticando..."
    echo "$ADMIN_PASSWORD" | kinit administrator@"$REALM_NAME" 2>/dev/null
    
    if [ $? -eq 0 ]; then
        log_success "Autenticacao OK!"
    else
        log_warning "Falha na autenticacao"
    fi
    
    log_info "Status da replicacao:"
    echo ""
    samba-tool drs showrepl 2>/dev/null | head -20
    echo ""
    
    log_info "Testando DNS:"
    host -t A $FQDN 2>/dev/null || log_warning "DNS do $FQDN nao resolve"
    host -t A $DC1_FQDN 2>/dev/null || log_warning "DNS do $DC1_FQDN nao resolve"
}

# =============================================================================
# FUNCAO: CRIAR SCRIPTS AUXILIARES
# =============================================================================

create_scripts() {
    print_header "CRIANDO SCRIPTS AUXILIARES"
    
    # Script de teste
    cat > /root/test-ad.sh << EOF
#!/bin/bash
echo "=== TESTE DO AD (SECUNDARIO) ==="
echo ""

echo "1. SERVICO:"
systemctl status samba-ad-dc --no-pager | grep Active
echo ""

echo "2. REPLICACAO:"
samba-tool drs showrepl 2>/dev/null | grep "last success" | head -5
echo ""

echo "3. DOMINIO:"
samba-tool domain info 127.0.0.1 2>/dev/null | grep -E "Domain|Forest"
echo ""

echo "4. USUARIOS (primeiros 5):"
samba-tool user list 2>/dev/null | head -5
echo ""

echo "5. DNS:"
host $FQDN 2>/dev/null || echo "   Nao resolveu"
host $DC1_FQDN 2>/dev/null || echo "   Nao resolveu"
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

echo "Backup concluido" >> $LOG_FILE
EOF
    
    chmod +x /usr/local/bin/backup-ad.sh
    
    log_success "Scripts auxiliares criados!"
}

# =============================================================================
# FUNCAO: CONFIGURAR SSH
# =============================================================================

configure_ssh() {
    print_header "CONFIGURANDO SSH"
    
    log_info "Habilitando Root via SSH..."
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
# FUNCAO: CONFIGURAR AUTO-COMPLETE
# =============================================================================

setup_autocomplete() {
    print_header "CONFIGURANDO AUTO-COMPLETE"
    
    cat > /root/.bashrc << 'EOF'
# Auto-complete
bind 'set show-all-if-ambiguous on'
bind 'set completion-ignore-case on'
export HISTTIMEFORMAT="%F %T "

# Aliases
alias ad-status='systemctl status samba-ad-dc'
alias ad-users='samba-tool user list'
alias ad-groups='samba-tool group list'
alias ad-repl='samba-tool drs showrepl'
alias ad-test='/root/test-ad.sh'
alias ad-backup='/usr/local/bin/backup-ad.sh'
alias ad-logs='tail -f /var/log/samba/log.samba'
alias ad-ports='ss -tulpn | grep -E "135|139|389|445|464|636|3268|3269|88"'
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias update='apt update && apt upgrade -y'
alias install='apt install -y'
alias clean='apt autoremove -y && apt autoclean'
EOF
    
    log_success "Auto-complete configurado!"
}

# =============================================================================
# FUNCAO: RESUMO FINAL
# =============================================================================

show_summary() {
    print_header "CONFIGURACAO CONCLUIDA!"
    
    echo ""
    echo "====================================================================="
    echo "              INFORMACOES DO DOMINIO"
    echo "====================================================================="
    printf "  %-20s: %-40s\n" "Funcao" "Controlador Secundario"
    printf "  %-20s: %-40s\n" "Dominio" "$DOMAIN_NAME"
    printf "  %-20s: %-40s\n" "Servidor" "$FQDN"
    printf "  %-20s: %-40s\n" "IP" "$IP_ADDRESS"
    printf "  %-20s: %-40s\n" "DC Primario" "$DC1_FQDN ($DC1_IP)"
    printf "  %-20s: %-40s\n" "Usuario" "administrator@$REALM_NAME"
    printf "  %-20s: %-40s\n" "Senha AD" "$ADMIN_PASSWORD"
    echo "---------------------------------------------------------------------"
    printf "  %-20s: %-40s\n" "Script Teste" "/root/test-ad.sh"
    printf "  %-20s: %-40s\n" "Script Backup" "/usr/local/bin/backup-ad.sh"
    echo "====================================================================="
    
    echo ""
    echo "====================================================================="
    echo "                    COMANDOS UTEIS"
    echo "====================================================================="
    echo "  1. Verificar servico:"
    echo "     systemctl status samba-ad-dc"
    echo ""
    echo "  2. Verificar replicacao:"
    echo "     samba-tool drs showrepl"
    echo ""
    echo "  3. Executar testes:"
    echo "     /root/test-ad.sh"
    echo ""
    echo "  4. Testar autenticacao:"
    echo "     kinit administrator@$REALM_NAME"
    echo ""
    echo "  5. Forcar replicacao:"
    echo "     samba-tool drs replicate $FQDN $DC1_FQDN dc=$DOMAIN_NAME"
    echo "====================================================================="
    
    log_success "DC SECUNDARIO CONFIGURADO!"
}

# =============================================================================
# FUNCAO PRINCIPAL
# =============================================================================

main() {
    check_root
    
    clear
    echo "====================================================================="
    echo "                                                                     "
    echo "     ACTIVE DIRECTORY - CONTROLADOR SECUNDARIO                      "
    echo "     Versao: 1.4 - CORRIGIDO DEFINITIVO                             "
    echo "                                                                     "
    echo "     Join automatico no dominio                                     "
    echo "     SSH Root habilitado                                            "
    echo "                                                                     "
    echo "====================================================================="
    echo ""
    
    # MOSTRAR CONFIGURACOES
    echo "CONFIGURACOES:"
    echo "  Servidor: $HOSTNAME"
    echo "  Dominio: $DOMAIN_NAME"
    echo "  IP: $IP_ADDRESS"
    echo "  DC Primario: $DC1_FQDN ($DC1_IP)"
    echo "  Senha AD: ********"
    echo ""
    
    if ! confirm "Confirmar e iniciar configuracao?"; then
        log_info "Configuracao cancelada."
        exit 0
    fi
    
    log_info "Inicio: $(date)"
    log_info "Log: $LOG_FILE"
    echo ""
    
    # EXECUTAR ETAPAS
    configure_dns
    configure_ssh
    setup_autocomplete
    configure_hostname
    check_dc1
    install_packages
    join_domain
    start_services
    check_replication
    create_scripts
    
    show_summary
    
    if confirm "Reiniciar o servidor agora?"; then
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
