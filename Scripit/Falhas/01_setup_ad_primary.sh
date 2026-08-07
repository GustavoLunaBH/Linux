#!/bin/bash
# 01_setup_ad_primary.sh
# Script COMPLETO para configurar o AD Primário do ZERO
# Versão: FINAL - Use APENAS no servidor adserver01

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
HOSTNAME="adserver01"
IP="192.168.1.2"
DNS_FORWARDER="8.8.8.8"
INTERFACE="ens33"  # ALTERE PARA SUA INTERFACE (ens33, eth0, etc)

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
echo "║     🚀 INSTALAÇÃO COMPLETA - AD PRIMÁRIO                                 ║"
echo "║                                                                           ║"
echo "║     Domínio: ${DOMAIN}                                                    ║"
echo "║     Servidor: ${HOSTNAME} (${IP})                                        ║"
echo "║                                                                           ║"
echo "╚═══════════════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""

# Verificar root
if [[ $EUID -ne 0 ]]; then
    error "Este script deve ser executado como root (sudo)"
fi

# Solicitar senha
echo -e "${YELLOW}Digite a senha do administrador (mínimo 8 caracteres):${NC}"
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
192.168.1.3 adserver02.${DOMAIN,,} adserver02
EOF
success "/etc/hosts configurado"

# ============================================
# 3. CONFIGURAR /ETC/RESOLV.CONF
# ============================================
log "3. Configurando /etc/resolv.conf..."
chattr -i /etc/resolv.conf 2>/dev/null || true
cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
search ${DOMAIN,,}
domain ${DOMAIN,,}
EOF
chattr +i /etc/resolv.conf 2>/dev/null || true
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
# 6. PROVISIONAR DOMÍNIO
# ============================================
log "6. Provisionando domínio..."
rm -rf /var/lib/samba/private 2>/dev/null || true
rm -rf /var/lib/samba/sysvol 2>/dev/null || true
rm -f /etc/samba/smb.conf

samba-tool domain provision \
    --use-rfc2307 \
    --realm=${REALM} \
    --domain=${SHORT_DOMAIN} \
    --server-role=dc \
    --dns-backend=SAMBA_INTERNAL \
    --adminpass=${ADMIN_PASSWORD} \
    --host-ip=${IP} \
    --option="interfaces=lo ${INTERFACE}" \
    --option="bind interfaces only=yes" \
    > /tmp/provision.log 2>&1

if [ $? -eq 0 ]; then
    success "Provisionamento concluído"
else
    error "Falha no provisionamento. Verifique /tmp/provision.log"
fi

# ============================================
# 7. CONFIGURAR SMB.CONF
# ============================================
log "7. Configurando smb.conf..."
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
# 8. INICIAR SERVIÇOS
# ============================================
log "8. Iniciando serviços..."
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
# 9. TESTAR
# ============================================
log "9. Testando..."
echo "$ADMIN_PASSWORD" | kinit administrator@${REALM} > /dev/null 2>&1

if [ $? -eq 0 ]; then
    success "Kerberos funcionando"
else
    warning "Kerberos com problemas"
fi

# ============================================
# 10. CRIAR USUÁRIOS INICIAIS
# ============================================
log "10. Criando usuários iniciais..."
samba-tool group add "admins" --description="Administradores" 2>/dev/null || true
samba-tool user create admin2 ${ADMIN_PASSWORD} --given-name="Admin" --surname="Secundario" 2>/dev/null || true
samba-tool group addmembers "Domain Admins" admin2 2>/dev/null || true
success "Usuários criados"

# ============================================
# 11. SALVAR INFORMAÇÕES
# ============================================
cat > /root/ad_info.txt << EOF
═══════════════════════════════════════════════════════════════════════════
                    AD PRIMÁRIO CONFIGURADO
═══════════════════════════════════════════════════════════════════════════

DOMÍNIO: ${DOMAIN}
REALM: ${REALM}
IP: ${IP}
SERVIDOR: ${HOSTNAME}
INTERFACE: ${INTERFACE}

USUÁRIO ADMIN: administrator@${REALM}
SENHA: ${ADMIN_PASSWORD}

USUÁRIO: admin2@${REALM}
SENHA: ${ADMIN_PASSWORD}

═══════════════════════════════════════════════════════════════════════════
COMANDOS ÚTEIS
═══════════════════════════════════════════════════════════════════════════

# Verificar status
systemctl status samba-ad-dc

# Verificar portas
ss -tlnp | grep -E "(389|445|464|636|3268|3269|88|53)"

# Testar Kerberos
echo '${ADMIN_PASSWORD}' | kinit administrator@${REALM}
klist

# Listar usuários
samba-tool user list

# Verificar DNS
host -t SRV _ldap._tcp.${DOMAIN,,}

═══════════════════════════════════════════════════════════════════════════
EOF

success "Informações salvas em /root/ad_info.txt"

# ============================================
# 12. RESUMO FINAL
# ============================================
clear
echo -e "${GREEN}"
echo "═══════════════════════════════════════════════════════════════════════════"
echo "                                                                           "
echo "         ✅ AD PRIMÁRIO CONFIGURADO COM SUCESSO!                          "
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
echo -e "${YELLOW}🔐 USUÁRIOS:${NC}"
echo ""
echo -e "  Administrator: ${BLUE}administrator@${REALM}${NC}"
echo -e "  Admin2: ${BLUE}admin2@${REALM}${NC}"
echo -e "  Senha: ${BLUE}${ADMIN_PASSWORD}${NC}"
echo ""
echo -e "${YELLOW}📌 PRÓXIMOS PASSOS:${NC}"
echo ""
echo -e "  1. Execute no servidor SECUNDÁRIO:"
echo -e "     ${BLUE}02_setup_ad_secondary.sh${NC}"
echo ""
echo -e "  2. Configure os clientes Windows:"
echo -e "     ${BLUE}03_fix_windows_client.sh${NC}"
echo ""
echo -e "  3. Verifique a replicação:"
echo -e "     ${BLUE}04_check_replication.sh${NC}"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════════════${NC}"
