#!/bin/bash
# 03_fix_windows_client.sh
# Script para corrigir problemas de autenticação de clientes Windows
# Versão: FINAL - Execute em AMBOS os servidores

set -e

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DOMAIN="RNV.INTRA"
REALM="RNV.INTRA"
PRIMARY_IP="192.168.1.2"
SECONDARY_IP="192.168.1.3"

log() { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERRO]${NC} $1"; exit 1; }
success() { echo -e "${GREEN}[SUCESSO]${NC} $1"; }
warning() { echo -e "${YELLOW}[AVISO]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    error "Este script deve ser executado como root (sudo)"
fi

clear
echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════════════════════════════════════╗"
echo "║                                                                           ║"
echo "║     🖥️  CORREÇÃO PARA CLIENTES WINDOWS                                   ║"
echo "║                                                                           ║"
echo "╚═══════════════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""

# Solicitar senha
echo -e "${YELLOW}Digite a senha do administrador:${NC}"
read -s -p "> " ADMIN_PASSWORD
echo ""

export ADMIN_PASSWORD

# ============================================
# 1. PARAR SERVIÇOS
# ============================================
log "1. Parando serviços..."
systemctl stop samba-ad-dc 2>/dev/null || true
pkill -9 -f samba 2>/dev/null || true
sleep 3
success "Serviços parados"

# ============================================
# 2. RECONFIGURAR SMB.CONF
# ============================================
log "2. Reconfigurando smb.conf..."

# Backup
cp /etc/samba/smb.conf /etc/samba/smb.conf.bak 2>/dev/null || true

# Adicionar configurações para Windows
cat >> /etc/samba/smb.conf << EOF

    # Configurações para Windows 7/10/11
    ntlm auth = yes
    raw NTLMv2 auth = yes
    lanman auth = yes
    server signing = auto
    client signing = auto
    server schannel = auto
    client schannel = auto
    allow insecure wide links = yes
    client max protocol = SMB2
    server max protocol = SMB2
    client min protocol = SMB2
    dns forwarder = 8.8.8.8
EOF

success "smb.conf atualizado"

# ============================================
# 3. INICIAR SERVIÇOS
# ============================================
log "3. Iniciando serviços..."
systemctl unmask samba-ad-dc 2>/dev/null || true
systemctl enable samba-ad-dc 2>/dev/null || true
systemctl start samba-ad-dc
sleep 10

if systemctl is-active --quiet samba-ad-dc; then
    success "Samba AD iniciado"
else
    error "Falha ao iniciar Samba AD"
fi

# ============================================
# 4. REGISTRAR DNS
# ============================================
log "4. Registrando DNS..."
samba-tool dns add 127.0.0.1 ${DOMAIN,,} _ldap._tcp SRV "adserver01.${DOMAIN,,}" 389 100 0 -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null || true
samba-tool dns add 127.0.0.1 ${DOMAIN,,} _ldap._tcp SRV "adserver02.${DOMAIN,,}" 389 100 0 -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null || true
samba-tool dns add 127.0.0.1 ${DOMAIN,,} _kerberos._tcp SRV "adserver01.${DOMAIN,,}" 88 100 0 -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null || true
samba-tool dns add 127.0.0.1 ${DOMAIN,,} _kerberos._tcp SRV "adserver02.${DOMAIN,,}" 88 100 0 -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null || true
success "DNS registrado"

# ============================================
# 5. VERIFICAR
# ============================================
log "5. Verificando..."
ss -tlnp 2>/dev/null | grep -E "(389|445|464|636|3268|3269|88|53)" | grep LISTEN

echo ""
success "✅ CORREÇÃO CONCLUÍDA!"

echo ""
echo -e "${YELLOW}📌 CONFIGURAÇÕES PARA O WINDOWS:${NC}"
echo ""
echo -e "  DNS Primário: ${BLUE}${PRIMARY_IP}${NC}"
echo -e "  DNS Secundário: ${BLUE}${SECONDARY_IP}${NC}"
echo -e "  Sufixo DNS: ${BLUE}${DOMAIN,,}${NC}"
echo ""
echo -e "  Domínio: ${BLUE}${DOMAIN}${NC}"
echo -e "  Usuário: ${BLUE}administrator@${DOMAIN}${NC}"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════════════${NC}"
