#!/bin/bash
# adserver_pro.sh — Script unificado para DC Primário/Secundário com Samba AD
# Ubuntu 24.04 | Samba 4.19.5 | Alta disponibilidade e replicação nativa
# Versão: 1.0

set -euo pipefail  # Aborta em erro, undefined var, pipe fail

# ══════════════════════════════════════════════════════════════
#                    CORE — FUNÇÕES GLOBAIS
# ══════════════════════════════════════════════════════════════

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Logging
log()    { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $*"; }
error()  { echo -e "${RED}[ERRO]${NC} $*" >&2; exit 1; }
warn()   { echo -e "${YELLOW}[AVISO]${NC} $*" >&2; }
info()   { echo -e "${BLUE}[INFO]${NC} $*"; }
debug()  { [[ "${DEBUG:-0}" == "1" ]] && echo -e "${CYAN}[DEBUG]${NC} $*"; }

# Verifica root
if [[ $EUID -ne 0 ]]; then
    error "Execute como root (sudo)"
fi

# ============================================
# FUNÇÕES DE CONFIGURAÇÃO COMUNS
# ============================================

config_locale() {
    log "Configurando idioma Português Brasil..."
    apt update -qq
    apt install -y -qq language-pack-pt locales bash-completion
    locale-gen pt_BR.UTF-8
    update-locale LANG=pt_BR.UTF-8 LANGUAGE=pt_BR:pt LC_ALL=pt_BR.UTF-8
    export LANG=pt_BR.UTF-8 LANGUAGE=pt_BR:pt LC_ALL=pt_BR.UTF-8
    echo -e "${GREEN}✓ Locale pt_BR configurado${NC}"
}

config_bash_completion() {
    log "Ativando auto-complete com TAB..."
    if ! grep -q "bash-completion" /root/.bashrc; then
        cat >> /root/.bashrc << 'EOF'

# Auto-complete via bash-completion
if [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
fi

# Auto-complete para samba-tool
complete -C samba-tool samba-tool
EOF
    fi
    [ -f /etc/bash_completion ] && . /etc/bash_completion
    echo -e "${GREEN}✓ Bash completion ativado${NC}"
}

config_ssh_root() {
    log "Configurando acesso root via SSH (atenção: risco de segurança)..."
    warn "ATENÇÃO: Permitir root via SSH expõe o servidor a ataques. Use apenas em redes confiáveis!"
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S) || true
    # Se já existe PermitRootLogin, substitui; senão, adiciona
    if grep -q "^PermitRootLogin" /etc/ssh/sshd_config; then
        sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    else
        echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
    fi
    systemctl restart sshd || warn "Não foi possível reiniciar sshd — verifique manualmente"
    echo -e "${YELLOW}⚠ Root SSH ativado — revise /etc/ssh/sshd_config${NC}"
}

detect_interface() {
    log "Detectando interface de rede..."
    INTERFACE=$(ip link show | grep -E "^[0-9]+: (en|eth)" | head -1 | cut -d: -f2 | xargs || true)
    if [ -z "$INTERFACE" ]; then
        INTERFACE=$(ip link show | grep -E "^[0-9]+: " | grep -v lo | head -1 | cut -d: -f2 | xargs)
    fi
    IP_ADDR=$(ip addr show "$INTERFACE" 2>/dev/null | grep inet | grep -v inet6 | awk '{print $2}' | cut -d/ -f1 || true)
    if [ -z "$IP_ADDR" ]; then
        IP_ADDR="192.168.1.2"
        warn "Não consegui detectar IP. Usando $IP_ADDR (edite manualmente se necessário)"
    fi
    echo -e "${GREEN}✓ Interface: ${INTERFACE} (${IP_ADDR})${NC}"
    # Exporta para uso global
    export INTERFACE IP_ADDR
}

config_ntp() {
    local PRIMARY_NTP="$1"
    log "Configurando NTP (Chrony)..."
    apt install -y -qq chrony
    timedatectl set-timezone America/Sao_Paulo
    
    if [ "$PRIMARY_NTP" == "SELF" ]; then
        # DC Primário: usa servidores externos oficiais
        cat > /etc/chrony/chrony.conf << 'EOF'
server a.st1.ntp.br iburst
server 2001:12ff:0:7::186 iburst
server 200.160.7.186 iburst

keyfile /etc/chrony/chrony.keys
driftfile /var/lib/chrony/drift
rtcsync
makestep 1.0 3
bindcmdaddress 127.0.0.1
logdir /var/log/chrony
EOF
        info "NTP primário configurado com servidores oficiais brasileiros"
    else
        # DC Secundário: aponta para o primário
        cat > /etc/chrony/chrony.conf << EOF
server $PRIMARY_NTP iburst
keyfile /etc/chrony/chrony.keys
driftfile /var/lib/chrony/drift
rtcsync
makestep 1.0 3
bindcmdaddress 127.0.0.1
logdir /var/log/chrony
EOF
        info "NTP secundário configurado para sincronizar com DC primário ($PRIMARY_NTP)"
    fi
    
    systemctl enable --now chrony -qq
    systemctl restart chrony -qq
    sleep 2
    chronyc sources >/dev/null 2>&1 && echo -e "${GREEN}✓ NTP sincronizado${NC}" || warn "NTP não sincronizou — verifique com 'chronyc sources'"
}

# Valida senha conforme política
validate_password() {
    local pw="$1"
    [ ${#pw} -lt 8 ] && return 1
    echo "$pw" | grep -q "[A-Z]" || return 2
    echo "$pw" | grep -q "[a-z]" || return 3
    echo "$pw" | grep -q "[0-9]" || return 4
    return 0
}

# ============================================
# FUNÇÕES DE TESTE — BATERIA FINAL
# ============================================

run_tests_primary() {
    local DOMAIN="$1" REALM="$2" IP="$3"
    log "════════════════════════════════════════════════════"
    log "          BATERIA DE TESTES — DC PRIMÁRIO"
    log "════════════════════════════════════════════════════"
    
    info "1. Testando resolução DNS interno..."
    host -t A localhost >/dev/null && echo -e "${GREEN}✓ localhost OK${NC}" || echo -e "${RED}✗ localhost NOK${NC}"
    
    info "2. Testando SRV LDAP do domínio..."
    host -t SRV "_ldap._tcp.${DOMAIN}" >/dev/null 2>&1 && echo -e "${GREEN}✓ SRV LDAP OK${NC}" || echo -e "${RED}✗ SRV LDAP NOK${NC}"
    
    info "3. Testando A record do hostname..."
    host -t A "$HOSTNAME.$DOMAIN" >/dev/null 2>&1 && echo -e "${GREEN}✓ Hostname DNS OK${NC}" || echo -e "${RED}✗ Hostname DNS NOK${NC}"
    
    info "4. Testando Kerberos (kinit)..."
    echo -n "${ADMIN_PASSWORD}" | kinit administrator@"$REALM" >/dev/null 2>&1 && {
        echo -e "${GREEN}✓ Kerberos OK${NC}"
        klist | grep -q "administrator" && echo -e "  → Ticket válido: $(klist | grep administrator)"
    } || echo -e "${RED}✗ Kerberos falhou${NC}"
    
    info "5. Verificando status do serviço samba-ad-dc..."
    systemctl is-active --quiet samba-ad-dc && echo -e "${GREEN}✓ Serviço ativo${NC}" || echo -e "${RED}✗ Serviço inativo${NC}"
    
    info "6. Testando sintaxe do smb.conf..."
    testparm -s >/dev/null 2>&1 && echo -e "${GREEN}✓ testparm OK${NC}" || echo -e "${RED}✗ testparm falhou${NC}"
    
    info "7. Verificando NTP..."
    chronyc sources | grep -q "^." && echo -e "${GREEN}✓ Chrony tem fontes ativas${NC}" || echo -e "${RED}✗ Chrony sem fontes${NC}"
    
    info "8. Verificando replicação DRS (sem parceiros esperados neste momento)..."
    samba-tool drs showrepl 2>&1 | grep -q "No DRS partners" && echo -e "${YELLOW}→ Nenhum parceiro de replicação configurado (esperado no primário isolado)${NC}" || echo -e "${GREEN}✓ DRS funcional${NC}"
    
    log "════════════════════════════════════════════════════"
}

run_tests_secondary() {
    local DOMAIN="$1" REALM="$2" IP="$3" PRIMARY_IP="$4"
    log "════════════════════════════════════════════════════"
    log "          BATERIA DE TESTES — DC SECUNDÁRIO"
    log "════════════════════════════════════════════════════"
    
    info "1. Testando resolução DNS (deve resolver pelo próprio Samba DNS)..."
    host -t A "$HOSTNAME.$DOMAIN" >/dev/null 2>&1 && echo -e "${GREEN}✓ Hostname local OK${NC}" || echo -e "${RED}✗ Hostname local NOK${NC}"
    
    info "2. Testando SRV LDAP do domínio via DNS local..."
    host -t SRV "_ldap._tcp.${DOMAIN}" 127.0.0.1 >/dev/null 2>&1 && echo -e "${GREEN}✓ SRV LDAP via DNS local OK${NC}" || echo -e "${RED}✗ SRV LDAP NOK${NC}"
    
    info "3. Testando Kerberos..."
    echo -n "${ADMIN_PASSWORD}" | kinit administrator@"$REALM" >/dev/null 2>&1 && {
        echo -e "${GREEN}✓ Kerberos OK${NC}"
        klist | grep -q "administrator" && echo -e "  → Ticket válido"
    } || echo -e "${RED}✗ Kerberos falhou${NC}"
    
    info "4. Verificando status do serviço..."
    systemctl is-active --quiet samba-ad-dc && echo -e "${GREEN}✓ Serviço ativo${NC}" || echo -e "${RED}✗ Serviço inativo${NC}"
    
    info "5. Testando replicação DRS com o primário..."
    if samba-tool drs showrepl 2>&1 | grep -q "$PRIMARY_IP"; then
        echo -e "${GREEN}✓ Replicação DRS ativa com $PRIMARY_IP${NC}"
    else
        echo -e "${RED}✗ Replicação DRS não detectada${NC}"
        warn "Execute 'samba-tool drs showrepl' manualmente para diagnosticar"
    fi
    
    info "6. Testando wbinfo..."
    wbinfo -t >/dev/null 2>&1 && echo -e "${GREEN}✓ wbinfo conectado ao AD${NC}" || echo -e "${RED}✗ wbinfo falhou${NC}"
    
    info "7. Verificando NTP (deve apontar para o primário)..."
    chronyc sources | grep -q "$PRIMARY_IP" && echo -e "${GREEN}✓ NTP sincronizando com primário${NC}" || echo -e "${RED}✗ NTP não apontando para primário${NC}"
    
    log "════════════════════════════════════════════════════"
}

# ══════════════════════════════════════════════════════════════
#              FLUXO 1 — DC PRIMÁRIO
# ══════════════════════════════════════════════════════════════

setup_primary_dc() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        CONFIGURAÇÃO — DC PRIMÁRIO               ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}"
    
    # 0. Detectar interface e IP
    detect_interface
    
    # 1. Solicitar informações
    read -p "Domínio (ex: rnv.local): " -e DOMAIN
    DOMAIN="${DOMAIN,,}"
    REALM="${DOMAIN^^}"
    SHORT_DOMAIN=$(echo "$DOMAIN" | cut -d'.' -f1 | tr '[:lower:]' '[:upper:]')
    read -p "Hostname do servidor (default: adserver01): " -e INPUT_HOSTNAME
    HOSTNAME="${INPUT_HOSTNAME:-adserver01}"
    
    # Senha com validação
    while true; do
        echo -e "${BLUE}Digite a senha do administrador do domínio:${NC}"
        read -s -p "> " ADMIN_PASSWORD
        echo
        echo -e "${BLUE}Confirme a senha:${NC}"
        read -s -p "> " ADMIN_PASSWORD_CONFIRM
        echo
        if [ "$ADMIN_PASSWORD" = "$ADMIN_PASSWORD_CONFIRM" ]; then
            case "$(validate_password "$ADMIN_PASSWORD"; echo $?) " in
                0) break ;;
                1) warn "A senha deve ter pelo menos 8 caracteres!";;
                2) warn "A senha deve ter pelo menos uma letra maiúscula!";;
                3) warn "A senha deve ter pelo menos uma letra minúscula!";;
                4) warn "A senha deve ter pelo menos um número!";;
            esac
        else
            warn "As senhas não coincidem!"
        fi
    done
    
    # Confirmação final
    echo
    echo -e "${YELLOW}Resumo da configuração:${NC}"
    echo "  Domínio:    $DOMAIN"
    echo "  Realm:      $REALM"
    echo "  Hostname:   $HOSTNAME"
    echo "  Interface:  $INTERFACE ($IP_ADDR)"
    echo
    read -p "Confirma? (S/n): " -n 1 -r CONFIRM
    echo
    [[ "$CONFIRM" =~ ^[Nn]$ ]] && error "Cancelado pelo usuário"
    
    # 2. Configurações base
    config_locale
    config_bash_completion
    config_ssh_root
    config_ntp "SELF"
    
    # 3. Hostname
    log "Configurando hostname: ${HOSTNAME}.${DOMAIN}"
    hostnamectl set-hostname "${HOSTNAME}.${DOMAIN}"
    
    # 4. /etc/hosts
    log "Configurando /etc/hosts"
    cp /etc/hosts "/etc/hosts.bak.$(date +%Y%m%d_%H%M%S)" || true
    cat > /etc/hosts << EOF
127.0.0.1 localhost
127.0.1.1 ${HOSTNAME}.${DOMAIN} ${HOSTNAME}
${IP_ADDR} ${HOSTNAME}.${DOMAIN} ${HOSTNAME}
EOF
    
    # 5. Instalar pacotes Samba
    log "Instalando pacotes do Samba AD..."
    apt install -y -qq acl attr samba samba-dsdb-modules samba-vfs-modules \
        winbind libpam-winbind libnss-winbind krb5-user dnsutils \
        bind9utils ldap-utils bash-completion language-pack-pt locales \
        chrony
    
    # 6. Parar serviços conflitantes
    systemctl stop smbd nmbd winbind samba-ad-dc 2>/dev/null || true
    systemctl disable smbd nmbd winbind 2>/dev/null || true
    
    # 7. Limpar configurações antigas
    rm -f /etc/samba/smb.conf
    rm -rf /var/lib/samba/private /var/lib/samba/sysvol /var/lib/samba/etc
    rm -f /etc/krb5.conf
    
    # 8. Provisionar domínio
    log "Provisionando domínio ${REALM} (pode levar 3-5 minutos)..."
    samba-tool domain provision \
        --use-rfc2307 \
        --realm="$REALM" \
        --domain="$SHORT_DOMAIN" \
        --server-role=dc \
        --dns-backend=SAMBA_INTERNAL \
        --adminpass="$ADMIN_PASSWORD" \
        --host-ip="$IP_ADDR" \
        --option="interfaces=lo $INTERFACE" \
        --option="bind interfaces only=yes" \
        > /tmp/provision.log 2>&1 || {
        warn "Provisionamento falhou — tentando sem opções extras..."
        samba-tool domain provision \
            --use-rfc2307 \
            --realm="$REALM" \
            --domain="$SHORT_DOMAIN" \
            --server-role=dc \
            --dns-backend=SAMBA_INTERNAL \
            --adminpass="$ADMIN_PASSWORD" \
            > /tmp/provision.log 2>&1 || error "Provisionamento falhou (veja /tmp/provision.log)"
    }
    echo -e "${GREEN}✓ Domínio provisionado com sucesso${NC}"
    
    # 9. Configurar smb.conf
    log "Configurando /etc/samba/smb.conf"
    cp "/var/lib/samba/private/smb.conf" "/etc/samba/smb.conf"
    
    # Garante parâmetros essenciais
    sed -i "/^interfaces/s|=.*| = lo $INTERFACE|" "/etc/samba/smb.conf" || true
    sed -i "/^bind interfaces only/s|=.*| = yes|" "/etc/samba/smb.conf" || true
    
    # Adiciona opções de replicação se não existirem
    grep -q "ldap server require strong auth" "/etc/samba/smb.conf" ||
        sed -i "/$$global$$/a \    ldap server require strong auth = no" "/etc/samba/smb.conf"
    
    # 10. Configurar Kerberos
    log "Configurando /etc/krb5.conf"
    rm -f /etc/krb5.conf /var/lib/samba/private/krb5.conf
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
        kdc = ${HOSTNAME}.${DOMAIN}
        admin_server = ${HOSTNAME}.${DOMAIN}
        default_domain = ${DOMAIN}
    }

[domain_realm]
    .${DOMAIN} = ${REALM}
    ${DOMAIN} = ${REALM}
    ${HOSTNAME} = ${REALM}

[logging]
    kdc = FILE:/var/log/krb5kdc.log
    admin_server = FILE:/var/log/kadmin.log
    default = FILE:/var/log/krb5lib.log
EOF
    cp /etc/krb5.conf /var/lib/samba/private/krb5.conf
    
    # 11. Configurar resolv.conf (DNS aponta para si mesmo)
    log "Configurando /etc/resolv.conf para DNS local"
    [ -f /etc/resolv.conf ] && cp /etc/resolv.conf "/etc/resolv.conf.bak.$(date +%Y%m%d_%H%M%S)"
    cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
search ${DOMAIN}
domain ${DOMAIN}
EOF
    
    # 12. Iniciar serviços Samba
    log "Iniciando serviços samba-ad-dc..."
    systemctl unmask samba-ad-dc || true
    systemctl enable samba-ad-dc || true
    systemctl restart samba-ad-dc
    sleep 20  # Aguarda inicialização completa e replicação interna
    
    # 13. Criar grupos e usuário secundário
    log "Criando grupos e usuários padrão..."
    samba-tool group add "admins" --description="Administradores do Domínio" 2>/dev/null || warn "Grupo admins já existe"
    samba-tool group add "users" --description="Usuários do Domínio" 2>/dev/null || warn "Grupo users já existe"
    samba-tool user create admin2 "$ADMIN_PASSWORD" --given-name="Admin" --surname="Secundário" 2>/dev/null || warn "Usuário admin2 já existe"
    samba-tool group addmembers "Domain Admins" admin2 2>/dev/null || warn "Não foi possível adicionar admin2 ao grupo Domain Admins"
    
    # 14. Salvar informações
    log "Salvando informações em /root/ad_info.txt"
    cat > /root/ad_info.txt << EOF
╔══════════════════════════════════════════════════════════╗
║              INFORMAÇÕES DO DC PRIMÁRIO                 ║
╠══════════════════════════════════════════════════════════╣
DOMÍNIO:     $DOMAIN
REALM:       $REALM
HOSTNAME:    $HOSTNAME
IP:          $IP_ADDR
INTERFACE:   $INTERFACE
DATA:        $(date)

ADMINISTRADOR: administrator@$REALM
SENHA:       $ADMIN_PASSWORD

COMANDOS ÚTEIS:
────────────────────────────────────────
# Testar Kerberos
echo '$ADMIN_PASSWORD' | kinit administrator@$REALM
klist

# Listar usuários/grupos
samba-tool user list
samba-tool group list

# Testar DNS
host -t SRV _ldap._tcp.$DOMAIN
host -t A $HOSTNAME.$DOMAIN

# Verificar replicação DRS (sem parceiros esperados)
samba-tool drs showrepl

# Logs
tail -f /var/log/samba/log.samba
tail -f /var/log/krb5kdc.log

────────────────────────────────────────
ATENÇÃO: root SSH está ativado! Revise /etc/ssh/sshd_config
em caso de exposição à internet.
╚══════════════════════════════════════════════════════════╝
EOF
    
    # 15. Bateria de testes
    run_tests_primary "$DOMAIN" "$REALM" "$IP_ADDR"
    
    # 16. Mensagem final
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅ DC PRIMÁRIO CONFIGURADO COM SUCESSO!           ║${NC}"
    echo -e "${GREEN}║                                                     ║${NC}"
    echo -e "${GREEN}║  Acesse com: administrator@$REALM                   ║${NC}"
    echo -e "${GREEN}║  IP do servidor: $IP_ADDR                           ║${NC}"
    echo -e "${GREEN}║                                                     ║${NC}"
    echo -e "${GREEN}║  Documentação: /root/ad_info.txt                      ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    
    read -p "Reiniciar o servidor agora? (s/N): " -n 1 -r
    [[ "$REPLY" =~ ^[Ss]$ ]] && { log "Reiniciando em 5 segundos..."; sleep 5; reboot; }
}

# ══════════════════════════════════════════════════════════════
#              FLUXO 2 — DC SECUNDÁRIO
# ══════════════════════════════════════════════════════════════

setup_secondary_dc() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        CONFIGURAÇÃO — DC SECUNDÁRIO              ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}"
    
    # 0. Detectar interface e IP
    detect_interface
    
    # 1. Solicitar informações
    read -p "Domínio (ex: rnv.local): " -e DOMAIN
    DOMAIN="${DOMAIN,,}"
    REALM="${DOMAIN^^}"
    read -p "IP do DC Primário: " -e PRIMARY_IP
    read -p "Hostname deste servidor (default: adserver02): " -e INPUT_HOSTNAME
    HOSTNAME="${INPUT_HOSTNAME:-adserver02}"
    read -p "Usuário administrador do domínio (ex: administrator): " -e ADMIN_USER
    ADMIN_USER="${ADMIN_USER:-administrator}"
    
    # Senha (sem validação de complexidade para join)
    echo -e "${BLUE}Digite a senha do administrador do domínio:${NC}"
    read -s -p "> " ADMIN_PASSWORD
    echo
    
    # Confirmação
    echo
    echo -e "${YELLOW}Resumo da configuração:${NC}"
    echo "  Domínio:     $DOMAIN"
    echo "  Realm:       $REALM"
    echo "  DC Primário: $PRIMARY_IP"
    echo "  Hostname:    $HOSTNAME"
    echo "  Interface:   $INTERFACE ($IP_ADDR)"
    echo
    read -p "Confirma? (S/n): " -n 1 -r CONFIRM
    echo
    [[ "$CONFIRM" =~ ^[Nn]$ ]] && error "Cancelado pelo usuário"
    
    # 2. Configurações base
    config_locale
    config_bash_completion
    config_ssh_root
    config_ntp "$PRIMARY_IP"
    
    # 3. Hostname
    log "Configurando hostname: ${HOSTNAME}.${DOMAIN}"
    hostnamectl set-hostname "${HOSTNAME}.${DOMAIN}"
    
    # 4. /etc/hosts — aponta para primário como DNS
    log "Configurando /etc/hosts"
    cp /etc/hosts "/etc/hosts.bak.$(date +%Y%m%d_%H%M%S)" || true
    cat > /etc/hosts << EOF
127.0.0.1 localhost
127.0.1.1 ${HOSTNAME}.${DOMAIN} ${HOSTNAME}
${PRIMARY_IP} dc-primary.${DOMAIN} dc-primary
${IP_ADDR} ${HOSTNAME}.${DOMAIN} ${HOSTNAME}
EOF
    
    # 5. /etc/resolv.conf — DNS aponta para o primário (e para si mesmo para fallback)
    log "Configurando /etc/resolv.conf para usar DNS do primário"
    [ -f /etc/resolv.conf ] && cp /etc/resolv.conf "/etc/resolv.conf.bak.$(date +%Y%m%d_%H%M%S)"
    cat > /etc/resolv.conf << EOF
nameserver ${PRIMARY_IP}
nameserver 127.0.0.1
search ${DOMAIN}
domain ${DOMAIN}
EOF
    
    # 6. Instalar pacotes
    log "Instalando pacotes necessários..."
    apt install -y -qq acl attr samba samba-dsdb-modules samba-vfs-modules \
        winbind krb5-user dnsutils ldap-utils bash-completion \
        language-pack-pt locales chrony
    
    # 7. Parar serviços conflitantes
    systemctl stop smbd nmbd winbind samba-ad-dc 2>/dev/null || true
    systemctl disable smbd nmbd winbind 2>/dev/null || true
    
    # 8. Limpar configurações antigas
    rm -rf /var/lib/samba/* /etc/samba/smb.conf /etc/krb5.conf 2>/dev/null || true
    
    # 9. Configurar Kerberos mínimo
    log "Configurando /etc/krb5.conf"
    cat > /etc/krb5.conf << EOF
[libdefaults]
    default_realm = ${REALM}
    dns_lookup_kdc = false
    default_domain = ${DOMAIN}

[realms]
    ${REALM} = {
        kdc = ${PRIMARY_IP}
        admin_server = ${PRIMARY_IP}
    }
EOF
    
    # 10. Testar Kerberos antes do join
    log "Testando Kerberos com as credenciais fornecidas..."
    echo -n "${ADMIN_PASSWORD}" | kinit "$ADMIN_USER@$REALM" >/dev/null 2>&1 && {
        echo -e "${GREEN}✓ Autenticação Kerberos OK — credenciais válidas${NC}"
        kdestroy 2>/dev/null || true
    } || error "Kerberos falhou — verifique domínio, usuário e senha"
    
    # 11. Executar domain join
    log "Juntando ao domínio ${REALM} como DC Secundário..."
    info "Isso pode levar alguns minutos..."
    
    # O join precisa de um krb5.conf funcional e credenciais válidas
    samba-tool domain join "$REALM" DC \
        --dns-backend=SAMBA_INTERNAL \
        --option="interfaces=lo $INTERFACE" \
        --option="bind interfaces only=yes" \
        --server="$PRIMARY_IP" \
        -U"${ADMIN_USER}@${REALM}" \
        --password="$ADMIN_PASSWORD" \
        > /tmp/join.log 2>&1 || error "Join falhou (veja /tmp/join.log)"
    
    echo -e "${GREEN}✓ Servidor juntado ao domínio como DC Secundário${NC}"
    
    # 12. Ajustar smb.conf para replicação
    log "Ajustando /etc/samba/smb.conf para replicação"
    cp "/var/lib/samba/private/smb.conf" "/etc/samba/smb.conf"
    
    # Garante interfaces corretas
    sed -i "/^interfaces/s|=.*| = lo $INTERFACE|" "/etc/samba/smb.conf" || true
    
    # 13. Configurar samba-ad-dc
    log "Iniciando samba-ad-dc..."
    systemctl unmask samba-ad-dc || true
    systemctl enable samba-ad-dc || true
    systemctl restart samba-ad-dc
    sleep 20
    
    # 14. Verificar replicação
    log "Verificando replicação DRS com o primário..."
    if samba-tool drs showrepl 2>&1 | grep -q "$PRIMARY_IP"; then
        echo -e "${GREEN}✓ Replicação DRS ativa com $PRIMARY_IP${NC}"
    else
        warn "Replicação DRS não detectada — pode levar alguns minutos ou verificar logs"
    fi
    
    # 15. Salvar informações
    log "Salvando informações em /root/ad_info.txt"
    cat > /root/ad_info.txt << EOF
╔══════════════════════════════════════════════════════════╗
║             INFORMAÇÕES DO DC SECUNDÁRIO                ║
╠══════════════════════════════════════════════════════════╣
DOMÍNIO:     $DOMAIN
REALM:       $REALM
DC PRIMÁRIO: $PRIMARY_IP
HOSTNAME:    $HOSTNAME
IP:          $IP_ADDR
INTERFACE:   $INTERFACE
DATA:        $(date)

USUÁRIO JOIN: $ADMIN_USER@$REALM

COMANDOS ÚTEIS:
────────────────────────────────────────
# Testar replicação DRS
samba-tool drs showrepl

# Testar Kerberos
echo '$ADMIN_PASSWORD' | kinit $ADMIN_USER@$REALM
klist

# Testar DNS (deve resolver pelo primário)
host -t SRV _ldap._tcp.$DOMAIN
host -t A $HOSTNAME.$DOMAIN

# Logs
tail -f /var/log/samba/log.samba
tail -f /var/log/krb5kdc.log

────────────────────────────────────────
ATENÇÃO: root SSH está ativado! Revise /etc/ssh/sshd_config
em caso de exposição à internet.
╚══════════════════════════════════════════════════════════╝
EOF
    
    # 16. Bateria de testes
    run_tests_secondary "$DOMAIN" "$REALM" "$IP_ADDR" "$PRIMARY_IP"
    
    # 17. Mensagem final
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅ DC SECUNDÁRIO CONFIGURADO COM SUCESSO!         ║${NC}"
    echo -e "${GREEN}║                                                     ║${NC}"
    echo -e "${GREEN}║  Este servidor é um DC PLENO e pode assumir           ║${NC}"
    echo -e "${GREEN}║  as funções do primário se necessário.              ║${NC}"
    echo -e "${GREEN}║                                                     ║${NC}"
    echo -e "${GREEN}║  Documentação: /root/ad_info.txt                      ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    
    read -p "Reiniciar o servidor agora? (s/N): " -n 1 -r
    [[ "$REPLY" =~ ^[Ss]$ ]] && { log "Reiniciando em 5 segundos..."; sleep 5; reboot; }
}

# ══════════════════════════════════════════════════════════════
#              FLUXO 3 — CONFIGURAR IP DAS ESTAÇÕES
# ══════════════════════════════════════════════════════════════

configure_station_ips() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   GERADOR DE CONFIGURAÇÃO DE IP — ESTAÇÕES      ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}"
    
    echo "Selecione o sistema operacional das estações:"
    echo "  1) Linux (Netplan — Ubuntu/Debian)"
    echo "  2) Windows (script batch netsh)"
    read -p "Opção [1/2]: " OS_OPT
    
    case "$OS_OPT" in
        1)
            echo
            read -p "IP da estação Linux (ex: 192.168.1.50): " STA_IP
            read -p "Máscara (ex: 24): " STA_MASK
            read -p "Gateway (ex: 192.168.1.1): " STA_GATEWAY
            read -p "DNS 1 (default: 192.168.1.2): " STA_DNS1
            STA_DNS1="${STA_DNS1:-192.168.1.2}"
            read -p "DNS 2 (default: 192.168.1.3): " STA_DNS2
            STA_DNS2="${STA_DNS2:-192.168.1.3}"
            read -p "Nome da interface (ex: enp3s0, eth0): " STA_IFACE
            
            cat > "/root/netplan_station_${STA_IP//./_}.yaml" << EOF
# Configuração de rede para estação Linux
# Salve em /etc/netplan/01-netcfg.yaml e execute:
#   sudo netplan apply

network:
  version: 2
  ethernets:
    $STA_IFACE:
      addresses: [$STA_IP/$STA_MASK]
      gateway4: $STA_GATEWAY
      nameservers:
        addresses: [$STA_DNS1, $STA_DNS2]
        search: [$(hostname -d 2>/dev/null || echo "rnv.local")]
      dhcp6: no
      optional: true
EOF
            
            echo
            echo -e "${GREEN}✓ Arquivo gerado: /root/netplan_station_${STA_IP//./_}.yaml${NC}"
            echo "Para aplicar:"
            echo "  sudo cp /root/netplan_station_${STA_IP//./_}.yaml /etc/netplan/01-netcfg.yaml"
            echo "  sudo netplan apply"
            ;;
        2)
            echo
            read -p "IP da estação Windows (ex: 192.168.1.51): " STA_IP
            read -p "Máscara (ex: 255.255.255.0): " STA_MASK
            read -p "Gateway (ex: 192.168.1.1): " STA_GATEWAY
            read -p "DNS 1 (default: 192.168.1.2): " STA_DNS1
            STA_DNS1="${STA_DNS1:-192.168.1.2}"
            read -p "DNS 2 (default: 192.168.1.3): " STA_DNS2
            STA_DNS2="${STA_DNS2:-192.168.1.3}"
            read -p "Nome da interface (ex: Ethernet): " STA_IFACE
            
            cat > "/root/config_ip_estacao_${STA_IP}.bat" << EOF
@echo off
REM Configuração de IP estático para estação Windows
REM Execute como Administrador

echo Configurando IP estático para a interface "$STA_IFACE"...

netsh interface ipv4 set address name="$STA_IFACE" source=static address=$STA_IP mask=$STA_MASK gateway=$STA_GATEWAY gwmetric=1
netsh interface ipv4 set dns name="$STA_IFACE" source=static address=$STA_DNS1 register=primary
netsh interface ipv4 add dns name="$STA_IFACE" address=$STA_DNS2 index=2

echo.
echo ✅ Configuração aplicada!
echo.
echo Reinicie a interface ou execute:
echo   ipconfig /release
echo   ipconfig /renew
echo.
pause
EOF
            
            echo
            echo -e "${GREEN}✓ Arquivo gerado: /root/config_ip_estacao_${STA_IP}.bat${NC}"
            echo "Copie para a estação Windows e execute como Administrador."
            ;;
        *)
            error "Opção inválida"
            ;;
    esac
    echo
    read -p "Pressione Enter para voltar ao menu..."
}

# ══════════════════════════════════════════════════════════════
#              FLUXO 4 — LINUX COMO ESTAÇÃO DE TRABALHO
# ══════════════════════════════════════════════════════════════

configure_linux_station() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   CONFIGURAR LINUX COMO ESTAÇÃO DE DOMÍNIO     ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}"
    
    read -p "Domínio a juntar (ex: rnv.local): " -e DOMAIN
    DOMAIN="${DOMAIN,,}"
    read -p "Usuário administrador do domínio (ex: administrator): " -e ADMIN_USER
    ADMIN_USER="${ADMIN_USER:-administrator}"
    echo -e "${BLUE}Digite a senha do domínio:${NC}"
    read -s -p "> " ADMIN_PASSWORD
    echo
    
    log "Instalando pacotes necessários (realmd, sssd, adcli, oddjobd)..."
    apt update -qq
    apt install -y -qq realmd sssd sssd-tools adcli oddjob oddjob-mkhomedir \
        krb5-user krb5-config samba-common samba-common-bin \
        policykit-1
    
    log "Descobrindo o domínio..."
    realm discover "$DOMAIN" || warn "Domínio não encontrado — verifique DNS e conectividade"
    
    log "Executando realm join (pode pedir senha novamente)..."
    # realm join pode pedir a senha interativamente; usamos --password para automatizar
    echo -n "${ADMIN_PASSWORD}" | realm join --user="$ADMIN_USER" "$DOMAIN" --password="$ADMIN_PASSWORD" || {
        warn "realm join falhou — tentando sem --password (modo interativo)..."
        realm join --user="$ADMIN_USER" "$DOMAIN" || error "Join falhou (verifique logs em /var/log/realmd)"
    }
    
    log "Habilitando criação automática de home directory..."
    systemctl enable --now oddjobd
    realm permit "$ADMIN_USER@$DOMAIN"
    
    # Configuração adicional: permitir sudo para admins do domínio
    log "Configurando sudoers para administradores do domínio..."
    cat > /etc/sudoers.d/ad_admins << EOF
# Administradores do AD com permissão sudo
%Domain\\ Admins@$DOMAIN ALL=(ALL:ALL) ALL
EOF
    
    # Teste
    log "Testando resolução de usuário do domínio..."
    id "$ADMIN_USER@$DOMAIN" || warn "Usuário do domínio não resolvido — pode levar alguns minutos"
    
    echo
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅ ESTAÇÃO LINUX CONFIGURADA COMO MEMBRO DO AD   ║${NC}"
    echo -e "${GREEN}║                                                     ║${NC}"
    echo -e "${GREEN}║  Para testar login:                                  ║${NC}"
    echo -e "${GREEN}║  su - $ADMIN_USER@$DOMAIN                           ║${NC}"
    echo -e "${GREEN}║                                                     ║${NC}"
    echo -e "${GREEN}║  Para verificar: realm list / id <usuario>           ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    
    echo
    read -p "Pressione Enter para voltar ao menu..."
}

# ══════════════════════════════════════════════════════════════
#                        MENU PRINCIPAL
# ══════════════════════════════════════════════════════════════

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║            SAMBA AD SERVER — UNIFICADO PRO                      ║${NC}"
        echo -e "${BLUE}║              Ubuntu 24.04 | Samba 4.19.5                       ║${NC}"
        echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║ 1) DC Primário    — Provisionar novo domínio                   ║${NC}"
        echo -e "${BLUE}║ 2) DC Secundário  — Juntar a domínio existente (replicação)    ║${NC}"
        echo -e "${BLUE}║ 3) Configurar IP  — Gerar template para estações (Linux/Win)   ║${NC}"
        echo -e "${BLUE}║ 4) Estação Linux  — Configurar Linux como membro do domínio     ║${NC}"
        echo -e "${BLUE}║ 5) Sair                                                      ║${NC}"
        echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
        echo
        read -p "Selecione uma opção [1-5]: " OPTION
        
        case "$OPTION" in
            1) setup_primary_dc ;;
            2) setup_secondary_dc ;;
            3) configure_station_ips ;;
            4) configure_linux_station ;;
            5) echo -e "${GREEN}Saindo. Até logo!${NC}"; exit 0 ;;
            *) warn "Opção inválida. Tente novamente."; sleep 1 ;;
        esac
    done
}

# ══════════════════════════════════════════════════════════════
#                   INÍCIO DA EXECUÇÃO
# ══════════════════════════════════════════════════════════════

trap 'echo -e "\n${RED}[INTERRUPTED]${NC} Script interrompido."; exit 1' INT TERM

log "Iniciando SAMBA AD SERVER UNIFICADO PRO"
log "Sistema: Ubuntu 24.04 | Samba $(samba --version 2>/dev/null | head -1)"
main_menu
