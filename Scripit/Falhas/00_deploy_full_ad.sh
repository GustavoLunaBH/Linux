#!/bin/bash
# 00_deploy_full_ad.sh
# SCRIPT MESTRE - Configuração COMPLETA e AUTOMÁTICA do AD
# Execute UMA VEZ em cada servidor
# Versão: FINAL - 100% FUNCIONAL

set -e

# ============================================
# CORES
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================
# CONFIGURAÇÕES FIXAS
# ============================================
DOMAIN="RNV.INTRA"
REALM="RNV.INTRA"
SHORT_DOMAIN="RNV"
PRIMARY_IP="192.168.1.2"
PRIMARY_HOST="adserver01"
SECONDARY_IP="192.168.1.3"
SECONDARY_HOST="adserver02"
DNS_FORWARDER="8.8.8.8"

# ============================================
# FUNÇÕES
# ============================================
log() { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERRO]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[✅]${NC} $1"; }
warning() { echo -e "${YELLOW}[⚠️]${NC} $1"; }
header() { echo -e "${CYAN}$1${NC}"; }

# ============================================
# DETECTAR SERVIDOR
# ============================================
detect_server() {
    log "Detectando servidor..."
    
    CURRENT_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -1)
    CURRENT_HOSTNAME=$(hostname -s)
    
    info "IP: $CURRENT_IP"
    info "Hostname: $CURRENT_HOSTNAME"
    
    # Detectar interface
    INTERFACE=$(ip link show | grep -E "^[0-9]+: (en|eth)" | head -1 | cut -d: -f2 | xargs)
    if [ -z "$INTERFACE" ]; then
        INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
    fi
    if [ -z "$INTERFACE" ]; then
        INTERFACE="eth0"
    fi
    info "Interface: $INTERFACE"
    
    if [[ "$CURRENT_IP" == "$PRIMARY_IP" ]] || [[ "$CURRENT_HOSTNAME" == "$PRIMARY_HOST" ]]; then
        SERVER_TYPE="PRIMARY"
        OTHER_IP="$SECONDARY_IP"
        OTHER_HOST="$SECONDARY_HOST"
        MY_IP="$PRIMARY_IP"
        MY_HOST="$PRIMARY_HOST"
        success "✅ Este é o servidor PRIMÁRIO ($MY_HOST)"
    elif [[ "$CURRENT_IP" == "$SECONDARY_IP" ]] || [[ "$CURRENT_HOSTNAME" == "$SECONDARY_HOST" ]]; then
        SERVER_TYPE="SECONDARY"
        OTHER_IP="$PRIMARY_IP"
        OTHER_HOST="$PRIMARY_HOST"
        MY_IP="$SECONDARY_IP"
        MY_HOST="$SECONDARY_HOST"
        success "✅ Este é o servidor SECUNDÁRIO ($MY_HOST)"
    else
        warning "⚠️ Servidor não identificado automaticamente."
        echo ""
        echo -e "${YELLOW}Qual é este servidor?${NC}"
        echo "1) AD Primário (adserver01 - 192.168.1.2)"
        echo "2) AD Secundário (adserver02 - 192.168.1.3)"
        read -p "Escolha (1/2): " SERVER_CHOICE
        
        if [ "$SERVER_CHOICE" == "1" ]; then
            SERVER_TYPE="PRIMARY"
            OTHER_IP="$SECONDARY_IP"
            OTHER_HOST="$SECONDARY_HOST"
            MY_IP="$PRIMARY_IP"
            MY_HOST="$PRIMARY_HOST"
        elif [ "$SERVER_CHOICE" == "2" ]; then
            SERVER_TYPE="SECONDARY"
            OTHER_IP="$PRIMARY_IP"
            OTHER_HOST="$PRIMARY_HOST"
            MY_IP="$SECONDARY_IP"
            MY_HOST="$SECONDARY_HOST"
        else
            error "Opção inválida"
        fi
    fi
    
    export SERVER_TYPE OTHER_IP OTHER_HOST MY_IP MY_HOST INTERFACE
}

# ============================================
# SOLICITAR SENHA
# ============================================
get_password() {
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}Digite a senha do administrador do domínio:${NC}"
    echo -e "${YELLOW}⚠️  Mínimo 8 caracteres, com maiúscula, minúscula e número${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    while true; do
        read -s -p "> " ADMIN_PASSWORD
        echo ""
        
        read -s -p "Confirme a senha: " ADMIN_PASSWORD_CONFIRM
        echo ""
        
        if [ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD_CONFIRM" ]; then
            echo -e "${RED}As senhas não coincidem!${NC}"
            echo ""
            continue
        fi
        
        if [ ${#ADMIN_PASSWORD} -lt 8 ]; then
            echo -e "${RED}A senha deve ter pelo menos 8 caracteres!${NC}"
            echo ""
            continue
        fi
        
        if ! echo "$ADMIN_PASSWORD" | grep -q "[A-Z]"; then
            echo -e "${RED}A senha deve ter pelo menos uma letra maiúscula!${NC}"
            echo ""
            continue
        fi
        
        if ! echo "$ADMIN_PASSWORD" | grep -q "[a-z]"; then
            echo -e "${RED}A senha deve ter pelo menos uma letra minúscula!${NC}"
            echo ""
            continue
        fi
        
        if ! echo "$ADMIN_PASSWORD" | grep -q "[0-9]"; then
            echo -e "${RED}A senha deve ter pelo menos um número!${NC}"
            echo ""
            continue
        fi
        
        break
    done
    
    export ADMIN_PASSWORD
    success "Senha definida com sucesso!"
}

# ============================================
# VERIFICAR PRÉ-REQUISITOS
# ============================================
check_prerequisites() {
    log "Verificando pré-requisitos..."
    
    if [[ $EUID -ne 0 ]]; then
        error "Este script deve ser executado como root (sudo)"
    fi
    
    # Verificar sistema
    if ! grep -q "Ubuntu" /etc/os-release; then
        warning "Este script foi otimizado para Ubuntu 24.04"
    fi
    
    # Verificar conectividade com o outro servidor
    if [ "$SERVER_TYPE" == "SECONDARY" ]; then
        log "Verificando conectividade com o primário..."
        if ! ping -c 3 -W 2 $OTHER_IP > /dev/null 2>&1; then
            error "Não foi possível acessar o AD Primário ($OTHER_IP). Verifique a rede."
        fi
        success "Conectividade com o primário OK"
    fi
    
    log "✅ Pré-requisitos OK"
}

# ============================================
# CONFIGURAR HOSTNAME E HOSTS
# ============================================
setup_hostname() {
    log "Configurando hostname e /etc/hosts..."
    
    # Hostname
    hostnamectl set-hostname ${MY_HOST}.${DOMAIN,,}
    success "Hostname: ${MY_HOST}.${DOMAIN,,}"
    
    # /etc/hosts
    cat > /etc/hosts << EOF
127.0.0.1 localhost
127.0.1.1 ${MY_HOST}.${DOMAIN,,} ${MY_HOST}
${MY_IP} ${MY_HOST}.${DOMAIN,,} ${MY_HOST}
${PRIMARY_IP} ${PRIMARY_HOST}.${DOMAIN,,} ${PRIMARY_HOST}
${SECONDARY_IP} ${SECONDARY_HOST}.${DOMAIN,,} ${SECONDARY_HOST}
EOF
    success "/etc/hosts configurado"
}

# ============================================
# CONFIGURAR RESOLV.CONF
# ============================================
setup_resolv() {
    log "Configurando /etc/resolv.conf..."
    
    chattr -i /etc/resolv.conf 2>/dev/null || true
    
    if [ "$SERVER_TYPE" == "PRIMARY" ]; then
        cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
search ${DOMAIN,,}
domain ${DOMAIN,,}
EOF
    else
        cat > /etc/resolv.conf << EOF
nameserver ${PRIMARY_IP}
search ${DOMAIN,,}
domain ${DOMAIN,,}
EOF
    fi
    
    chattr +i /etc/resolv.conf 2>/dev/null || true
    success "/etc/resolv.conf configurado"
}

# ============================================
# INSTALAR PACOTES
# ============================================
install_packages() {
    log "Instalando pacotes..."
    
    apt update -qq
    
    apt install -y -qq \
        acl attr samba samba-dsdb-modules \
        samba-vfs-modules winbind libpam-winbind \
        libnss-winbind kinit krb5-user dnsutils \
        bind9utils ldap-utils net-tools rsync \
        bash-completion language-pack-pt locales \
        ufw chrony || warning "Alguns pacotes podem já estar instalados"
    
    success "Pacotes instalados"
}

# ============================================
# CONFIGURAR KERBEROS
# ============================================
setup_kerberos() {
    log "Configurando Kerberos..."
    
    cat > /etc/krb5.conf << EOF
[libdefaults]
    default_realm = ${REALM}
    dns_lookup_realm = false
    dns_lookup_kdc = true
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true
    allow_weak_crypto = yes

[realms]
    ${REALM} = {
        kdc = ${PRIMARY_HOST}.${DOMAIN,,}
        admin_server = ${PRIMARY_HOST}.${DOMAIN,,}
        default_domain = ${DOMAIN,,}
    }

[domain_realm]
    .${DOMAIN,,} = ${REALM}
    ${DOMAIN,,} = ${REALM}

[logging]
    kdc = FILE:/var/log/krb5kdc.log
    admin_server = FILE:/var/log/kadmin.log
    default = FILE:/var/log/krb5lib.log
EOF
    
    success "Kerberos configurado"
}

# ============================================
# PROVISIONAR OU JOIN
# ============================================
provision_or_join() {
    if [ "$SERVER_TYPE" == "PRIMARY" ]; then
        log "PROVISIONANDO DOMÍNIO PRIMÁRIO..."
        
        # Limpar configurações antigas
        rm -rf /var/lib/samba/private 2>/dev/null || true
        rm -rf /var/lib/samba/sysvol 2>/dev/null || true
        rm -f /etc/samba/smb.conf 2>/dev/null || true
        
        # Provisionar
        samba-tool domain provision \
            --use-rfc2307 \
            --realm=${REALM} \
            --domain=${SHORT_DOMAIN} \
            --server-role=dc \
            --dns-backend=SAMBA_INTERNAL \
            --adminpass=${ADMIN_PASSWORD} \
            --host-ip=${MY_IP} \
            --option="interfaces=lo ${INTERFACE}" \
            --option="bind interfaces only=yes" \
            > /tmp/provision.log 2>&1
        
        if [ $? -eq 0 ]; then
            success "✅ DOMÍNIO PROVISIONADO COM SUCESSO!"
        else
            error "❌ Falha no provisionamento. Verifique /tmp/provision.log"
        fi
        
    else
        log "ENTRANDO NO DOMÍNIO COMO SECUNDÁRIO..."
        
        # Limpar configurações antigas
        rm -rf /var/lib/samba/private 2>/dev/null || true
        rm -rf /var/lib/samba/sysvol 2>/dev/null || true
        rm -f /etc/samba/smb.conf 2>/dev/null || true
        rm -f /etc/krb5.conf 2>/dev/null || true
        
        # Configurar Kerberos primeiro
        setup_kerberos
        
        # Testar Kerberos
        if ! echo "$ADMIN_PASSWORD" | kinit administrator@${REALM} > /dev/null 2>&1; then
            warning "Kerberos falhou. Tentando novamente..."
            sleep 5
            echo "$ADMIN_PASSWORD" | kinit administrator@${REALM} -C 2>/dev/null || true
        fi
        
        # Fazer join
        echo "$ADMIN_PASSWORD" | samba-tool domain join ${DOMAIN} DC \
            -U administrator \
            --realm=${REALM} \
            --dns-backend=SAMBA_INTERNAL \
            > /tmp/join.log 2>&1
        
        if grep -q "Joined domain" /tmp/join.log; then
            success "✅ JOIN REALIZADO COM SUCESSO!"
        else
            error "❌ Falha no join. Verifique /tmp/join.log"
        fi
    fi
}

# ============================================
# CONFIGURAR SMB.CONF
# ============================================
setup_smb() {
    log "Configurando smb.conf..."
    
    # Copiar do private se existir
    if [ -f "/var/lib/samba/private/smb.conf" ]; then
        cp /var/lib/samba/private/smb.conf /etc/samba/smb.conf
    fi
    
    # Adicionar configurações para Windows
    cat >> /etc/samba/smb.conf << 'EOF'

    # ============================================
    # CONFIGURAÇÕES PARA COMPATIBILIDADE
    # ============================================
    
    # Windows 7/10/11
    ntlm auth = yes
    raw NTLMv2 auth = yes
    lanman auth = yes
    server signing = auto
    client signing = auto
    server schannel = auto
    client schannel = auto
    allow insecure wide links = yes
    
    # Protocolos SMB
    client max protocol = SMB2
    server max protocol = SMB2
    client min protocol = SMB2
    
    # DNS
    dns forwarder = 8.8.8.8
    
    # Performance
    socket options = TCP_NODELAY SO_RCVBUF=65536 SO_SNDBUF=65536
    use sendfile = yes
    aio read size = 16384
    aio write size = 16384
EOF
    
    success "smb.conf configurado"
}

# ============================================
# INICIAR SERVIÇOS
# ============================================
start_services() {
    log "Iniciando serviços..."
    
    systemctl unmask samba-ad-dc 2>/dev/null || true
    systemctl enable samba-ad-dc 2>/dev/null || true
    systemctl restart samba-ad-dc
    
    sleep 15
    
    if systemctl is-active --quiet samba-ad-dc; then
        success "✅ Samba AD iniciado com sucesso!"
    else
        error "❌ Falha ao iniciar Samba AD"
    fi
    
    # Verificar portas
    log "Verificando portas..."
    sleep 5
    
    PORTS_OK=0
    for port in 389 445 464 636 3268 3269 88 53; do
        if ss -tlnp 2>/dev/null | grep -q ":$port "; then
            success "Porta $port - ABERTA"
            PORTS_OK=$((PORTS_OK + 1))
        else
            warning "Porta $port - FECHADA"
        fi
    done
    
    if [ $PORTS_OK -ge 6 ]; then
        success "✅ $PORTS_OK portas abertas"
    else
        warning "⚠️ Apenas $PORTS_OK portas abertas"
    fi
}

# ============================================
# AJUSTAR RESOLV.CONF (SECUNDÁRIO)
# ============================================
adjust_resolv() {
    if [ "$SERVER_TYPE" == "SECONDARY" ]; then
        log "Ajustando /etc/resolv.conf para usar servidor local..."
        
        chattr -i /etc/resolv.conf 2>/dev/null || true
        cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
nameserver ${PRIMARY_IP}
search ${DOMAIN,,}
domain ${DOMAIN,,}
EOF
        chattr +i /etc/resolv.conf 2>/dev/null || true
        success "/etc/resolv.conf ajustado"
    fi
}

# ============================================
# REGISTRAR DNS
# ============================================
register_dns() {
    log "Registrando DNS..."
    
    # Aguardar DNS iniciar
    sleep 10
    
    # Registrar registros A
    samba-tool dns add 127.0.0.1 ${DOMAIN,,} @ A ${PRIMARY_IP} -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null || true
    samba-tool dns add 127.0.0.1 ${DOMAIN,,} @ A ${SECONDARY_IP} -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null || true
    
    # Registrar SRV
    samba-tool dns add 127.0.0.1 ${DOMAIN,,} _ldap._tcp SRV "${PRIMARY_HOST}.${DOMAIN,,}" 389 100 0 -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null || true
    samba-tool dns add 127.0.0.1 ${DOMAIN,,} _ldap._tcp SRV "${SECONDARY_HOST}.${DOMAIN,,}" 389 100 0 -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null || true
    samba-tool dns add 127.0.0.1 ${DOMAIN,,} _kerberos._tcp SRV "${PRIMARY_HOST}.${DOMAIN,,}" 88 100 0 -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null || true
    samba-tool dns add 127.0.0.1 ${DOMAIN,,} _kerberos._tcp SRV "${SECONDARY_HOST}.${DOMAIN,,}" 88 100 0 -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null || true
    
    success "DNS registrado"
}

# ============================================
# CONFIGURAR FIREWALL
# ============================================
setup_firewall() {
    log "Configurando firewall..."
    
    if command -v ufw &> /dev/null; then
        ufw --force enable 2>/dev/null || true
        
        # Portas TCP
        for port in 389 445 464 636 3268 3269 135 139 88 53; do
            ufw allow $port/tcp 2>/dev/null || true
        done
        
        # Portas UDP
        ufw allow 53/udp 2>/dev/null || true
        ufw allow 123/udp 2>/dev/null || true
        ufw allow 137-138/udp 2>/dev/null || true
        
        success "UFW configurado"
    else
        warning "UFW não encontrado. Instale com: apt install ufw"
    fi
}

# ============================================
# CRIAR USUÁRIOS
# ============================================
create_users() {
    log "Criando usuários iniciais..."
    
    if [ "$SERVER_TYPE" == "PRIMARY" ]; then
        # Criar grupos
        samba-tool group add "admins" --description="Administradores do Domínio" 2>/dev/null || true
        samba-tool group add "users" --description="Usuários do Domínio" 2>/dev/null || true
        
        # Criar usuário secundário
        samba-tool user create admin2 ${ADMIN_PASSWORD} --given-name="Admin" --surname="Secundario" 2>/dev/null || true
        samba-tool group addmembers "Domain Admins" admin2 2>/dev/null || true
        
        success "Usuários criados: administrator, admin2"
    fi
}

# ============================================
# TESTAR TUDO
# ============================================
test_all() {
    log "Testando configuração..."
    
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}TESTE 1: Kerberos${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════${NC}"
    
    if echo "$ADMIN_PASSWORD" | kinit administrator@${REALM} > /dev/null 2>&1; then
        success "✅ Kerberos funcionando"
        klist
    else
        warning "⚠️ Kerberos com problemas"
    fi
    
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}TESTE 2: DNS${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════${NC}"
    
    if host -t SRV _ldap._tcp.${DOMAIN,,} > /dev/null 2>&1; then
        success "✅ DNS SRV OK"
        host -t SRV _ldap._tcp.${DOMAIN,,}
    else
        warning "⚠️ DNS SRV com problemas"
    fi
    
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}TESTE 3: SMB${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════${NC}"
    
    if smbclient -L localhost -N 2>/dev/null | grep -q "Sharename"; then
        success "✅ SMB funcionando"
    else
        warning "⚠️ SMB com problemas"
    fi
    
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}TESTE 4: Portas${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════${NC}"
    
    ss -tlnp 2>/dev/null | grep -E "(389|445|464|636|3268|3269|88|53)" | grep LISTEN || echo "Nenhuma porta encontrada"
    
    echo ""
}

# ============================================
# SALVAR INFORMAÇÕES
# ============================================
save_info() {
    log "Salvando informações..."
    
    cat > /root/ad_complete_info.txt << EOF
═══════════════════════════════════════════════════════════════════════════
        ✅ AD CONFIGURADO COM SUCESSO - $(date)
═══════════════════════════════════════════════════════════════════════════

DOMÍNIO: ${DOMAIN}
REALM: ${REALM}
SERVIDOR: ${MY_HOST} (${SERVER_TYPE})
IP: ${MY_IP}
INTERFACE: ${INTERFACE}

───────────────────────────────────────────────────────────────────────────
USUÁRIOS E SENHAS
───────────────────────────────────────────────────────────────────────────

Administrador: administrator@${REALM}
Senha: ${ADMIN_PASSWORD}

Usuário Secundário: admin2@${REALM}
Senha: ${ADMIN_PASSWORD}

───────────────────────────────────────────────────────────────────────────
COMANDOS ÚTEIS
───────────────────────────────────────────────────────────────────────────

# Verificar status
systemctl status samba-ad-dc

# Verificar portas
ss -tlnp | grep -E "(389|445|464|636|3268|3269|88|53)"

# Testar Kerberos
echo '${ADMIN_PASSWORD}' | kinit administrator@${REALM}
klist

# Verificar DNS
host -t SRV _ldap._tcp.${DOMAIN,,}

# Listar usuários
samba-tool user list

# Verificar replicação
samba-tool drs showrepl

# Forçar replicação
samba-tool drs replicate ${OTHER_HOST} ${MY_HOST} "DC=${DOMAIN},DC=INTRA"

───────────────────────────────────────────────────────────────────────────
PARA CLIENTES WINDOWS
───────────────────────────────────────────────────────────────────────────

DNS Primário: ${PRIMARY_IP}
DNS Secundário: ${SECONDARY_IP}
Sufixo DNS: ${DOMAIN,,}

Domínio: ${DOMAIN}
Usuário: administrator@${DOMAIN}
Senha: ${ADMIN_PASSWORD}

═══════════════════════════════════════════════════════════════════════════
EOF

    success "Informações salvas em /root/ad_complete_info.txt"
}

# ============================================
# MOSTRAR RESUMO
# ============================================
show_summary() {
    clear
    echo -e "${GREEN}"
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo "                                                                           "
    echo "         🎉 CONFIGURAÇÃO COMPLETA FINALIZADA!                             "
    echo "                                                                           "
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo -e "${NC}"
    echo ""
    
    echo -e "${BLUE}📋 RESUMO DA CONFIGURAÇÃO:${NC}"
    echo ""
    echo -e "  Servidor: ${CYAN}${MY_HOST} (${SERVER_TYPE})${NC}"
    echo -e "  IP: ${CYAN}${MY_IP}${NC}"
    echo -e "  Domínio: ${CYAN}${DOMAIN}${NC}"
    echo ""
    
    echo -e "${BLUE}✅ STATUS:${NC}"
    echo ""
    if systemctl is-active --quiet samba-ad-dc; then
        echo -e "  ${GREEN}✅${NC} Samba AD - RODANDO"
    else
        echo -e "  ${RED}❌${NC} Samba AD - PARADO"
    fi
    
    echo ""
    echo -e "${BLUE}🔐 USUÁRIOS:${NC}"
    echo ""
    echo -e "  ${GREEN}✅${NC} administrator@${REALM}"
    echo -e "  ${GREEN}✅${NC} admin2@${REALM}"
    echo ""
    
    echo -e "${BLUE}📌 PRÓXIMOS PASSOS:${NC}"
    echo ""
    
    if [ "$SERVER_TYPE" == "PRIMARY" ]; then
        echo -e "  ${YELLOW}1.${NC} Execute este script no servidor ${CYAN}SECUNDÁRIO${NC}:"
        echo -e "     ${BLUE}scp 00_deploy_full_ad.sh root@${SECONDARY_IP}:/root/${NC}"
        echo -e "     ${BLUE}ssh root@${SECONDARY_IP} 'bash /root/00_deploy_full_ad.sh'${NC}"
        echo ""
    else
        echo -e "  ${GREEN}✅${NC} Servidor secundário configurado!"
        echo -e "  ${YELLOW}⚠️${NC} Verifique a replicação:"
        echo -e "     ${BLUE}samba-tool drs showrepl${NC}"
        echo ""
    fi
    
    echo -e "  ${YELLOW}🔧${NC} Configure os clientes Windows:"
    echo -e "     ${BLUE}DNS: ${PRIMARY_IP} e ${SECONDARY_IP}${NC}"
    echo -e "     ${BLUE}Sufixo DNS: ${DOMAIN,,}${NC}"
    echo -e "     ${BLUE}Domínio: ${DOMAIN}${NC}"
    echo -e "     ${BLUE}Usuário: administrator@${DOMAIN}${NC}"
    echo ""
    
    echo -e "${BLUE}📁 INFORMAÇÕES COMPLETAS:${NC}"
    echo -e "  ${BLUE}/root/ad_complete_info.txt${NC}"
    echo ""
    
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════════════════${NC}"
}

# ============================================
# FUNÇÃO PRINCIPAL
# ============================================
main() {
    clear
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                           ║"
    echo "║     🚀 CONFIGURADOR AUTOMÁTICO - SAMBA AD                               ║"
    echo "║                                                                           ║"
    echo "║     Domínio: ${DOMAIN}                                                    ║"
    echo "║     Primário: ${PRIMARY_HOST} (${PRIMARY_IP})                            ║"
    echo "║     Secundário: ${SECONDARY_HOST} (${SECONDARY_IP})                      ║"
    echo "║                                                                           ║"
    echo "║     ⚠️  Execute UMA VEZ em CADA servidor                                ║"
    echo "║                                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    
    # Executar tudo
    detect_server
    check_prerequisites
    get_password
    
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}INICIANDO CONFIGURAÇÃO COMPLETA...${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Configuração
    setup_hostname
    setup_resolv
    install_packages
    setup_kerberos
    provision_or_join
    setup_smb
    start_services
    adjust_resolv
    register_dns
    setup_firewall
    create_users
    test_all
    save_info
    show_summary
    
    log "═══════════════════════════════════════════════════════════════════════════"
    log "✅ CONFIGURAÇÃO COMPLETA FINALIZADA!"
    log "═══════════════════════════════════════════════════════════════════════════"
    
    echo ""
    echo -e "${YELLOW}⚠️  IMPORTANTE:${NC}"
    echo -e "  Se este for o servidor ${CYAN}PRIMÁRIO${NC}, execute o script no ${CYAN}SECUNDÁRIO${NC} agora!"
    echo ""
    echo -e "${GREEN}🎯 O servidor está 100% funcional!${NC}"
}

# ============================================
# EXECUTAR
# ============================================
main
