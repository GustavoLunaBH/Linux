# 1. Criar o arquivo manualmente
cat > configure-netplan.sh << 'EOF'
#!/bin/bash
# =============================================================================
# Script: configure-netplan.sh
# Versão: 1.3 - COMPLETO E CORRIGIDO
# Descrição: Configuração de IP via Netplan identificando arquivos existentes
# =============================================================================

# Cores para output
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

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ❌ ERRO:${NC} $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${CYAN}[$(date +'%Y-%m-%d %H:%M:%S')] ✅${NC} $1" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] ℹ️  INFO:${NC} $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] ⚠️  AVISO:${NC} $1" | tee -a "$LOG_FILE"
}

print_header() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║  $1"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Este script deve ser executado como root!"
        echo "Use: sudo ./configure-netplan.sh"
        exit 1
    fi
}

pause() {
    read -p "Pressione ENTER para continuar..."
}

confirm() {
    read -p "$1 (s/N): " -n 1 -r
    echo
    [[ $REPLY =~ ^[Ss]$ ]]
}

# =============================================================================
# FUNÇÃO: IDENTIFICAR INTERFACE DE REDE
# =============================================================================

identify_interface() {
    print_header "IDENTIFICANDO INTERFACE DE REDE"

    log_info "Identificando interfaces de rede disponíveis..."
    echo ""
    echo "Interfaces disponíveis:"
    echo "----------------------------------------"
    ip -br link | grep -v lo | awk '{print "  " $1 " - " $3}'
    echo "----------------------------------------"
    echo ""

    ACTIVE_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [[ -n "$ACTIVE_INTERFACE" ]]; then
        log_info "Interface ativa detectada: $ACTIVE_INTERFACE"
        DEFAULT_INTERFACE=$ACTIVE_INTERFACE
    else
        DEFAULT_INTERFACE=$(ip -br link | grep -v lo | awk '{print $1}' | head -n1)
        log_info "Usando interface: $DEFAULT_INTERFACE"
    fi

    read -p "Interface de rede (ex: ens33, enp0s3) [$DEFAULT_INTERFACE]: " INTERFACE
    INTERFACE=${INTERFACE:-$DEFAULT_INTERFACE}

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

    log_info "Verificando arquivos Netplan existentes..."

    NETPLAN_FILES=($(ls -1 $NETPLAN_DIR/*.yaml 2>/dev/null | sort))

    if [ ${#NETPLAN_FILES[@]} -eq 0 ]; then
        log_warning "Nenhum arquivo Netplan encontrado!"
        log_info "Criando novo arquivo: 01-netcfg.yaml"
        NETPLAN_FILE="$NETPLAN_DIR/01-netcfg.yaml"
        IS_NEW=true
        return
    fi

    echo ""
    echo "Arquivos Netplan encontrados:"
    echo "----------------------------------------"
    for i in "${!NETPLAN_FILES[@]}"; do
        echo "  $((i+1))) ${NETPLAN_FILES[$i]}"
    done
    echo "----------------------------------------"
    echo ""

    echo "Opções:"
    echo "  1) Usar arquivo existente (recomendado)"
    echo "  2) Criar novo arquivo (pode causar conflito)"
    echo "  3) Sair e editar manualmente"
    echo ""
    read -p "Escolha uma opção (1-3): " CHOICE

    case $CHOICE in
        1)
            echo ""
            for i in "${!NETPLAN_FILES[@]}"; do
                echo "  $((i+1))) ${NETPLAN_FILES[$i]}"
            done
            echo ""
            read -p "Selecione o arquivo (1-${#NETPLAN_FILES[@]}): " FILE_NUM
            FILE_NUM=$((FILE_NUM-1))

            if [[ $FILE_NUM -ge 0 && $FILE_NUM -lt ${#NETPLAN_FILES[@]} ]]; then
                NETPLAN_FILE="${NETPLAN_FILES[$FILE_NUM]}"
                IS_NEW=false
                log_info "Arquivo selecionado: $NETPLAN_FILE"
            else
                log_error "Opção inválida!"
                exit 1
            fi
            ;;
        2)
            read -p "Nome do novo arquivo (ex: 01-netcfg.yaml): " NEW_FILE
            if [[ -z "$NEW_FILE" ]]; then
                NEW_FILE="01-netcfg.yaml"
            fi
            NETPLAN_FILE="$NETPLAN_DIR/$NEW_FILE"
            IS_NEW=true
            log_info "Novo arquivo será criado: $NETPLAN_FILE"
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
# FUNÇÃO: COLETAR INFORMAÇÕES DE REDE
# =============================================================================

collect_network_info() {
    print_header "COLETANDO INFORMAÇÕES DE REDE"

    CURRENT_IP=$(ip -4 addr show "$INTERFACE" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1)
    CURRENT_GATEWAY=$(ip route | grep default | awk '{print $3}')
    CURRENT_NETMASK=$(ip -4 addr show "$INTERFACE" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f2 | head -n1)

    if [[ -n "$CURRENT_IP" ]]; then
        log_info "Configuração atual:"
        echo "  IP: $CURRENT_IP"
        echo "  Gateway: $CURRENT_GATEWAY"
        echo "  Máscara: /$CURRENT_NETMASK"
        echo ""

        if confirm "Manter o IP atual?"; then
            IP_ADDRESS=$CURRENT_IP
            NETMASK=$CURRENT_NETMASK
            GATEWAY=$CURRENT_GATEWAY
        fi
    fi

    if [[ -z "$IP_ADDRESS" ]]; then
        read -p "Endereço IP (ex: 192.168.1.10): " IP_ADDRESS
        while [[ -z "$IP_ADDRESS" ]]; do
            log_error "IP não pode estar vazio!"
            read -p "Endereço IP (ex: 192.168.1.10): " IP_ADDRESS
        done
    fi

    if [[ -z "$NETMASK" ]]; then
        read -p "Máscara de rede (ex: 24): " NETMASK
        NETMASK=${NETMASK:-24}
    fi

    if [[ -z "$GATEWAY" ]]; then
        read -p "Gateway (ex: 192.168.1.1): " GATEWAY
        while [[ -z "$GATEWAY" ]]; do
            log_error "Gateway não pode estar vazio!"
            read -p "Gateway (ex: 192.168.1.1): " GATEWAY
        done
    fi

    read -p "DNS Primário (ex: 8.8.8.8) [8.8.8.8]: " DNS1
    DNS1=${DNS1:-8.8.8.8}

    read -p "DNS Secundário (ex: 8.8.4.4) [8.8.4.4]: " DNS2
    DNS2=${DNS2:-8.8.4.4}

    read -p "Domínio de pesquisa (ex: empresa.local): " SEARCH_DOMAIN

    log_success "Informações coletadas!"
}

# =============================================================================
# FUNÇÃO: CRIAR CONFIGURAÇÃO NETPLAN
# =============================================================================

create_netplan_config() {
    print_header "CRIANDO CONFIGURAÇÃO NETPLAN"

    log_info "Criando configuração para interface: $INTERFACE"

    if [ -f "$NETPLAN_FILE" ] && [ "$IS_NEW" = false ]; then
        mkdir -p "$BACKUP_DIR"
        cp "$NETPLAN_FILE" "$BACKUP_DIR/"
        log_info "Backup criado: $BACKUP_DIR/$(basename $NETPLAN_FILE)"
    fi

    cat > "$NETPLAN_FILE" << EOF
# Configuração gerada automaticamente
# Interface: $INTERFACE
# Data: $(date)
network:
  version: 2
  ethernets:
    $INTERFACE:
      addresses:
        - $IP_ADDRESS/$NETMASK
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses:
          - $DNS1
          - $DNS2
EOF

    if [[ -n "$SEARCH_DOMAIN" ]]; then
        cat >> "$NETPLAN_FILE" << EOF
        search:
          - $SEARCH_DOMAIN
EOF
    fi

    cat >> "$NETPLAN_FILE" << EOF
      dhcp4: false
      dhcp6: false
      optional: false
EOF

    chmod 600 "$NETPLAN_FILE"

    log_success "Arquivo criado: $NETPLAN_FILE"
    echo ""
    echo "Conteúdo do arquivo:"
    echo "----------------------------------------"
    cat "$NETPLAN_FILE"
    echo "----------------------------------------"
}

# =============================================================================
# FUNÇÃO: TESTAR E APLICAR CONFIGURAÇÃO
# =============================================================================

test_and_apply() {
    print_header "TESTANDO E APLICANDO CONFIGURAÇÃO"

    log_info "Testando configuração Netplan..."
    if netplan try --timeout 10; then
        log_success "Configuração testada e aprovada!"
    else
        log_error "Falha no teste da configuração!"
        log_info "Você pode tentar corrigir manualmente ou reverter o backup."

        if confirm "Deseja reverter para a configuração anterior?"; then
            if [ -d "$BACKUP_DIR" ]; then
                cp "$BACKUP_DIR/"* "$NETPLAN_DIR/"
                log_success "Backup restaurado!"
                netplan apply
            fi
        fi
        exit 1
    fi

    log_info "Aplicando configuração..."
    netplan apply

    NEW_IP=$(ip -4 addr show "$INTERFACE" | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1)
    if [[ "$NEW_IP" == "$IP_ADDRESS" ]]; then
        log_success "IP configurado com sucesso: $IP_ADDRESS"
    else
        log_warning "IP pode não ter sido alterado. Verifique: $NEW_IP"
    fi

    log_info "Testando conectividade..."
    if ping -c 3 "$GATEWAY" > /dev/null 2>&1; then
        log_success "Gateway acessível: $GATEWAY"
    else
        log_warning "Gateway não responde: $GATEWAY"
    fi

    if ping -c 3 "$DNS1" > /dev/null 2>&1; then
        log_success "DNS acessível: $DNS1"
    else
        log_warning "DNS não responde: $DNS1"
    fi
}

# =============================================================================
# FUNÇÃO: CRIAR SCRIPT DE REVERSÃO
# =============================================================================

create_revert_script() {
    if [ -d "$BACKUP_DIR" ] && [ "$(ls -A $BACKUP_DIR)" ]; then
        REVERT_SCRIPT="/root/revert-netplan-$(date +%Y%m%d-%H%M%S).sh"

        cat > "$REVERT_SCRIPT" << 'RVT'
#!/bin/bash
echo "Revertendo configuração Netplan..."
cp -f /root/netplan-backup-*/* /etc/netplan/
netplan apply
echo "Configuração revertida!"
RVT

        chmod +x "$REVERT_SCRIPT"
        log_info "Script de reversão criado: $REVERT_SCRIPT"
        log_info "Para reverter: sudo $REVERT_SCRIPT"
    fi
}

# =============================================================================
# FUNÇÃO: VERIFICAR E AJUSTAR RESOLV.CONF
# =============================================================================

fix_resolv_conf() {
    print_header "AJUSTANDO RESOLV.CONF"

    log_info "Ajustando /etc/resolv.conf..."

    chattr -i /etc/resolv.conf 2>/dev/null

    cat > /etc/resolv.conf << EOF
# Configurado pelo script configure-netplan.sh
nameserver $DNS1
nameserver $DNS2
EOF

    if [[ -n "$SEARCH_DOMAIN" ]]; then
        echo "search $SEARCH_DOMAIN" >> /etc/resolv.conf
        echo "domain $SEARCH_DOMAIN" >> /etc/resolv.conf
    fi

    log_success "resolv.conf atualizado!"
    echo ""
    echo "Conteúdo do resolv.conf:"
    echo "----------------------------------------"
    cat /etc/resolv.conf
    echo "----------------------------------------"
}

# =============================================================================
# FUNÇÃO: RESUMO FINAL
# =============================================================================

show_summary() {
    print_header "CONFIGURAÇÃO NETPLAN CONCLUÍDA"

    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                    RESUMO DA CONFIGURAÇÃO                      ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    printf "║ %-20s: %-40s ║\n" "Interface" "$INTERFACE"
    printf "║ %-20s: %-40s ║\n" "IP" "$IP_ADDRESS/$NETMASK"
    printf "║ %-20s: %-40s ║\n" "Gateway" "$GATEWAY"
    printf "║ %-20s: %-40s ║\n" "DNS Primário" "$DNS1"
    printf "║ %-20s: %-40s ║\n" "DNS Secundário" "$DNS2"
    [[ -n "$SEARCH_DOMAIN" ]] && printf "║ %-20s: %-40s ║\n" "Domínio" "$SEARCH_DOMAIN"
    printf "║ %-20s: %-40s ║\n" "Arquivo" "$(basename $NETPLAN_FILE)"
    echo "╚══════════════════════════════════════════════════════════════════╝"

    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                    COMANDOS ÚTEIS                              ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    echo "║ 1. Verificar IP:                                               ║"
    echo "║    ip a show $INTERFACE                                        ║"
    echo "║                                                                ║"
    echo "║ 2. Testar configuração:                                        ║"
    echo "║    netplan try                                                  ║"
    echo "║                                                                ║"
    echo "║ 3. Aplicar configuração:                                       ║"
    echo "║    netplan apply                                                ║"
    echo "║                                                                ║"
    echo "║ 4. Ver logs:                                                   ║"
    echo "║    $LOG_FILE                                                    ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
}

# =============================================================================
# FUNÇÃO PRINCIPAL
# =============================================================================

main() {
    check_root

    clear
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║     CONFIGURADOR DE REDE - NETPLAN                             ║"
    echo "║     Versão: 1.3 - COMPLETO                                     ║"
    echo "║     Identifica arquivos existentes e evita duplicação          ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""

    log_info "Início: $(date)"
    log_info "Log: $LOG_FILE"
    echo ""

    identify_interface
    pause

    identify_netplan_files
    pause

    collect_network_info
    pause

    create_netplan_config
    pause

    test_and_apply
    pause

    fix_resolv_conf
    pause

    create_revert_script

    show_summary

    log_success "CONFIGURAÇÃO NETPLAN CONCLUÍDA!"

    if confirm "Deseja reiniciar a rede agora?"; then
        log_info "Reiniciando rede..."
        systemctl restart systemd-networkd
        systemctl restart systemd-resolved
        log_success "Rede reiniciada!"
    fi

    if confirm "Deseja mostrar a configuração atual da interface?"; then
        echo ""
        ip a show "$INTERFACE"
        echo ""
        echo "Rotas:"
        ip route
    fi
}

main "$@"
EOF

# 2. Tornar executável e executar
chmod +x configure-netplan.sh
sudo ./configure-netplan.sh
