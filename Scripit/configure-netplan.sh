cat > configure-netplan.sh << 'SCRIPT_COMPLETO'
#!/bin/bash
# =============================================================================
# Script: configure-netplan.sh
# Versão: 2.0 - DEFINITIVO
# Descrição: Configuração de IP via Netplan identificando arquivos existentes
# =============================================================================

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Variáveis
NETPLAN_DIR="/etc/netplan"
BACKUP_DIR="/root/netplan-backup-$(date +%Y%m%d-%H%M%S)"
LOG_FILE="/root/netplan-config-$(date +%Y%m%d-%H%M%S).log"

# =============================================================================
# FUNÇÕES
# =============================================================================

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ❌ ERRO:${NC} $1" | tee -a "$LOG_FILE"; }
log_success() { echo -e "${CYAN}[$(date +'%Y-%m-%d %H:%M:%S')] ✅${NC} $1" | tee -a "$LOG_FILE"; }
log_info() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] ℹ️  INFO:${NC} $1" | tee -a "$LOG_FILE"; }
log_warning() { echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] ⚠️  AVISO:${NC} $1" | tee -a "$LOG_FILE"; }

print_header() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║  $1"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
}

pause() { read -p "Pressione ENTER para continuar..."; }
confirm() { read -p "$1 (s/N): " -n 1 -r; echo; [[ $REPLY =~ ^[Ss]$ ]]; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Este script deve ser executado como root!${NC}"
        echo "Use: sudo ./configure-netplan.sh"
        exit 1
    fi
}

# =============================================================================
# FUNÇÃO: IDENTIFICAR INTERFACE
# =============================================================================

identify_interface() {
    print_header "IDENTIFICANDO INTERFACE DE REDE"
    
    echo "Interfaces disponíveis:"
    echo "----------------------------------------"
    ip -br link | grep -v lo
    echo "----------------------------------------"
    echo ""
    
    read -p "Nome da interface (ex: ens33): " INTERFACE
    
    if [[ -z "$INTERFACE" ]]; then
        INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
        log_info "Usando interface detectada: $INTERFACE"
    fi
    
    if ! ip link show "$INTERFACE" > /dev/null 2>&1; then
        log_error "Interface $INTERFACE não encontrada!"
        exit 1
    fi
    
    log_success "Interface selecionada: $INTERFACE"
}

# =============================================================================
# FUNÇÃO: IDENTIFICAR ARQUIVOS NETPLAN
# =============================================================================

identify_netplan_files() {
    print_header "IDENTIFICANDO ARQUIVOS NETPLAN"
    
    echo "Arquivos Netplan existentes:"
    echo "----------------------------------------"
    ls -la $NETPLAN_DIR/*.yaml 2>/dev/null || echo "  Nenhum arquivo encontrado"
    echo "----------------------------------------"
    echo ""
    
    NETPLAN_FILES=($(ls -1 $NETPLAN_DIR/*.yaml 2>/dev/null | sort))
    
    if [ ${#NETPLAN_FILES[@]} -eq 0 ]; then
        log_warning "Nenhum arquivo Netplan encontrado!"
        NETPLAN_FILE="$NETPLAN_DIR/01-netcfg.yaml"
        log_info "Será criado: $NETPLAN_FILE"
        return
    fi
    
    echo "Opções:"
    echo "  1) Editar arquivo existente"
    echo "  2) Criar novo arquivo"
    echo "  3) Sair"
    echo ""
    read -p "Escolha (1-3): " CHOICE
    
    case $CHOICE in
        1)
            echo ""
            for i in "${!NETPLAN_FILES[@]}"; do
                echo "  $((i+1))) ${NETPLAN_FILES[$i]}"
            done
            echo ""
            read -p "Selecione o arquivo (1-${#NETPLAN_FILES[@]}): " FILE_NUM
            FILE_NUM=$((FILE_NUM-1))
            NETPLAN_FILE="${NETPLAN_FILES[$FILE_NUM]}"
            log_info "Editando: $NETPLAN_FILE"
            ;;
        2)
            read -p "Nome do novo arquivo [01-netcfg.yaml]: " NEW_FILE
            NEW_FILE=${NEW_FILE:-01-netcfg.yaml}
            NETPLAN_FILE="$NETPLAN_DIR/$NEW_FILE"
            log_info "Criando: $NETPLAN_FILE"
            ;;
        3)
            log_info "Saindo..."
            exit 0
            ;;
        *)
            log_error "Opção inválida!"
            exit 1
            ;;
    esac
}

# =============================================================================
# FUNÇÃO: COLETAR DADOS
# =============================================================================

collect_data() {
    print_header "COLETANDO DADOS DE REDE"
    
    CURRENT_IP=$(ip -4 addr show "$INTERFACE" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1)
    CURRENT_GATEWAY=$(ip route | grep default | awk '{print $3}')
    
    if [[ -n "$CURRENT_IP" ]]; then
        log_info "IP atual: $CURRENT_IP"
        echo "Gateway: $CURRENT_GATEWAY"
        echo ""
        if confirm "Manter o IP atual?"; then
            IP_ADDRESS=$CURRENT_IP
            GATEWAY=$CURRENT_GATEWAY
        fi
    fi
    
    if [[ -z "$IP_ADDRESS" ]]; then
        read -p "Novo IP (ex: 192.168.1.10): " IP_ADDRESS
    fi
    
    read -p "Máscara (ex: 24) [24]: " NETMASK
    NETMASK=${NETMASK:-24}
    
    read -p "Gateway (ex: 192.168.1.1): " GATEWAY
    while [[ -z "$GATEWAY" ]]; do
        log_error "Gateway obrigatório!"
        read -p "Gateway: " GATEWAY
    done
    
    read -p "DNS 1 [8.8.8.8]: " DNS1
    DNS1=${DNS1:-8.8.8.8}
    
    read -p "DNS 2 [8.8.4.4]: " DNS2
    DNS2=${DNS2:-8.8.4.4}
    
    read -p "Domínio de pesquisa (ex: empresa.local): " DOMAIN
}

# =============================================================================
# FUNÇÃO: CRIAR ARQUIVO NETPLAN
# =============================================================================

create_netplan() {
    print_header "CRIANDO ARQUIVO NETPLAN"
    
    if [ -f "$NETPLAN_FILE" ]; then
        mkdir -p "$BACKUP_DIR"
        cp "$NETPLAN_FILE" "$BACKUP_DIR/"
        log_info "Backup criado: $BACKUP_DIR/$(basename $NETPLAN_FILE)"
    fi
    
    echo "# Configuração gerada em $(date)" > "$NETPLAN_FILE"
    echo "# Interface: $INTERFACE" >> "$NETPLAN_FILE"
    echo "network:" >> "$NETPLAN_FILE"
    echo "  version: 2" >> "$NETPLAN_FILE"
    echo "  ethernets:" >> "$NETPLAN_FILE"
    echo "    $INTERFACE:" >> "$NETPLAN_FILE"
    echo "      addresses:" >> "$NETPLAN_FILE"
    echo "        - $IP_ADDRESS/$NETMASK" >> "$NETPLAN_FILE"
    echo "      routes:" >> "$NETPLAN_FILE"
    echo "        - to: default" >> "$NETPLAN_FILE"
    echo "          via: $GATEWAY" >> "$NETPLAN_FILE"
    echo "      nameservers:" >> "$NETPLAN_FILE"
    echo "        addresses:" >> "$NETPLAN_FILE"
    echo "          - $DNS1" >> "$NETPLAN_FILE"
    echo "          - $DNS2" >> "$NETPLAN_FILE"
    
    if [[ -n "$DOMAIN" ]]; then
        echo "        search:" >> "$NETPLAN_FILE"
        echo "          - $DOMAIN" >> "$NETPLAN_FILE"
    fi
    
    echo "      dhcp4: false" >> "$NETPLAN_FILE"
    echo "      dhcp6: false" >> "$NETPLAN_FILE"
    echo "      optional: false" >> "$NETPLAN_FILE"
    
    chmod 600 "$NETPLAN_FILE"
    
    log_success "Arquivo criado: $NETPLAN_FILE"
    echo ""
    echo "Conteúdo:"
    echo "----------------------------------------"
    cat "$NETPLAN_FILE"
    echo "----------------------------------------"
}

# =============================================================================
# FUNÇÃO: TESTAR E APLICAR
# =============================================================================

test_and_apply() {
    print_header "TESTANDO E APLICANDO"
    
    log_info "Testando configuração..."
    if netplan try --timeout 10; then
        log_success "Teste aprovado!"
    else
        log_error "Falha no teste!"
        if confirm "Reverter backup?"; then
            [ -d "$BACKUP_DIR" ] && cp "$BACKUP_DIR"/* "$NETPLAN_DIR/"
            netplan apply
            log_success "Revertido!"
        fi
        exit 1
    fi
    
    log_info "Aplicando..."
    netplan apply
    
    NEW_IP=$(ip -4 addr show "$INTERFACE" | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1)
    if [[ "$NEW_IP" == "$IP_ADDRESS" ]]; then
        log_success "IP aplicado: $IP_ADDRESS"
    fi
    
    ping -c 3 "$GATEWAY" > /dev/null 2>&1 && log_success "Gateway OK" || log_warning "Gateway falhou"
    ping -c 3 "$DNS1" > /dev/null 2>&1 && log_success "DNS OK" || log_warning "DNS falhou"
}

# =============================================================================
# FUNÇÃO: RESOLV.CONF
# =============================================================================

fix_resolv() {
    print_header "AJUSTANDO RESOLV.CONF"
    
    chattr -i /etc/resolv.conf 2>/dev/null
    
    echo "# Configurado em $(date)" > /etc/resolv.conf
    echo "nameserver $DNS1" >> /etc/resolv.conf
    echo "nameserver $DNS2" >> /etc/resolv.conf
    
    if [[ -n "$DOMAIN" ]]; then
        echo "search $DOMAIN" >> /etc/resolv.conf
        echo "domain $DOMAIN" >> /etc/resolv.conf
    fi
    
    log_success "resolv.conf atualizado!"
    cat /etc/resolv.conf
}

# =============================================================================
# FUNÇÃO: RESUMO
# =============================================================================

show_summary() {
    print_header "CONFIGURAÇÃO CONCLUÍDA"
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                    RESUMO DA CONFIGURAÇÃO                      ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    printf "║ %-15s: %-45s ║\n" "Interface" "$INTERFACE"
    printf "║ %-15s: %-45s ║\n" "IP" "$IP_ADDRESS/$NETMASK"
    printf "║ %-15s: %-45s ║\n" "Gateway" "$GATEWAY"
    printf "║ %-15s: %-45s ║\n" "DNS 1" "$DNS1"
    printf "║ %-15s: %-45s ║\n" "DNS 2" "$DNS2"
    [[ -n "$DOMAIN" ]] && printf "║ %-15s: %-45s ║\n" "Domínio" "$DOMAIN"
    printf "║ %-15s: %-45s ║\n" "Arquivo" "$(basename $NETPLAN_FILE)"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    
    echo ""
    echo "COMANDOS:"
    echo "  ip a show $INTERFACE"
    echo "  netplan try"
    echo "  netplan apply"
    echo ""
    echo "LOG: $LOG_FILE"
}

# =============================================================================
# FUNÇÃO PRINCIPAL
# =============================================================================

main() {
    check_root
    
    clear
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║     CONFIGURADOR DE REDE - NETPLAN                             ║"
    echo "║     Versão: 2.0 - DEFINITIVO                                   ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    
    log_info "Início: $(date)"
    log_info "Log: $LOG_FILE"
    echo ""
    
    identify_interface
    pause
    
    identify_netplan_files
    pause
    
    collect_data
    pause
    
    create_netplan
    pause
    
    test_and_apply
    pause
    
    fix_resolv
    pause
    
    show_summary
    
    log_success "CONFIGURAÇÃO CONCLUÍDA!"
    
    if confirm "Deseja reiniciar a rede?"; then
        systemctl restart systemd-networkd
        systemctl restart systemd-resolved
        log_success "Rede reiniciada!"
    fi
}

main "$@"
SCRIPT_COMPLETO

chmod +x configure-netplan.sh
sudo ./configure-netplan.sh
