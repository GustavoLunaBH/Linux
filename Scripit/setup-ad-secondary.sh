#!/bin/bash
# =============================================================================
# Script: setup-ad-secondary.sh
# Versão: 1.3 - CORRIGIDO (DNS)
# Descrição: Configuração do Controlador Secundário
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
# FUNCAO: CONFIGURAR DNS (UMA VEZ SÓ)
# =============================================================================

configure_dns() {
    print_header "CONFIGURANDO DNS"
    
    log_info "Removendo bloqueio do resolv.conf..."
    chattr -i /etc/resolv.conf 2>/dev/null
    
    log_info "Configurando DNS com servidores publicos..."
    cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
    
    log_info "Testando conectividade com a internet..."
    
    # Testar primeiro o ping para IP (não depende de DNS)
    if ping -c 2 8.8.8.8 > /dev/null 2>&1; then
        log_success "Internet acessivel (ping 8.8.8.8 OK)"
    else
        log_error "Sem acesso a internet! Verifique sua rede."
        log_info "Gateway: $(ip route | grep default | awk '{print $3}')"
        exit 1
    fi
    
    log_info "Testando resolucao de DNS..."
    
    # Tentar resolver com nslookup
    if nslookup google.com 8.8.8.8 > /dev/null 2>&1; then
        log_success "DNS funcionando!"
    else
        log_warning "DNS com problemas, mas continuando..."
        log_info "Tentando ping para google.com..."
        
        if ping -c 2 google.com > /dev/null 2>&1; then
            log_success "DNS funcionando (ping google.com OK)"
        else
            log_error "DNS NAO esta funcionando!"
            log_info "Tente: echo 'nameserver 8.8.8.8' > /etc/resolv.conf"
            exit 1
        fi
    fi
}

# =============================================================================
# FUNCAO: VERIFICAR DC1
# =============================================================================

check_dc1() {
    print_header "VERIFICANDO DC PRIMARIO"
    
    log_info "Testando ping para DC1 ($DC1_IP)..."
    if ! ping -c 2 $DC1_IP > /dev/null 2>&1; then
        log_error "DC1 nao acessivel!"
        exit 1
    fi
    log_success "DC1 acessivel via ping"
    
    log_info "Testando portas do AD no DC1..."
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
nameserver 8.8.8.8
search $DOMAIN_NAME
domain $DOMAIN_NAME
EOF
    
    log_success "Hostname configurado!"
}

# =============================================================================
# FUNCAO: JUNTAR AO DOMINIO
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
    
    # Usar samba-tool com pipe
    echo "$ADMIN_PASSWORD" | samba-tool domain join $DOMAIN_NAME DC \
        -U administrator \
        --dns-backend=SAMBA_INTERNAL 2>&1 | tee -a "$LOG_FILE"
    
    if [ -f /var/lib/samba/private/secrets.ldb ]; then
        log_success "Join no dominio concluido!"
        
        if [ -f /var/lib/samba/private/krb5.conf ]; then
            cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
        fi
        
        samba-tool domain exportkeytab /root/adadmin.keytab \
            --principal=administrator@"$REALM_NAME" 2>/dev/null
        chmod 600 /root/adadmin.keytab 2>/dev/null
        
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
EOF
    
    chmod +x /root/test-ad.sh
    log_success "Scripts criados!"
}

# =============================================================================
# FUNCAO: CONFIGURAR SSH
# =============================================================================

configure_ssh() {
    print_header "CONFIGURANDO SSH"
    
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null
    sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null
    
    grep -q "^PermitRootLogin" /etc/ssh/sshd_config || echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
    
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    log_success "SSH Root habilitado!"
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
    echo "====================================================================="
    
    echo ""
    echo "====================================================================="
    echo "                    COMANDOS UTEIS"
    echo "====================================================================="
    echo "  1. Verificar servico: systemctl status samba-ad-dc"
    echo "  2. Verificar replicacao: samba-tool drs showrepl"
    echo "  3. Testar autenticacao: kinit administrator@$REALM_NAME"
    echo "  4. Executar testes: /root/test-ad.sh"
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
    echo "     Versao: 1.3 - CORRIGIDO                                        "
    echo "                                                                     "
    echo "     Join automatico no dominio                                     "
    echo "     SSH Root habilitado                                            "
    echo "                                                                     "
    echo "====================================================================="
    echo ""
    
    # CONFIGURAR DNS PRIMEIRO (UMA VEZ)
    configure_dns
    
    # COLETAR INFORMACOES
    collect_user_info
    
    log_info "Inicio: $(date)"
    log_info "Log: $LOG_FILE"
    echo ""
    
    # EXECUTAR ETAPAS
    check_dc1
    configure_ssh
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
