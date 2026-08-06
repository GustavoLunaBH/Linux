#!/bin/bash
# 02_setup_ad_secondary.sh
# Script COMPLETO para configurar o AD Secundário do ZERO
# Versão: FINAL - Use APENAS no servidor adserver02

set -e

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================
# CONFIGURAÇÕES
# ============================================
DOMAIN="RNV.INTRA"
REALM="RNV.INTRA"
SHORT_DOMAIN="RNV"
HOSTNAME="adserver02"
IP="192.168.1.3"
PRIMARY_IP="192.168.1.2"
DNS_FORWARDER="8.8.8.8"

# ============================================
# FUNÇÕES
# ============================================
log() { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERRO]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCESSO]${NC} $1"; }

# ============================================
# INÍCIO
# ============================================
clear
echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════════════════════════════════════╗"
echo "║                                                                           ║"
echo "║     🚀 INSTALAÇÃO COMPLETA - AD SECUNDÁRIO                               ║"
echo "║                                                                           ║"
echo "║     Domínio: ${DOMAIN}                                                    ║"
echo "║     Servidor: ${HOSTNAME} (${IP})                                        ║"
echo "║     Primário: adserver01 (${PRIMARY_IP})                                 ║"
echo "║                                                                           ║"
echo "╚═══════════════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""

# Verificar root
if [[ $EUID -ne 0 ]]; then
    error "Este script deve ser executado como root (sudo)"
fi

# Verificar conectividade
if ! ping -c 2 -W 2 ${PRIMARY_IP} > /dev/null 2>&1; then
    error "Não foi possível acessar o AD Primário (${PRIMARY_IP})"
fi

# Solicitar senha
echo -e "${YELLOW}Digite a senha do administrador (MESMA do primário):${NC}"
read -s -p "> " ADMIN_PASSWORD
echo ""

if [ ${#ADMIN_PASSWORD} -lt 8 ]; then
    error "Senha deve ter pelo menos 8 caracteres"
fi

echo ""
echo -e "${YELLOW}Confirmar senha:${NC}"
read -s -p "> " ADMIN_PASSWORD_CONFIRM
echo ""

if [ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD_CONFIRM" ]; then
    error "Senhas não coincidem"
fi

echo ""
read -p "Deseja continuar com a instalação? (s/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Ss]$ ]]; then
    error "Instalação cancelada"
fi

# ============================================
# 1. CONFIGURAR HOSTNAME
# ============================================
log "1. Configurando hostname..."
hostnamectl set-hostname ${HOSTNAME}.${DOMAIN,,}
success "Hostname configurado"

# ============================================
# 2. CONFIGURAR /ETC/HOSTS
# ============================================
log "2. Configurando /etc/hosts..."
cat > /etc/hosts << EOF
127.0.0.1 localhost
127.0.1.1 ${HOSTNAME}.${DOMAIN,,} ${HOSTNAME}
${IP} ${HOSTNAME}.${DOMAIN,,} ${HOSTNAME}
${PRIMARY_IP} adserver01.${DOMAIN,,} adserver01
EOF
success "/etc/hosts configurado"

# ============================================
# 3. CONFIGURAR /ETC/RESOLV.CONF
# ============================================
log "3. Configurando /etc/resolv.conf..."
chattr -i /etc/resolv.conf 2>/dev/null || true
cat > /etc/resolv.conf << EOF
nameserver ${PRIMARY_IP}
search ${DOMAIN,,}
domain ${DOMAIN,,}
EOF
success "/etc/resolv.conf configurado"

# ============================================
# 4. INSTALAR PACOTES
# ============================================
log "4. Instalando pacotes..."
apt update -qq
apt install -y -qq \
    acl attr samba samba-dsdb-modules \
    samba-vfs-modules winbind libpam-winbind \
    libnss-winbind kinit krb5-user dnsutils \
    bind9utils ldap-utils net-tools rsync \
    bash-completion language-pack-pt locales

success "Pacotes instalados"

# ============================================
# 5. PARAR SERVIÇOS CONFLITANTES
# ============================================
log "5. Parando serviços conflitantes..."
systemctl stop smbd nmbd winbind 2>/dev/null || true
systemctl disable smbd nmbd winbind 2>/dev/null || true
success "Serviços parados"

# ============================================
# 6. LIMPAR CONFIGURAÇÕES ANTIGAS
# ============================================
log "6. Limpando configurações antigas..."
rm -rf /var/lib/samba/private 2>/dev/null || true
rm -rf /var/lib/samba/sysvol 2>/dev/null || true
rm -f /etc/samba/smb.conf
rm -f /etc/krb5.conf
success "Limpeza concluída"

# ============================================
# 7. CONFIGURAR KERBEROS
# ============================================
log "7. Configurando Kerberos..."
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
        kdc = adserver01.${DOMAIN,,}
        admin_server = adserver01.${DOMAIN,,}
        default_domain = ${DOMAIN,,}
    }

[domain_realm]
    .${DOMAIN,,} = ${REALM}
    ${DOMAIN,,} = ${REALM}
EOF

# Testar Kerberos
if echo "$ADMIN_PASSWORD" | kinit administrator@${REALM} > /dev/null 2>&1; then
    success "Kerberos funcionando"
else
    error "Falha no Kerberos. Verifique a senha."
fi

# ============================================
# 8. JOIN NO DOMÍNIO
# ============================================
log "8. Entrando no domínio..."
echo "$ADMIN_PASSWORD" | samba-tool domain join ${DOMAIN} DC \
    -U administrator \
    --realm=${REALM} \
    --dns-backend=SAMBA_INTERNAL \
    > /tmp/join.log 2>&1

if grep -q "Joined domain" /tmp/join.log; then
    success "Join realizado com sucesso!"
else
    error "Falha no join. Verifique /tmp/join.log"
fi

# ============================================
# 9. CONFIGURAR SMB.CONF
# ============================================
log "9. Configurando smb.conf..."
if [ -f "/var/lib/samba/private/smb.conf" ]; then
    cp /var/lib/samba/private/smb.conf /etc/samba/smb.conf
fi

# Adicionar configurações para Windows
cat >> /etc/samba/smb.conf << EOF

    # Configurações para Windows
    ntlm auth = yes
    raw NTLMv2 auth = yes
    lanman auth = yes
    server signing = auto
    client signing = auto
    server max protocol = SMB2
    client max protocol = SMB2
EOF

success "smb.conf configurado"

# ============================================
# 10. INICIAR SERVIÇOS
# ============================================
log "10. Iniciando serviços..."
systemctl unmask samba-ad-dc 2>/dev/null || true
systemctl enable samba-ad-dc 2>/dev/null || true
systemctl restart samba-ad-dc
sleep 10

if systemctl is-active --quiet samba-ad-dc; then
    success "Samba AD iniciado com sucesso!"
else
    error "Falha ao iniciar Samba AD"
fi

# ============================================
# 11. AJUSTAR RESOLV.CONF
# ============================================
log "11. Ajustando /etc/resolv.conf..."
chattr -i /etc/resolv.conf 2>/dev/null || true
cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
nameserver ${PRIMARY_IP}
search ${DOMAIN,,}
domain ${DOMAIN,,}
EOF
success "/etc/resolv.conf ajustado"

# ============================================
# 12. TESTAR
# ============================================
log "12. Testando..."
echo "$ADMIN_PASSWORD" | kinit administrator@${REALM} > /dev/null 2>&1

if [ $? -eq 0 ]; then
    success "Kerberos funcionando"
else
    warning "Kerberos com problemas"
fi

# ============================================
# 13. SALVAR INFORMAÇÕES
# ============================================
cat > /root/ad_info.txt << EOF
═══════════════════════════════════════════════════════════════════════════
                    AD SECUNDÁRIO CONFIGURADO
═══════════════════════════════════════════════════════════════════════════

DOMÍNIO: ${DOMAIN}
REALM: ${REALM}
IP: ${IP}
SERVIDOR: ${HOSTNAME}
PRIMÁRIO: adserver01 (${PRIMARY_IP})

═══════════════════════════════════════════════════════════════════════════
COMANDOS ÚTEIS
═══════════════════════════════════════════════════════════════════════════

# Verificar status
systemctl status samba-ad-dc

# Verificar replicação
samba-tool drs showrepl

# Forçar replicação
samba-tool drs replicate adserver01 adserver02 "DC=${DOMAIN},DC=INTRA"

═══════════════════════════════════════════════════════════════════════════
EOF

success "Informações salvas em /root/ad_info.txt"

# ============================================
# 14. RESUMO FINAL
# ============================================
clear
echo -e "${GREEN}"
echo "═══════════════════════════════════════════════════════════════════════════"
echo "                                                                           "
echo "         ✅ AD SECUNDÁRIO CONFIGURADO COM SUCESSO!                        "
echo "                                                                           "
echo "═══════════════════════════════════════════════════════════════════════════"
echo -e "${NC}"
echo ""
echo -e "${BLUE}📋 INFORMAÇÕES:${NC}"
echo ""
echo -e "  Domínio: ${GREEN}${DOMAIN}${NC}"
echo -e "  Servidor: ${GREEN}${HOSTNAME}.${DOMAIN,,}${NC}"
echo -e "  IP: ${GREEN}${IP}${NC}"
echo ""
echo -e "${YELLOW}📌 PRÓXIMOS PASSOS:${NC}"
echo ""
echo -e "  1. Verifique a replicação:"
echo -e "     ${BLUE}samba-tool drs showrepl${NC}"
echo ""
echo -e "  2. Execute no cliente Windows:"
echo -e "     ${BLUE}03_fix_windows_client.sh${NC}"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════════════${NC}"
