#!/bin/bash
# 05_firewall_ports.sh
# Script para abrir portas no firewall
# Versão: FINAL - Execute em AMBOS os servidores

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"; }
success() { echo -e "${GREEN}[SUCESSO]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Este script deve ser executado como root (sudo)${NC}"
    exit 1
fi

clear
echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════════════════════════════════════╗"
echo "║                                                                           ║"
echo "║     🔥 CONFIGURANDO FIREWALL                                             ║"
echo "║                                                                           ║"
echo "╚═══════════════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""

# Portas do AD
PORTS="389 445 464 636 3268 3269 135 139 88 53 49152-65535"

log "Abrindo portas do Active Directory..."

# Verificar qual firewall está ativo
if command -v ufw &> /dev/null; then
    log "UFW detectado..."
    
    # Habilitar UFW
    ufw --force enable
    
    # Liberar portas
    for port in $PORTS; do
        ufw allow $port/tcp 2>/dev/null || true
    done
    
    # Liberar UDP
    ufw allow 53/udp 2>/dev/null || true
    ufw allow 123/udp 2>/dev/null || true
    ufw allow 137-138/udp 2>/dev/null || true
    
    success "UFW configurado"
    ufw status

elif command -v firewall-cmd &> /dev/null; then
    log "Firewalld detectado..."
    
    for port in $PORTS; do
        firewall-cmd --permanent --add-port=$port/tcp 2>/dev/null || true
    done
    
    firewall-cmd --permanent --add-port=53/udp 2>/dev/null || true
    firewall-cmd --permanent --add-port=123/udp 2>/dev/null || true
    firewall-cmd --permanent --add-port=137-138/udp 2>/dev/null || true
    
    firewall-cmd --reload 2>/dev/null || true
    
    success "Firewalld configurado"
    firewall-cmd --list-ports

elif command -v iptables &> /dev/null; then
    log "IPtables detectado..."
    
    for port in $PORTS; do
        iptables -A INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || true
    done
    
    iptables -A INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || true
    iptables -A INPUT -p udp --dport 123 -j ACCEPT 2>/dev/null || true
    iptables -A INPUT -p udp --dport 137:138 -j ACCEPT 2>/dev/null || true
    
    # Salvar regras
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    
    success "IPtables configurado"
else
    log "Nenhum firewall detectado. Portas já estão abertas."
fi

echo ""
success "✅ FIREWALL CONFIGURADO!"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════════════${NC}"
