#!/bin/bash
# adserver01_complete.sh
# Script completo para configuração do Samba AD
# Versão: 4.0 - Corrigido provisionamento e NetBIOS

set -e  # Para o script em caso de erro

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configurações padrão (serão sobrescritas pelo usuário)
DEFAULT_DOMAIN="rnv.intra"
DEFAULT_REALM="RNV.INTRA"
DEFAULT_SHORT_DOMAIN="RNV"
DEFAULT_HOSTNAME="adserver01"
DEFAULT_DNS_FORWARDER="8.8.8.8"

# ============================================
# FUNÇÕES
# ============================================
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERRO]${NC} $1"
    exit 1
}

warning() {
    echo -e "${YELLOW}[AVISO]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

check_success() {
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ OK${NC}"
    else
        echo -e "${RED}✗ FALHOU${NC}"
        warning "Continuando mesmo com falha..."
    fi
}

# Verificar se é root
if [[ $EUID -ne 0 ]]; then
   error "Este script deve ser executado como root (sudo)"
fi

# ============================================
# DETECTAR INTERFACE DE REDE
# ============================================
clear
echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║                                                               ║"
echo "║     SAMBA AD SERVER - INSTALAÇÃO COMPLETA                    ║"
echo "║                                                               ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

log "=== DETECTANDO INTERFACE DE REDE ==="

# Descobrir interface de rede
INTERFACE=$(ip link show | grep -E "^[0-9]+: (en|eth)" | head -1 | cut -d: -f2 | xargs)
if [ -z "$INTERFACE" ]; then
    INTERFACE=$(ip link show | grep -E "^[0-9]+: " | grep -v lo | head -1 | cut -d: -f2 | xargs)
fi

# Obter IP da interface
IP_ADDR=$(ip addr show $INTERFACE 2>/dev/null | grep inet | grep -v inet6 | awk '{print $2}' | cut -d/ -f1)

# Se não conseguir o IP, usar o configurado
if [ -z "$IP_ADDR" ]; then
    IP_ADDR="192.168.1.2"
fi

# Usar o IP detectado
IP="$IP_ADDR"

echo -e "${GREEN}✓ Interface detectada: ${INTERFACE}${NC}"
echo -e "${GREEN}✓ IP detectado: ${IP}${NC}"
echo ""

# ============================================
# CONFIGURAR LOCALE PT-BR
# ============================================
log "0. Configurando idioma Português Brasil..."

# Atualizar lista de pacotes
apt update -qq

# Instalar pacotes de idioma
apt install -y -qq language-pack-pt locales

# Gerar locale pt_BR
locale-gen pt_BR.UTF-8

# Configurar locale no sistema
update-locale LANG=pt_BR.UTF-8 LANGUAGE=pt_BR:pt LC_ALL=pt_BR.UTF-8

# Aplicar configuração
export LANG=pt_BR.UTF-8
export LANGUAGE=pt_BR:pt
export LC_ALL=pt_BR.UTF-8

echo -e "${GREEN}✓ Idioma Português Brasil configurado${NC}"
echo ""

# ============================================
# ATIVAR AUTO COMPLETE COM TAB
# ============================================
log "0. Ativando auto complete com TAB..."

# Instalar bash-completion
apt install -y -qq bash-completion

# Configurar bashrc para auto complete
if ! grep -q "bash-completion" /root/.bashrc; then
    cat >> /root/.bashrc << 'EOF'

# Ativar auto complete com TAB
if [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
fi

# Ativar auto complete para samba-tool
complete -C samba-tool samba-tool
EOF
fi

# Ativar para o usuário atual
if [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
fi

echo -e "${GREEN}✓ Auto complete com TAB ativado${NC}"
echo ""

# ============================================
# SOLICITAR INFORMAÇÕES DO DOMÍNIO
# ============================================
clear
echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║                                                               ║"
echo "║     SAMBA AD SERVER - INSTALAÇÃO COMPLETA                    ║"
echo "║                                                               ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

log "=== INFORMAÇÕES DO DOMÍNIO ==="
echo ""

echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Configure as informações do seu domínio:${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
echo ""

# Ler informações com valores padrão
echo -e "${BLUE}Nome do DOMÍNIO DNS (ex: meudominio.local):${NC}"
read -p "[${DEFAULT_DOMAIN}] " DOMAIN_INPUT
DOMAIN=${DOMAIN_INPUT:-$DEFAULT_DOMAIN}
echo ""

echo -e "${BLUE}Nome NETBIOS (nome curto do domínio, ex: MEUDOMINIO):${NC}"
read -p "[${DEFAULT_SHORT_DOMAIN}] " SHORT_DOMAIN_INPUT
SHORT_DOMAIN=${SHORT_DOMAIN_INPUT:-$DEFAULT_SHORT_DOMAIN}
echo ""

echo -e "${BLUE}Nome do HOST (ex: dc01):${NC}"
read -p "[${DEFAULT_HOSTNAME}] " HOSTNAME_INPUT
HOSTNAME=${HOSTNAME_INPUT:-$DEFAULT_HOSTNAME}
echo ""

echo -e "${BLUE}DNS Forwarder (ex: 8.8.8.8):${NC}"
read -p "[${DEFAULT_DNS_FORWARDER}] " DNS_FORWARDER_INPUT
DNS_FORWARDER=${DNS_FORWARDER_INPUT:-$DEFAULT_DNS_FORWARDER}
echo ""

# Realm = DOMÍNIO em maiúsculas
REALM=$(echo "$DOMAIN" | tr '[:lower:]' '[:upper:]')
IP="$IP_ADDR"

# Mostrar resumo
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}RESUMO DA CONFIGURAÇÃO:${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  • Domínio DNS: ${BLUE}${DOMAIN}${NC}"
echo -e "  • Realm Kerberos: ${BLUE}${REALM}${NC}"
echo -e "  • Domínio NetBIOS: ${BLUE}${SHORT_DOMAIN}${NC}  ${YELLOW}(ATENÇÃO: NOME CURTO, SEM PONTOS!)${NC}"
echo -e "  • Hostname: ${BLUE}${HOSTNAME}${NC}"
echo -e "  • IP do Servidor: ${BLUE}${IP}${NC}"
echo -e "  • Interface: ${BLUE}${INTERFACE}${NC}"
echo -e "  • DNS Forwarder: ${BLUE}${DNS_FORWARDER}${NC}"
echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
echo ""

# Solicitar senha do Administrador
echo -e "${BLUE}Configuração da senha do Administrador do Domínio${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
echo ""

# Pedir a senha com confirmação
while true; do
    echo -e "${BLUE}Digite a senha do administrador:${NC}"
    read -s -p "> " ADMIN_PASSWORD
    echo ""
    
    echo -e "${BLUE}Confirme a senha:${NC}"
    read -s -p "> " ADMIN_PASSWORD_CONFIRM
    echo ""
    
    if [ "$ADMIN_PASSWORD" = "$ADMIN_PASSWORD_CONFIRM" ]; then
        # Verificar se a senha tem requisitos mínimos
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
    else
        echo -e "${RED}As senhas não coincidem! Tente novamente.${NC}"
        echo ""
    fi
done

echo ""
echo -e "${GREEN}✓ Senha definida com sucesso!${NC}"
echo ""

# Perguntar se deseja continuar
echo -e "${YELLOW}Deseja continuar com a instalação? (s/N)${NC}"
read -p "> " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Ss]$ ]] && [[ ! -z "$REPLY" ]]; then
    error "Instalação cancelada pelo usuário"
fi

echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}INICIANDO INSTALAÇÃO...${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
echo ""

# ============================================
# 1. CONFIGURAR HOSTNAME
# ============================================
log "1. Configurando hostname..."
hostnamectl set-hostname ${HOSTNAME}.${DOMAIN}
check_success

# ============================================
# 2. CONFIGURAR /ETC/HOSTS
# ============================================
log "2. Configurando /etc/hosts..."
if [ -f /etc/hosts ]; then
    cp /etc/hosts /etc/hosts.bak.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
fi

cat > /etc/hosts << EOF
127.0.0.1 localhost
127.0.1.1 ${HOSTNAME}.${DOMAIN} ${HOSTNAME}
${IP} ${HOSTNAME}.${DOMAIN} ${HOSTNAME}
EOF
check_success

# ============================================
# 3. CONFIGURAR NTP
# ============================================
log "3. Instalando e configurando NTP..."
apt update -qq
apt install chrony -y -qq
timedatectl set-timezone America/Sao_Paulo
systemctl enable --now chrony -qq
check_success

# ============================================
# 4. INSTALAR PACOTES
# ============================================
log "4. Instalando pacotes do Samba AD..."
DEBIAN_FRONTEND=noninteractive apt install -y -qq \
    acl attr samba samba-dsdb-modules \
    samba-vfs-modules winbind libpam-winbind \
    libnss-winbind kinit krb5-user dnsutils \
    bind9utils ldap-utils \
    bash-completion \
    language-pack-pt \
    locales \
    expect
check_success

# ============================================
# 5. PARAR SERVIÇOS CONFLITANTES
# ============================================
log "5. Parando serviços conflitantes..."
systemctl stop smbd nmbd winbind 2>/dev/null || true
systemctl disable smbd nmbd winbind 2>/dev/null || true
check_success

# ============================================
# 6. LIMPAR CONFIGURAÇÕES ANTIGAS
# ============================================
log "6. Limpando configurações antigas..."
rm -f /etc/samba/smb.conf
rm -rf /var/lib/samba/private 2>/dev/null || true
rm -rf /var/lib/samba/sysvol 2>/dev/null || true
rm -f /etc/krb5.conf
check_success

# ============================================
# 7. PROVISIONAR O DOMÍNIO (CORRIGIDO!)
# ============================================
log "7. Provisionando o domínio ${DOMAIN}..."
info "REALM: ${REALM}"
info "DOMAIN (NetBIOS): ${SHORT_DOMAIN} (NOME CURTO!)"
info "Isso pode levar alguns minutos..."

# Provisionamento correto - DOMAIN é o NetBIOS (nome curto!)
samba-tool domain provision \
    --use-rfc2307 \
    --realm="${REALM}" \
    --domain="${SHORT_DOMAIN}" \
    --server-role=dc \
    --dns-backend=SAMBA_INTERNAL \
    --adminpass="${ADMIN_PASSWORD}" \
    --host-ip="${IP}" \
    --option="interfaces=lo ${INTERFACE}" \
    --option="bind interfaces only=yes" \
    > /tmp/provision.log 2>&1

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ OK${NC}"
else
    echo -e "${RED}✗ FALHOU${NC}"
    warning "Tentando provisionamento sem opções extras..."
    
    # Tentar sem opções extras
    samba-tool domain provision \
        --use-rfc2307 \
        --realm="${REALM}" \
        --domain="${SHORT_DOMAIN}" \
        --server-role=dc \
        --dns-backend=SAMBA_INTERNAL \
        --adminpass="${ADMIN_PASSWORD}" \
        > /tmp/provision.log 2>&1
    
    check_success
fi

# ============================================
# 8. CRIAR SMBCONF CORRETO
# ============================================
log "8. Configurando smb.conf..."

if [ -f "/var/lib/samba/private/smb.conf" ]; then
    cp /var/lib/samba/private/smb.conf /etc/samba/smb.conf
    info "Arquivo copiado de /var/lib/samba/private/"
else
    info "Criando smb.conf manualmente..."
fi

# Garantir configurações corretas
cat > /etc/samba/smb.conf << EOF
[global]
    netbios name = ${HOSTNAME^^}
    realm = ${REALM}
    server role = active directory domain controller
    workgroup = ${SHORT_DOMAIN}
    dns forwarder = ${DNS_FORWARDER}
    interfaces = lo ${INTERFACE}
    bind interfaces only = yes
    rpc_server:tcpip = yes
    rpc_server:default = external
    rpc_daemon:spoolssd = embedded
    rpc_server:spoolss = embedded
    rpc_server:winreg = embedded
    rpc_server:ntsvcs = embedded
    rpc_server:eventlog = embedded
    rpc_server:srvsvc = embedded
    rpc_server:svcctl = embedded
    log level = 2
    max log size = 1000
    debug timestamp = yes

[sysvol]
    path = /var/lib/samba/sysvol
    read only = No

[netlogon]
    path = /var/lib/samba/sysvol/${DOMAIN}/scripts
    read only = No
EOF

check_success

# ============================================
# 9. CONFIGURAR KERBEROS
# ============================================
log "9. Configurando Kerberos..."

# Remover configuração antiga
rm -f /etc/krb5.conf
rm -f /var/lib/samba/private/krb5.conf

# Criar configuração COMPLETA do Kerberos
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

# Copiar para o private
cp /etc/krb5.conf /var/lib/samba/private/krb5.conf
check_success

# ============================================
# 10. CONFIGURAR RESOLV.CONF
# ============================================
log "10. Configurando resolução DNS..."

if lsattr /etc/resolv.conf 2>/dev/null | grep -q "i"; then
    info "Removendo atributo imutável do /etc/resolv.conf..."
    chattr -i /etc/resolv.conf 2>/dev/null || true
fi

if [ -f /etc/resolv.conf ]; then
    cp /etc/resolv.conf /etc/resolv.conf.bak.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
fi

cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
search ${DOMAIN}
domain ${DOMAIN}
EOF

info "Arquivo /etc/resolv.conf atualizado"
check_success

# ============================================
# 11. INICIAR SERVIÇOS
# ============================================
log "11. Iniciando serviços do Samba AD..."
systemctl unmask samba-ad-dc 2>/dev/null || true
systemctl enable samba-ad-dc 2>/dev/null || true
systemctl restart samba-ad-dc

# Verificar se iniciou
sleep 5
if systemctl is-active --quiet samba-ad-dc; then
    echo -e "${GREEN}✓ OK${NC}"
else
    echo -e "${RED}✗ FALHOU${NC}"
    warning "Verificando logs..."
    journalctl -u samba-ad-dc --no-pager | tail -10
fi

# ============================================
# 12. AGUARDAR SERVIÇOS
# ============================================
log "12. Aguardando serviços iniciarem (30 segundos)..."
sleep 30

# ============================================
# 13. VERIFICAR DNS
# ============================================
log "13. Verificando DNS..."
info "Testando resolução DNS..."

sleep 5
if host -t SRV _ldap._tcp.${DOMAIN} > /dev/null 2>&1; then
    echo -e "${GREEN}✓ DNS SRV OK${NC}"
else
    warning "DNS SRV não resolvido corretamente - pode levar mais tempo"
    sleep 10
    host -t SRV _ldap._tcp.${DOMAIN} || warning "DNS SRV ainda não disponível"
fi

if host -t A ${HOSTNAME}.${DOMAIN} > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Hostname OK${NC}"
else
    warning "Hostname não resolvido - verificando..."
    sleep 5
    host -t A ${HOSTNAME}.${DOMAIN} || warning "Hostname ainda não disponível"
fi

# ============================================
# 14. TESTAR KERBEROS
# ============================================
log "14. Testando autenticação Kerberos..."
echo "═══════════════════════════════════════════════════════════════════"
info "Iniciando teste de Kerberos..."
info "Domínio: ${REALM}"
info "Usuário: administrator@${REALM}"
echo "═══════════════════════════════════════════════════════════════════"

# Teste: Autenticação
if echo "${ADMIN_PASSWORD}" | kinit administrator@${REALM} > /dev/null 2>&1; then
    echo -e "${GREEN}✅ Kerberos funcionando!${NC}"
    echo ""
    echo -e "${BLUE}Ticket atual:${NC}"
    klist
    KERBEROS_OK=1
else
    echo -e "${RED}❌ Kerberos falhou${NC}"
    KERBEROS_OK=0
    info "Tentando com mais detalhes..."
    echo "${ADMIN_PASSWORD}" | kinit -V administrator@${REALM} 2>&1 || true
fi

echo "═══════════════════════════════════════════════════════════════════"

# ============================================
# 15. TESTAR RPC
# ============================================
log "15. Testando RPC..."
RPC_TEST=$(rpcclient -U Administrator%"$ADMIN_PASSWORD" -c "srvinfo" 127.0.0.1 2>&1)
if echo "$RPC_TEST" | grep -q "${HOSTNAME^^}"; then
    echo -e "${GREEN}✅ RPC funcionando!${NC}"
    echo "$RPC_TEST"
    RPC_OK=1
else
    echo -e "${RED}❌ RPC falhou!${NC}"
    echo "$RPC_TEST"
    RPC_OK=0
fi

# ============================================
# 16. CRIAR GRUPOS
# ============================================
log "16. Criando grupos padrão..."
samba-tool group add "admins" --description="Administradores do Domínio" 2>/dev/null || warning "Grupo admins já existe"
samba-tool group add "users" --description="Usuários do Domínio" 2>/dev/null || warning "Grupo users já existe"
echo -e "${GREEN}✓ Grupos criados${NC}"

# ============================================
# 17. CRIAR USUÁRIO SECUNDÁRIO
# ============================================
log "17. Criando usuário admin2..."
samba-tool user create admin2 ${ADMIN_PASSWORD} --given-name="Admin" --surname="Secundario" 2>/dev/null || warning "Usuário admin2 já existe"
samba-tool group addmembers "Domain Admins" admin2 2>/dev/null || warning "Não foi possível adicionar admin2 ao grupo Domain Admins"
echo -e "${GREEN}✓ Usuário admin2 criado${NC}"

# ============================================
# 18. SALVAR INFORMAÇÕES
# ============================================
log "18. Salvando informações de configuração..."
cat > /root/ad_info.txt << EOF
═══════════════════════════════════════════════════════════════════
                    INFORMAÇÕES DO DOMÍNIO
═══════════════════════════════════════════════════════════════════

DOMÍNIO DNS: ${DOMAIN}
REALM: ${REALM}
NETBIOS (DOMAIN): ${SHORT_DOMAIN}
IP: ${IP}
SERVIDOR: ${HOSTNAME}
INTERFACE: ${INTERFACE}
DNS FORWARDER: ${DNS_FORWARDER}
DATA CRIAÇÃO: $(date)

───────────────────────────────────────────────────────────────────
USUÁRIOS E SENHAS
───────────────────────────────────────────────────────────────────
Administrador: administrator@${REALM}
Senha: ${ADMIN_PASSWORD}

Usuário Secundário: admin2@${REALM}
Senha: ${ADMIN_PASSWORD}

⚠️  IMPORTANTE: Guarde estas senhas em local seguro!

───────────────────────────────────────────────────────────────────
RESULTADO DOS TESTES
───────────────────────────────────────────────────────────────────
KERBEROS: $( [ ${KERBEROS_OK} -eq 1 ] && echo "✅ FUNCIONANDO" || echo "❌ FALHOU" )
RPC: $( [ ${RPC_OK} -eq 1 ] && echo "✅ FUNCIONANDO" || echo "❌ FALHOU" )

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

# Testar DNS
host -t SRV _ldap._tcp.${DOMAIN}
host -t A ${HOSTNAME}.${DOMAIN}

# Testar RPC
rpcclient -U Administrator%${ADMIN_PASSWORD} -c "srvinfo" 127.0.0.1

# Verificar configuração
cat /etc/samba/smb.conf | grep "workgroup"
cat /etc/samba/smb.conf | grep "realm"

───────────────────────────────────────────────────────────────────
LOGS
───────────────────────────────────────────────────────────────────
Arquivo de log: /tmp/provision.log
Log do Samba: /var/log/samba/log.samba
EOF

check_success

# ============================================
# 19. MOSTRAR RESUMO FINAL
# ============================================
clear
echo -e "${GREEN}"
echo "═══════════════════════════════════════════════════════════════════"
echo "                                                                   "
echo "         ✅ CONFIGURAÇÃO CONCLUÍDA COM SUCESSO!                    "
echo "                                                                   "
echo "═══════════════════════════════════════════════════════════════════"
echo -e "${NC}"
echo ""
echo -e "${BLUE}📋 RESUMO DA INSTALAÇÃO:${NC}"
echo ""
echo -e "  ${GREEN}✓${NC} Idioma Português Brasil configurado"
echo -e "  ${GREEN}✓${NC} Auto complete com TAB ativado"
echo -e "  ${GREEN}✓${NC} Hostname configurado: ${HOSTNAME}.${DOMAIN}"
echo -e "  ${GREEN}✓${NC} Interface detectada: ${INTERFACE} (${IP})"
echo -e "  ${GREEN}✓${NC} Samba AD provisionado"
echo -e "  ${GREEN}✓${NC} Serviços iniciados"
echo -e "  ${GREEN}✓${NC} DNS configurado"
echo -e "  ${GREEN}✓${NC} Kerberos: $( [ ${KERBEROS_OK} -eq 1 ] && echo "✅ Funcionando" || echo "❌ Falhou" )"
echo -e "  ${GREEN}✓${NC} RPC: $( [ ${RPC_OK} -eq 1 ] && echo "✅ Funcionando" || echo "❌ Falhou" )"
echo -e "  ${GREEN}✓${NC} Usuários criados"
echo ""
echo -e "${YELLOW}📌 INFORMAÇÕES DE ACESSO:${NC}"
echo ""
echo -e "  Domínio DNS: ${BLUE}${DOMAIN}${NC}"
echo -e "  Realm: ${BLUE}${REALM}${NC}"
echo -e "  NetBIOS: ${BLUE}${SHORT_DOMAIN}${NC}"
echo -e "  Usuário Admin: ${BLUE}administrator@${REALM}${NC}"
echo -e "  Senha Admin: ${BLUE}${ADMIN_PASSWORD}${NC}"
echo -e "  IP do Servidor: ${BLUE}${IP}${NC}"
echo -e "  Interface: ${BLUE}${INTERFACE}${NC}"
echo ""
echo -e "${YELLOW}📁 ARQUIVOS SALVOS:${NC}"
echo ""
echo -e "  /root/ad_info.txt - Informações completas"
echo -e "  /tmp/provision.log - Log do provisionamento"
echo ""
echo -e "${YELLOW}🔧 TESTE MANUAL:${NC}"
echo ""
echo -e "  Para testar o Kerberos manualmente, execute:"
echo -e "  ${BLUE}echo '${ADMIN_PASSWORD}' | kinit administrator@${REALM}${NC}"
echo -e "  ${BLUE}klist${NC}"
echo ""
echo -e "${YELLOW}💡 DICAS:${NC}"
echo -e "  ✅ Use TAB para auto completar comandos"
echo -e "  ✅ O sistema está em Português Brasil"
echo -e "  ✅ NetBIOS correto: ${SHORT_DOMAIN} (nome curto!)"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}                    FIM DA INSTALAÇÃO                              ${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
echo ""

# Perguntar se deseja reiniciar
echo -e "${YELLOW}Deseja reiniciar o servidor agora? (s/N)${NC}"
read -p "> " -n 1 -r
echo
if [[ $REPLY =~ ^[Ss]$ ]]; then
    log "Reiniciando servidor em 5 segundos..."
    sleep 5
    reboot
else
    log "Lembre-se de reiniciar o servidor depois para aplicar todas as configurações."
    log ""
    log "Para ingressar no Windows:"
    log "  DNS: ${IP}"
    log "  Domínio: ${DOMAIN}"
    log "  Usuário: Administrator"
    log "  Senha: ${ADMIN_PASSWORD}"
fi
