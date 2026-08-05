#!/bin/bash
# ad_controller_setup.sh
# Script completo para instalação do Samba AD - Controlador de Domínio
# Versão: 2.8 - Código refatorado, sem duplicidades

# ============================================
# CORES PARA OUTPUT
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'
BOLD='\033[1m'

# ============================================
# CONFIGURAÇÕES PADRÃO
# ============================================
DOMAIN="RNV.INTRA"
REALM="RNV.INTRA"
SHORT_DOMAIN="RNV"
ADMIN_USER="administrator"
ADMIN_PASSWORD=""
FIXED_IP=""
FIXED_GATEWAY="192.168.1.1"
INTERFACE=""
DNS_FORWARDER="8.8.8.8"
NTP_SERVER="a.st1.ntp.br"
PRIMARY_DC_IP="192.168.1.2"
PRIMARY_DC_HOSTNAME="adserver01"
SCRIPT_VERSION="2.8"
LOG_FILE="/tmp/ad_setup_$(date +%Y%m%d_%H%M%S).log"
INSTALLATION_TYPE=""
HOSTNAME=""
NETWORK_CONFIGURED=false
NETPLAN_FILE=""

# ============================================
# FUNÇÕES PRINCIPAIS
# ============================================

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}${BOLD}[ERRO]${NC} $1" | tee -a "$LOG_FILE"
    echo ""
    echo -e "${YELLOW}Últimas 20 linhas do log:${NC}"
    tail -20 "$LOG_FILE"
    exit 1
}

warning() {
    echo -e "${YELLOW}[AVISO]${NC} $1" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}✓${NC} $1" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${CYAN}ℹ${NC} $1" | tee -a "$LOG_FILE"
}

header() {
    echo -e "${CYAN}"
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  $1"
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "${NC}"
}

get_os_info() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_INFO="${PRETTY_NAME}"
    else
        OS_INFO="Linux $(uname -r)"
    fi
    KERNEL_VERSION=$(uname -r)
}

print_banner() {
    clear
    echo -e "${MAGENTA}"
    echo "    ╔══════════════════════════════════════════════════════════════╗"
    echo "    ║                                                              ║"
    echo "    ║     █████╗ ██████╗      ███████╗███████╗████████╗██╗   ██╗  ║"
    echo "    ║    ██╔══██╗██╔══██╗     ██╔════╝██╔════╝╚══██╔══╝██║   ██║  ║"
    echo "    ║    ███████║██║  ██║     ███████╗█████╗     ██║   ██║   ██║  ║"
    echo "    ║    ██╔══██║██║  ██║     ╚════██║██╔══╝     ██║   ██║   ██║  ║"
    echo "    ║    ██║  ██║██████╔╝     ███████║███████╗   ██║   ╚██████╔╝  ║"
    echo "    ║    ╚═╝  ╚═╝╚═════╝      ╚══════╝╚══════╝   ╚═╝    ╚═════╝   ║"
    echo "    ║                                                              ║"
    echo "    ║           INSTALADOR DO CONTROLADOR DE DOMÍNIO               ║"
    echo "    ║                  Samba AD - Versão ${SCRIPT_VERSION}                        ║"
    echo "    ╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ============================================
# DETECÇÃO DE SISTEMA - FUNÇÕES REUTILIZÁVEIS
# ============================================

detect_interface() {
    local interfaces=$(ip -o link show | grep -v "lo:" | grep -v "@" | grep "state UP" | awk -F': ' '{print $2}' | head -1)
    if [ -z "$interfaces" ]; then
        interfaces=$(ip -o link show | grep -v "lo:" | grep -v "@" | awk -F': ' '{print $2}' | head -1)
    fi
    if [ -n "$interfaces" ]; then
        INTERFACE="$interfaces"
        return 0
    else
        error "Nenhuma interface de rede encontrada!"
    fi
}

detect_ip() {
    local current_ip=$(ip -4 addr show ${INTERFACE} 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    if [ -n "$current_ip" ] && [ "$current_ip" != "127.0.0.1" ]; then
        FIXED_IP="$current_ip"
        return 0
    fi
    return 1
}

detect_gateway() {
    local gateway=$(ip route | grep default | awk '{print $3}' | head -1)
    if [ -n "$gateway" ]; then
        FIXED_GATEWAY="$gateway"
        return 0
    fi
    return 1
}

detect_domain() {
    local current_domain=$(hostname -d 2>/dev/null | tr '[:lower:]' '[:upper:]')
    if [ -n "$current_domain" ] && [ "$current_domain" != "" ]; then
        DOMAIN="$current_domain"
        REALM="$DOMAIN"
        SHORT_DOMAIN=$(echo $DOMAIN | cut -d. -f1)
        return 0
    fi
    return 1
}

detect_netplan_file() {
    # Verificar arquivos existentes em ordem de prioridade
    if [ -f "/etc/netplan/50-cloud-init.yaml" ]; then
        NETPLAN_FILE="/etc/netplan/50-cloud-init.yaml"
    elif [ -f "/etc/netplan/01-netcfg.yaml" ]; then
        NETPLAN_FILE="/etc/netplan/01-netcfg.yaml"
    elif [ -f "/etc/netplan/00-installer-config.yaml" ]; then
        NETPLAN_FILE="/etc/netplan/00-installer-config.yaml"
    else
        local existing_file=$(ls /etc/netplan/*.yaml 2>/dev/null | head -1)
        if [ -n "$existing_file" ]; then
            NETPLAN_FILE="$existing_file"
        else
            NETPLAN_FILE="/etc/netplan/01-netcfg.yaml"
        fi
    fi
}

# Função unificada para detectar todas as configurações
detect_all() {
    detect_interface
    detect_ip
    detect_gateway
    detect_domain
    detect_netplan_file
}

# ============================================
# FUNÇÃO UNIFICADA PARA CRIAR/ATUALIZAR NETPLAN
# ============================================

update_netplan() {
    local ip="$1"
    local netmask="${2:-24}"
    local gateway="$3"
    local dns1="$4"
    local dns2="${5:-8.8.8.8}"
    local search_domain="${6:-${DOMAIN,,}}"
    
    # Se não recebeu parâmetros, usar os valores atuais
    [ -z "$ip" ] && ip="$FIXED_IP"
    [ -z "$gateway" ] && gateway="$FIXED_GATEWAY"
    [ -z "$dns1" ] && dns1="$FIXED_IP"
    
    log "Atualizando netplan no arquivo: ${NETPLAN_FILE}"
    
    # Backup do arquivo existente
    if [ -f "${NETPLAN_FILE}" ]; then
        cp "${NETPLAN_FILE}" "${NETPLAN_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    fi
    
    # Criar/atualizar arquivo
    cat > ${NETPLAN_FILE} << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${INTERFACE}:
      dhcp4: false
      dhcp6: false
      addresses:
        - ${ip}/${netmask}
      routes:
        - to: default
          via: ${gateway}
      nameservers:
        addresses:
          - ${dns1}
          - ${dns2}
        search:
          - ${search_domain}
EOF
    
    # Desabilitar outros arquivos de rede
    for file in /etc/netplan/*.yaml; do
        if [ "$file" != "${NETPLAN_FILE}" ] && [ -f "$file" ]; then
            mv "$file" "$file.disabled.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        fi
    done
    
    success "Arquivo ${NETPLAN_FILE} atualizado"
}

# ============================================
# FUNÇÃO UNIFICADA PARA APLICAR NETPLAN
# ============================================

apply_netplan() {
    log "Aplicando configurações de rede..."
    
    if netplan try --timeout 5 2>/dev/null; then
        success "Netplan configurado com sucesso!"
    else
        warning "Falha ao aplicar netplan, tentando force..."
        netplan apply 2>/dev/null
    fi
    
    log "Reiniciando serviços de rede..."
    systemctl restart systemd-networkd 2>/dev/null
    systemctl restart systemd-resolved 2>/dev/null
    
    ip addr flush dev ${INTERFACE} 2>/dev/null
    netplan apply 2>/dev/null
    sleep 3
    
    local new_ip=$(ip -4 addr show ${INTERFACE} 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    if [ -n "$new_ip" ]; then
        success "Nova configuração aplicada: ${new_ip}"
        FIXED_IP="$new_ip"
        NETWORK_CONFIGURED=true
        return 0
    else
        error "Falha ao aplicar configuração de rede"
    fi
}

# ============================================
# FUNÇÃO UNIFICADA PARA REMOVER DHCP
# ============================================

stop_dhcp_services() {
    log "Parando todos os serviços DHCP..."
    systemctl stop dhcpcd 2>/dev/null || true
    systemctl disable dhcpcd 2>/dev/null || true
    systemctl stop network-manager 2>/dev/null || true
    systemctl disable network-manager 2>/dev/null || true
    systemctl stop systemd-networkd 2>/dev/null || true
    pkill -f dhclient 2>/dev/null || true
    pkill -f dhcpcd 2>/dev/null || true
    
    log "Removendo IPs antigos e configurando IP fixo..."
    ip addr flush dev ${INTERFACE}
    ip addr add ${FIXED_IP}/24 dev ${INTERFACE}
    ip route add default via ${FIXED_GATEWAY}
}

# ============================================
# AUTO DETECT - USANDO FUNÇÕES REUTILIZÁVEIS
# ============================================

auto_detect() {
    header "DETECTANDO CONFIGURAÇÕES DO SISTEMA"
    detect_all
    echo ""
    echo -e "  Interface: ${CYAN}${INTERFACE}${NC}"
    echo -e "  IP: ${CYAN}${FIXED_IP:-Não detectado}${NC}"
    echo -e "  Gateway: ${CYAN}${FIXED_GATEWAY}${NC}"
    echo -e "  Domínio: ${CYAN}${DOMAIN}${NC}"
    echo -e "  Arquivo Rede: ${CYAN}${NETPLAN_FILE}${NC}"
    echo ""
}

# ============================================
# MENU DE CONFIGURAÇÃO DE REDE (REFATORADO)
# ============================================

configure_network() {
    header "CONFIGURAÇÃO DE REDE"
    
    echo -e "${YELLOW}⚠️  ATENÇÃO: A configuração de rede deve ser feita ANTES da instalação${NC}"
    echo ""
    
    detect_all
    
    echo -e "${BLUE}Configurações atuais do sistema:${NC}"
    echo -e "  Interface: ${CYAN}${INTERFACE}${NC}"
    echo -e "  IP Atual: ${CYAN}${FIXED_IP:-Não detectado}${NC}"
    echo -e "  Gateway: ${CYAN}${FIXED_GATEWAY}${NC}"
    echo -e "  Arquivo Rede: ${CYAN}${NETPLAN_FILE}${NC}"
    echo ""
    
    echo -e "${WHITE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${WHITE}║                    OPÇÕES DE REDE                           ║${NC}"
    echo -e "${WHITE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${GREEN} 1)${NC} ${BOLD}Configurar IP Fixo${NC}"
    echo -e "     ${CYAN}➜${NC} Define IP, máscara e gateway"
    echo ""
    echo -e "${GREEN} 2)${NC} ${BOLD}Configurar DNS${NC}"
    echo -e "     ${CYAN}➜${NC} Define servidores DNS"
    echo ""
    echo -e "${GREEN} 3)${NC} ${BOLD}Verificar Configuração${NC}"
    echo -e "     ${CYAN}➜${NC} Mostra configurações atuais"
    echo ""
    echo -e "${GREEN} 4)${NC} ${BOLD}Testar Conectividade${NC}"
    echo -e "     ${CYAN}➜${NC} Testa ping e resolução DNS"
    echo ""
    echo -e "${GREEN} 5)${NC} ${BOLD}Aplicar e Reiniciar Rede${NC}"
    echo -e "     ${CYAN}➜${NC} Aplica configurações e reinicia rede"
    echo ""
    echo -e "${GREEN} 6)${NC} ${BOLD}Voltar ao Menu Principal${NC}"
    echo ""
    echo -e "${WHITE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    while true; do
        read -p "👉 Escolha uma opção [1-6]: " choice
        case $choice in
            1)
                configure_fixed_ip
                break
                ;;
            2)
                configure_dns_settings
                break
                ;;
            3)
                show_network_status
                break
                ;;
            4)
                test_connectivity
                break
                ;;
            5)
                apply_netplan
                break
                ;;
            6)
                return 0
                ;;
            *)
                echo -e "${RED}Opção inválida! Tente novamente.${NC}"
                ;;
        esac
    done
    
    configure_network
}

configure_fixed_ip() {
    header "CONFIGURANDO IP FIXO"
    
    detect_all
    
    echo -e "${BLUE}Interface detectada: ${CYAN}${INTERFACE}${NC}"
    echo -e "${BLUE}Arquivo de rede atual: ${CYAN}${NETPLAN_FILE}${NC}"
    echo -e "${BLUE}IP atual: ${CYAN}${FIXED_IP:-Não configurado}${NC}"
    echo ""
    
    echo -e "${BLUE}Digite o IP fixo [${FIXED_IP:-192.168.1.2}]:${NC}"
    read -p "> " IP_INPUT
    [ -n "$IP_INPUT" ] && FIXED_IP="$IP_INPUT"
    [ -z "$FIXED_IP" ] && FIXED_IP="192.168.1.2"
    
    echo -e "${BLUE}Digite a máscara de rede [24]:${NC}"
    read -p "> " NETMASK_INPUT
    [ -z "$NETMASK_INPUT" ] && NETMASK_INPUT="24"
    
    echo -e "${BLUE}Digite o gateway [${FIXED_GATEWAY}]:${NC}"
    read -p "> " GATEWAY_INPUT
    [ -n "$GATEWAY_INPUT" ] && FIXED_GATEWAY="$GATEWAY_INPUT"
    
    echo ""
    echo -e "${YELLOW}⚠️  Será aplicada a seguinte configuração:${NC}"
    echo -e "  Interface: ${CYAN}${INTERFACE}${NC}"
    echo -e "  IP: ${CYAN}${FIXED_IP}/${NETMASK_INPUT}${NC}"
    echo -e "  Gateway: ${CYAN}${FIXED_GATEWAY}${NC}"
    echo -e "  Arquivo: ${CYAN}${NETPLAN_FILE}${NC}"
    echo ""
    
    read -p "Deseja aplicar esta configuração? (S/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        info "Configuração cancelada"
        return
    fi
    
    # Usar função unificada
    update_netplan "${FIXED_IP}" "${NETMASK_INPUT}" "${FIXED_GATEWAY}"
    
    success "Configuração salva. Use a Opção 5 para aplicar e reiniciar a rede."
}

configure_dns_settings() {
    header "CONFIGURANDO DNS"
    
    echo -e "${BLUE}Digite o IP do DNS primário [8.8.8.8]:${NC}"
    read -p "> " DNS1
    [ -z "$DNS1" ] && DNS1="8.8.8.8"
    
    echo -e "${BLUE}Digite o IP do DNS secundário [1.1.1.1]:${NC}"
    read -p "> " DNS2
    [ -z "$DNS2" ] && DNS2="1.1.1.1"
    
    echo -e "${BLUE}Digite o domínio de pesquisa [${DOMAIN,,}]:${NC}"
    read -p "> " SEARCH_DOMAIN
    [ -z "$SEARCH_DOMAIN" ] && SEARCH_DOMAIN="${DOMAIN,,}"
    
    echo ""
    echo -e "${YELLOW}⚠️  Será aplicada a seguinte configuração:${NC}"
    echo -e "  DNS Primário: ${CYAN}${DNS1}${NC}"
    echo -e "  DNS Secundário: ${CYAN}${DNS2}${NC}"
    echo -e "  Domínio: ${CYAN}${SEARCH_DOMAIN}${NC}"
    echo ""
    
    read -p "Deseja aplicar esta configuração? (S/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        info "Configuração cancelada"
        return
    fi
    
    log "Configurando DNS..."
    
    chattr -i /etc/resolv.conf 2>/dev/null || true
    cat > /etc/resolv.conf << EOF
nameserver ${DNS1}
nameserver ${DNS2}
search ${SEARCH_DOMAIN}
domain ${SEARCH_DOMAIN}
EOF
    chattr +i /etc/resolv.conf 2>/dev/null || true
    
    # Atualizar netplan com os novos DNS
    detect_all
    update_netplan "${FIXED_IP}" "24" "${FIXED_GATEWAY}" "${DNS1}" "${DNS2}" "${SEARCH_DOMAIN}"
    
    success "DNS configurado com sucesso!"
}

show_network_status() {
    header "STATUS DA REDE"
    
    echo -e "${BLUE}=== Interfaces de Rede ===${NC}"
    ip -br addr show
    echo ""
    
    echo -e "${BLUE}=== Arquivos de Configuração ===${NC}"
    ls -la /etc/netplan/*.yaml 2>/dev/null || echo "  Nenhum arquivo .yaml encontrado"
    echo ""
    
    echo -e "${BLUE}=== Conteúdo do Arquivo Ativo ===${NC}"
    if [ -f "${NETPLAN_FILE}" ]; then
        cat "${NETPLAN_FILE}" 2>/dev/null
    else
        echo "  Arquivo não encontrado"
    fi
    echo ""
    
    echo -e "${BLUE}=== Rotas ===${NC}"
    ip route
    echo ""
    
    echo -e "${BLUE}=== DNS ===${NC}"
    cat /etc/resolv.conf 2>/dev/null || echo "  Arquivo /etc/resolv.conf não encontrado"
    echo ""
    
    read -p "Pressione ENTER para continuar..."
}

test_connectivity() {
    header "TESTANDO CONECTIVIDADE"
    
    echo -e "${BLUE}1. Testando gateway (${FIXED_GATEWAY}):${NC}"
    if ping -c 3 ${FIXED_GATEWAY} &> /dev/null; then
        success "Gateway acessível"
    else
        warning "Gateway não acessível"
    fi
    echo ""
    
    echo -e "${BLUE}2. Testando internet (8.8.8.8):${NC}"
    if ping -c 3 8.8.8.8 &> /dev/null; then
        success "Internet acessível"
    else
        warning "Internet não acessível"
    fi
    echo ""
    
    echo -e "${BLUE}3. Testando resolução DNS:${NC}"
    if nslookup google.com &> /dev/null; then
        success "Resolução DNS funcionando"
    else
        warning "Resolução DNS com problemas"
    fi
    echo ""
    
    echo -e "${BLUE}4. Testando domínio:${NC}"
    if host ${DOMAIN,,} &> /dev/null; then
        success "Domínio ${DOMAIN} resolvido"
    else
        info "Domínio ${DOMAIN} não encontrado na rede"
    fi
    echo ""
    
    read -p "Pressione ENTER para continuar..."
}

# ============================================
# INSTALAÇÃO SECUNDÁRIA (REFATORADA)
# ============================================

remove_dhcp() {
    header "REMOVENDO DHCP E CONFIGURANDO IP FIXO"
    
    stop_dhcp_services
    detect_netplan_file
    
    # Usar função unificada para criar netplan
    update_netplan "${FIXED_IP}" "24" "${FIXED_GATEWAY}" "${PRIMARY_DC_IP}" "8.8.8.8" "${DOMAIN,,}"
    
    # Aplicar configuração
    apply_netplan
}

configure_dns_secondary() {
    header "CONFIGURANDO DNS"
    
    log "Configurando /etc/resolv.conf..."
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf
    
    cat > /etc/resolv.conf << EOF
nameserver ${PRIMARY_DC_IP}
nameserver 8.8.8.8
search ${DOMAIN,,}
domain ${DOMAIN,,}
EOF
    chattr +i /etc/resolv.conf 2>/dev/null || true
    
    # Atualizar hosts
    cat > /etc/hosts << EOF
127.0.0.1 localhost
127.0.1.1 ${HOSTNAME}.${DOMAIN,,} ${HOSTNAME}
${FIXED_IP} ${HOSTNAME}.${DOMAIN,,} ${HOSTNAME}
${FIXED_IP} ${HOSTNAME}
${PRIMARY_DC_IP} ${PRIMARY_DC_HOSTNAME}.${DOMAIN,,} ${PRIMARY_DC_HOSTNAME}
EOF
    
    success "DNS e hosts configurados"
}

# ============================================
# MENU PRINCIPAL
# ============================================

show_menu() {
    print_banner
    
    echo -e "${WHITE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${WHITE}║                    SEJA BEM-VINDO!                          ║${NC}"
    echo -e "${WHITE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}📋 Este script irá instalar e configurar um Controlador de Domínio${NC}"
    echo -e "${CYAN}   Samba AD de forma completamente automatizada.${NC}"
    echo ""
    echo -e "${YELLOW}⚠️  ATENÇÃO:${NC}"
    echo -e "   - Execute como ${BOLD}root${NC}"
    echo -e "   - Configure a rede ANTES de instalar (Opção 1)"
    echo -e "   - O servidor será reiniciado ao final da instalação"
    echo ""
    
    get_os_info
    echo -e "${BLUE}📌 INFORMAÇÕES DO SISTEMA:${NC}"
    echo -e "   Sistema: ${CYAN}${OS_INFO}${NC}"
    echo -e "   Kernel: ${CYAN}${KERNEL_VERSION}${NC}"
    echo ""
    
    if [ -n "$FIXED_IP" ] && [ "$FIXED_IP" != "127.0.0.1" ]; then
        echo -e "${GREEN}✅ Rede configurada: ${FIXED_IP}${NC}"
        echo -e "   Interface: ${CYAN}${INTERFACE}${NC}"
        echo -e "   Arquivo: ${CYAN}${NETPLAN_FILE}${NC}"
    else
        echo -e "${RED}❌ Rede NÃO configurada${NC}"
        echo -e "   Use a Opção 1 para configurar"
    fi
    echo ""
    
    echo -e "${WHITE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${WHITE}║                    MENU PRINCIPAL                           ║${NC}"
    echo -e "${WHITE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${GREEN} 1)${NC} ${BOLD}CONFIGURAR REDE${NC}"
    echo -e "     ${CYAN}➜${NC} Configurar IP fixo, DNS e gateway"
    echo ""
    echo -e "${GREEN} 2)${NC} ${BOLD}INSTALAR CONTROLADOR PRIMÁRIO${NC}"
    echo -e "     ${CYAN}➜${NC} Primeiro DC do domínio"
    echo ""
    echo -e "${GREEN} 3)${NC} ${BOLD}INSTALAR CONTROLADOR SECUNDÁRIO${NC}"
    echo -e "     ${CYAN}➜${NC} DC adicional para redundância"
    echo ""
    echo -e "${GREEN} 4)${NC} ${BOLD}GERENCIAR REPLICAÇÃO AD${NC}"
    echo -e "     ${CYAN}➜${NC} Forçar sincronização entre DCs"
    echo ""
    echo -e "${RED} 5)${NC} ${BOLD}SAIR${NC}"
    echo ""
    echo -e "${WHITE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ============================================
# FUNÇÃO UNIFICADA PARA CONFIGURAÇÕES COMUNS
# ============================================

common_setup() {
    log "Executando configurações comuns..."
    
    # Configurar DNS do sistema
    if [ "$INSTALLATION_TYPE" == "secondary" ]; then
        configure_dns_secondary
    else
        fix_system_dns
    fi
    
    configure_locale
    configure_ntp
    install_packages
    configure_hostname
}

# ============================================
# FUNÇÃO DE FINALIZAÇÃO
# ============================================

finalize_installation() {
    clear
    header "✅ INSTALAÇÃO CONCLUÍDA!"
    
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}         CONTROLADOR DE DOMÍNIO INSTALADO COM SUCESSO!           ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}📌 ACESSO:${NC}"
    echo -e "  Domínio: ${BLUE}${DOMAIN}${NC}"
    echo -e "  Usuário: ${BLUE}${ADMIN_USER}@${DOMAIN}${NC}"
    echo -e "  Senha:   ${BLUE}${ADMIN_PASSWORD}${NC}"
    echo -e "  IP:      ${BLUE}${FIXED_IP}${NC}"
    echo ""
    echo -e "${YELLOW}📁 ARQUIVOS:${NC}"
    echo -e "  ${BLUE}/root/ad_info.txt${NC} - Informações completas"
    echo -e "  ${BLUE}${LOG_FILE}${NC} - Log da instalação"
    echo ""
    
    echo -e "${YELLOW}⚠️  Recomenda-se reiniciar o servidor.${NC}"
    read -p "Reiniciar agora? (s/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Ss]$ ]]; then
        log "Reiniciando..."
        sleep 5
        reboot
    fi
}

# ============================================
# INÍCIO DO SCRIPT - MAIN
# ============================================

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERRO] Este script deve ser executado como root (sudo)${NC}"
    exit 1
fi

# Auto detect inicial
auto_detect
show_menu
get_installation_type

# Executar instalação conforme tipo
if [ "$INSTALLATION_TYPE" == "primary" ]; then
    collect_configurations
    common_setup
    provision_domain
    configure_samba_primary
    configure_kerberos_primary
    test_primary_services
    final_tests_primary
    setup_auto_replication
    create_fix_dns_script
    save_info
elif [ "$INSTALLATION_TYPE" == "secondary" ]; then
    collect_configurations
    remove_dhcp
    common_setup
    configure_kerberos_secondary
    test_connection
    test_kerberos_secondary
    join_domain
    configure_samba_secondary
    verify_secondary
    setup_auto_replication
    create_fix_dns_script
    save_info
fi

finalize_installation
exit 0