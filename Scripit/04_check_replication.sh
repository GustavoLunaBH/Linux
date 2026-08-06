#!/bin/bash
# 04_check_replication.sh
# Script para verificar e corrigir replicação
# Versão: FINAL - Execute em AMBOS os servidores

set -e

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

# Solicitar senha
echo -e "${YELLOW}Digite a senha do administrador:${NC}"
read -s -p "> " ADMIN_PASSWORD
echo ""
export ADMIN_PASSWORD

clear
echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════════════════════════════════════╗"
echo "║                                                                           ║"
echo "║     🔄 VERIFICAÇÃO DE REPLICAÇÃO                                         ║"
echo "║                                                                           ║"
echo "╚═══════════════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""

# ============================================
# 1. VERIFICAR STATUS
# ============================================
log "1. Status da replicação:"
echo ""
samba-tool drs showrepl 2>&1

# ============================================
# 2. FORÇAR REPLICAÇÃO
# ============================================
echo ""
log "2. Forçando replicação..."

CURRENT_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -1)

if [[ "$CURRENT_IP" == "$PRIMARY_IP" ]]; then
    log "Forçando do Primário para o Secundário..."
    samba-tool drs replicate adserver02 adserver01 "DC=${DOMAIN},DC=INTRA" -U administrator --password="$ADMIN_PASSWORD" 2>&1
else
    log "Forçando do Secundário para o Primário..."
    samba-tool drs replicate adserver01 adserver02 "DC=${DOMAIN},DC=INTRA" -U administrator --password="$ADMIN_PASSWORD" 2>&1
fi

success "Replicação forçada"

# ============================================
# 3. TESTAR COM USUÁRIO
# ============================================
echo ""
log "3. Testando com usuário..."

TEST_USER="test_repl_$(date +%s)"

if samba-tool user create $TEST_USER Test@1234 --given-name="Test" --surname="Replication" -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null; then
    success "Usuário de teste criado"
    
    sleep 10
    
    # Verificar no outro servidor
    if [[ "$CURRENT_IP" == "$PRIMARY_IP" ]]; then
        if samba-tool user list --host=$SECONDARY_IP -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null | grep -q "$TEST_USER"; then
            success "✅ REPLICAÇÃO FUNCIONANDO PERFEITAMENTE!"
        else
            warning "⚠️ Usuário não replicado"
        fi
    else
        if samba-tool user list --host=$PRIMARY_IP -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null | grep -q "$TEST_USER"; then
            success "✅ REPLICAÇÃO FUNCIONANDO PERFEITAMENTE!"
        else
            warning "⚠️ Usuário não replicado"
        fi
    fi
    
    # Limpar
    samba-tool user delete $TEST_USER -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null || true
else
    warning "Não foi possível criar usuário de teste"
fi

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════════════${NC}"
