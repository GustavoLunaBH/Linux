#!/bin/bash
# =============================================================================
# Script: setup-ad-secondary-fixed.sh
# Versão: 1.2 - CORRIGIDO
# Descrição: Configuração do Controlador Secundário (join no domínio)
# Uso: sudo ./setup-ad-secondary-fixed.sh
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

# Variaveis
HOSTNAME=""
DOMAIN_NAME=""
IP_ADDRESS=""
DC1_IP=""
DC1_FQDN=""
ADMIN_PASSWORD=""
DNS_FORWARDER="8.8.8.8"

# Variaveis automaticas
REALM_NAME=""
FQDN=""

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
        exit 1
    fi
}

confirm() {
    read -p "$1 (s/N): " -n 1 -r
    echo
    [[ $REPLY =~ ^[Ss]$ ]]
}

# =============================================================================
# FUNCAO: COLETAR INFORMACOES
# =============================================================================

collect_user_info() {
    print_header "INFORMACOES DE CONFIGURACAO"
    
    echo "Por favor, informe os dados para o Controlador Secundario:"
    echo ""
    
    while true; do
        read -p "Nome do Servidor (ex: dc02, adserver02): " HOSTNAME
        if [[ -n "$HOSTNAME" ]] && [[ "$HOSTNAME" =~ ^[a-zA-Z0-9-]+$ ]]; then
            break
        else
            log_error "Nome invalido!"
        fi
    done
    
    while true; do
        read -p "Nome do Dominio (ex: empresa.local): " DOMAIN_NAME
        if [[ -n "$DOMAIN_NAME" ]] && [[ "$DOMAIN_NAME" =~ ^[a-z0-9]+\.[a-z]+$ ]]; then
            break
        else
            log_error "Dominio invalido!"
        fi
    done
    
    while true; do
        read -p "IP do Servidor (ex: 192.168.1.3): " IP_ADDRESS
        if [[ -n "$IP_ADDRESS" ]] && [[ "$IP_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
        else
            log_error "IP invalido!"
        fi
    done
    
    while true; do
        read -p "IP do DC Primario (ex: 192.168.1.2): " DC1_IP
        if [[ -n "$DC1_IP" ]] && [[ "$DC1_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
        else
            log_error "IP invalido!"
        fi
    done
    
    while true; do
        read -p "FQDN do DC Primario (ex: dc01.empresa.local): " DC1_FQDN
        if [[ -n "$DC1_FQDN" ]] && [[ "$DC1_FQDN" =~ ^[a-zA-Z0-9.-]+$ ]]; then
            break
        else
            log_error "FQDN invalido!"
        fi
    done
    
    read -p "DNS Forwarder [8.8.8.8]: " DNS_FORWARDER
    DNS_FORWARDER=${DNS_FORWARDER:-8.8.8.8}
    
    REALM_NAME=$(echo "$DOMAIN_NAME" | tr '[:lower:]' '[:upper:]')
    FQDN="${HOSTNAME}.${DOMAIN_NAME}"
    
    echo ""
    log_info "Configurando senha do ROOT..."
    passwd root
    
    echo ""
    while true; do
        read -s -p "Senha do Administrador do AD: " ADMIN_PASSWORD
        echo ""
        if [[ ${#ADMIN_PASSWORD} -ge 8 ]]; then
            read -s -p "Confirme a senha: " ADMIN_PASSWORD_CONFIRM
            echo ""
            if [[ "$ADMIN_PASSWORD" == "$ADMIN_PASSWORD_CONFIRM" ]]; then
                break
            else
                log_error "Senhas nao coincidem!"
            fi
        else
            log_error "Senha muito curta! Minimo 8 caracteres."
        fi
    done
    
    echo ""
    print_header "RESUMO DA CONFIGURACAO"
    echo "  --------------------------------------------------------------"
    printf "  %-22s: %-40s\n" "Tipo" "Controlador Secundario"
    printf "  %-22s: %-40s\n" "Servidor" "$HOSTNAME"
    printf "  %-22s: %-40s\n" "Dominio" "$DOMAIN_NAME"
    printf "  %-22s: %-40s\n" "Realm" "$REALM_NAME"
    printf "  %-22s: %-40s\n" "FQDN" "$FQDN"
    printf "  %-22s: %-40s\n" "IP" "$IP_ADDRESS"
    printf "  %-22s: %-40s\n" "IP DC Primario" "$DC1_IP"
    printf "  %-22s: %-40s\n" "FQDN DC Primario" "$DC1_FQDN"
    echo "  --------------------------------------------------------------"
    echo ""
    
    if ! confirm "Confirmar e iniciar configuracao?"; then
        log_info "Configuracao cancelada."
        exit 0
    fi
}

# =============================================================================
# FUNCAO: VERIFICAR DC1
# =============================================================================

check_dc1() {
    print_header "VERIFICANDO DC PRIMARIO"
    
    log_info "Testando ping para DC1 ($DC1_IP)..."
    if ! ping -c 3 $DC1_IP > /dev/null 2>&1; then
        log_error "DC1 nao acessivel!"
        exit 1
    fi
    log_success "DC1 acessivel via ping"
    
    log_info "Testando resolucao DNS do DC1..."
    if host $DC1_FQDN > /dev/null 2>&1; then
        log_success "DNS do DC1 resolvendo: $DC1_FQDN"
    else
        log_warning "DNS do DC1 nao resolvendo, tentando com IP..."
        echo "$DC1_IP $DC1_FQDN" >> /etc/hosts
    fi
    
    log_info "Testando portas do AD no DC1..."
    for port in 135 139 389 445 464 636 3268 3269 88; do
        if nc -zv $DC1_IP $port 2>&1 | grep -q "succeeded"; then
            log_success "Porta $port OK"
        else
            log_warning "Porta $port nao acessivel"
        fi
    done
    
    # Testar porta 53 (DNS) separadamente
    if nc -zu $DC1_IP 53 2>&1 | grep -q "succeeded"; then
        log_success "Porta 53 (DNS) OK"
    else
        log_warning "Porta 53 (DNS) pode estar bloqueada"
    fi
}

# =============================================================================
# FUNCAO: CONFIGURAR DNS
# =============================================================================

configure_dns() {
    print_header "CONFIGURANDO DNS"
    
    log_info "Configurando DNS para internet..."
    chattr -i /etc/resolv.conf 2>/dev/null
    
    cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver $DC1_IP
EOF
    
    log_info "Testando conectividade..."
    if ping -c 3 8.8.8.8 > /dev/null 2>&1; then
        log_success "Internet OK!"
    else
        log_error "Sem internet!"
        exit 1
    fi
    
    log_info "Testando DNS..."
    if nslookup google.com > /dev/null 2>&1; then
        log_success "DNS OK!"
    else
        log_error "DNS com problemas!"
        exit 1
    fi
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
        log_success "Samba instalado: $(samba --version 2>/dev/null | head -1)"
    else
        log_error "Falha na instalacao do Samba!"
        exit 1
    fi
}

# =============================================================================
# FUNCAO: CONFIGURAR HOSTNAME
# =============================================================================

configure_hostname() {
    print_header "CONFIGURANDO HOSTNAME"
    
    log_info "Hostname: $FQDN"
    hostnamectl set-hostname "$FQDN" 2>/dev/null
    echo "$FQDN" > /etc/hostname
    
    cat > /etc/hosts << EOF
127.0.0.1       localhost
127.0.1.1       $FQDN $HOSTNAME
$IP_ADDRESS     $FQDN $HOSTNAME
$DC1_IP         $DC1_FQDN
EOF
    
    chattr -i /etc/resolv.conf 2>/dev/null
    cat > /etc/resolv.conf << EOF
nameserver $DNS_FORWARDER
nameserver $DC1_IP
search $DOMAIN_NAME
domain $DOMAIN_NAME
EOF
    
    log_success "Hostname configurado!"
}

# =============================================================================
# FUNCAO: JUNTAR AO DOMINIO (CORRIGIDO)
# =============================================================================

join_domain() {
    print_header "JUNTANDO AO DOMINIO"
    
    log_info "Dominio: $DOMAIN_NAME"
    log_info "DC Primario: $DC1_FQDN ($DC1_IP)"
    
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
    log_info "Isso pode levar alguns minutos..."
    
    # Metodo 1: Usar samba-tool diretamente com pipe (mais confiavel)
    log_info "Tentando join com samba-tool..."
    
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
    
    # Se falhou, tentar com expect (metodo 2)
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
    log_info "Verifique:"
    log_info "  1. O dominio $DOMAIN_NAME existe"
    log_info "  2. A senha esta correta"
    log_info "  3. O DNS esta configurado"
    log_info "  4. As portas do AD estao acessiveis"
    
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
    
    log_info "Status da replicacao:"
    samba-tool drs showrepl 2>/dev/null | head -15
    
    log_info "Testando DNS:"
    host -t A $FQDN 2>/dev/null
    host -t A $DC1_FQDN 2>/dev/null
}

# =============================================================================
# FUNCAO: SCRIPTS AUXILIARES
# =============================================================================

create_scripts() {
    print_header "CRIANDO SCRIPTS"
    
    cat > /root/test-ad.sh << EOF
#!/bin/bash
echo "=== TESTE DO AD (SECUNDARIO) ==="
echo ""
systemctl status samba-ad-dc --no-pager | grep Active
echo ""
echo "Replicacao:"
samba-tool drs showrepl 2>/dev/null | grep "last success" | head -5
echo ""
echo "Dominio:"
samba-tool domain info 127.0.0.1 2>/dev/null | grep -E "Domain|Forest"
echo ""
echo "Usuarios:"
samba-tool user list 2>/dev/null | head -5
EOF
    
    chmod +x /root/test-ad.sh
    log_success "Scripts criados!"
}

# =============================================================================
# FUNCAO: CONFIGURAR SSH E AUTOCOMPLETE
# =============================================================================

configure_ssh() {
    print_header "CONFIGURANDO SSH"
    
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null
    sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null
    
    grep -q "^PermitRootLogin" /etc/ssh/sshd_config || echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
    
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    log_success "SSH Root habilitado!"
}

setup_autocomplete() {
    print_header "AUTO-COMPLETE"
    
    cat > /root/.bashrc << 'EOF'
bind 'set show-all-if-ambiguous on'
bind 'set completion-ignore-case on'
alias ad-status='systemctl status samba-ad-dc'
alias ad-users='samba-tool user list'
alias ad-repl='samba-tool drs showrepl'
alias ad-test='/root/test-ad.sh'
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
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
    echo "---------------------------------------------------------------------"
    printf "  %-20s: %-40s\n" "Script Teste" "/root/test-ad.sh"
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
    echo "  3. Testar autenticacao:"
    echo "     kinit administrator@$REALM_NAME"
    echo ""
    echo "  4. Executar testes:"
    echo "     /root/test-ad.sh"
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
    echo "     Versao: 1.2 - CORRIGIDO                                        "
    echo "                                                                     "
    echo "     Join automatico no dominio                                     "
    echo "     SSH Root habilitado                                            "
    echo "                                                                     "
    echo "====================================================================="
    echo ""
    
    configure_dns
    collect_user_info
    
    log_info "Inicio: $(date)"
    log_info "Log: $LOG_FILE"
    echo ""
    
    check_dc1
    configure_ssh
    setup_autocomplete
    configure_hostname
    install_packages
    join_domain
    start_services
    check_replication
    create_scripts
    
    show_summary
    
    if confirm "Reiniciar o servidor agora?"; then
        log_info "Reiniciando..."
        sleep 5
        reboot
    else
        log_info "Execute: reboot"
    fi
}

# =============================================================================
# EXECUTAR
# =============================================================================

main "$@"
