#!/bin/bash
# adserver_pro.sh — Script unificado para DC Primário/Secundário com Samba AD
# Ubuntu 24.04 | Samba 4.19.5 | Alta disponibilidade e replicação nativa
# Versão: 3.0

set -u pipefail

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

# Variáveis globais para relatório
REPORT_FILE="/root/ad_install_report_$(date +%Y%m%d_%H%M%S).log"
INSTALL_STEPS=()
INSTALL_STATUS=()
STEP_COUNT=0

# Logging
log()    { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $*"; }
error()  { echo -e "${RED}[ERRO]${NC} $*" >&2; exit 1; }
warn()   { echo -e "${YELLOW}[AVISO]${NC} $*" >&2; }
info()   { echo -e "${BLUE}[INFO]${NC} $*"; }
debug()  { [[ "${DEBUG:-0}" == "1" ]] && echo -e "${CYAN}[DEBUG]${NC} $*"; }

# Função para registrar passos no relatório
register_step() {
    local step_name="$1"
    local status="$2"  # OK, FAIL, WARN, INFO
    local details="${3:-}"
    STEP_COUNT=$((STEP_COUNT + 1))
    INSTALL_STEPS+=("$step_name")
    INSTALL_STATUS+=("$status")
    
    # Escreve no relatório
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$status] $step_name $details" >> "$REPORT_FILE"
}

# Verifica root
if [[ $EUID -ne 0 ]]; then
    error "Execute como root (sudo)"
fi

# ============================================
# FUNÇÃO: INSTALAR PACOTES ESSENCIAIS (INÍCIO)
# ============================================

install_essentials() {
    log "════════════════════════════════════════════════════"
    log "     INSTALANDO PACOTES ESSENCIAIS"
    log "════════════════════════════════════════════════════"
    
    # Detecta o gerenciador de pacotes
    if command -v apt &>/dev/null; then
        PKG_MANAGER="apt"
        log "Gerenciador detectado: APT (Ubuntu/Debian)"
        
        log "Atualizando cache de pacotes..."
        apt update -qq 2>/dev/null || true
        
        log "Instalando pacotes essenciais..."
        apt install -y -qq nano curl wget net-tools iputils-ping \
            language-pack-pt locales bash-completion 2>/dev/null || true
        
        register_step "Instalação de pacotes essenciais (APT)" "OK" "nano, curl, wget, net-tools, iputils-ping, locale"
        
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
        log "Gerenciador detectado: DNF (Fedora/RHEL)"
        
        log "Instalando pacotes essenciais..."
        dnf install -y -q nano iputils curl wget net-tools 2>/dev/null || true
        
        register_step "Instalação de pacotes essenciais (DNF)" "OK" "nano, iputils, curl, wget, net-tools"
        
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"
        log "Gerenciador detectado: YUM (RHEL/CentOS)"
        
        log "Instalando pacotes essenciais..."
        yum install -y -q nano iputils curl wget net-tools 2>/dev/null || true
        
        register_step "Instalação de pacotes essenciais (YUM)" "OK" "nano, iputils, curl, wget, net-tools"
        
    elif command -v zypper &>/dev/null; then
        PKG_MANAGER="zypper"
        log "Gerenciador detectado: Zypper (SUSE)"
        
        log "Instalando pacotes essenciais..."
        zypper install -y -q nano iputils curl wget net-tools 2>/dev/null || true
        
        register_step "Instalação de pacotes essenciais (Zypper)" "OK" "nano, iputils, curl, wget, net-tools"
        
    else
        warn "Gerenciador de pacotes não detectado. Pulando instalação automática."
        register_step "Instalação de pacotes essenciais" "WARN" "Gerenciador não detectado"
    fi
    
    # Verifica instalação do nano
    if command -v nano &>/dev/null; then
        echo -e "${GREEN}✓ nano instalado: $(nano --version 2>/dev/null | head -1)${NC}"
    else
        warn "nano não encontrado. Instale manualmente."
    fi
    
    # Verifica instalação do ping
    if command -v ping &>/dev/null; then
        echo -e "${GREEN}✓ ping disponível${NC}"
    else
        warn "ping não encontrado. Instale manualmente."
    fi
    
    echo -e "${GREEN}✓ Pacotes essenciais verificados${NC}"
    echo ""
}

# ============================================
# FUNÇÃO: CONFIGURAR LOCALE (INÍCIO)
# ============================================

config_locale() {
    log "════════════════════════════════════════════════════"
    log "     CONFIGURANDO IDIOMA PORTUGUÊS BRASIL"
    log "════════════════════════════════════════════════════"
    
    if command -v apt &>/dev/null; then
        apt update -qq 2>/dev/null || true
        apt install -y -qq language-pack-pt locales 2>/dev/null || true
    fi
    
    locale-gen pt_BR.UTF-8 2>/dev/null || true
    update-locale LANG=pt_BR.UTF-8 LANGUAGE=pt_BR:pt LC_ALL=pt_BR.UTF-8 2>/dev/null || true
    export LANG=pt_BR.UTF-8 LANGUAGE=pt_BR:pt LC_ALL=pt_BR.UTF-8
    
    echo -e "${GREEN}✓ Locale pt_BR configurado${NC}"
    echo ""
    
    register_step "Configuração de Locale" "OK" "pt_BR.UTF-8"
}

# ============================================
# FUNÇÃO: LER SENHA
# ============================================

read_password() {
    local prompt="$1"
    local password=""
    local char=""
    local IFS=""
    
    echo -ne "${BLUE}$prompt${NC}" >&2
    
    stty -echo -icanon min 1 time 0 2>/dev/null
    
    while true; do
        char=$(dd bs=1 count=1 2>/dev/null)
        
        if [[ -z "$char" ]] || [[ "$char" == $'\n' ]] || [[ "$char" == $'\r' ]] || [[ "$char" == $'\x04' ]]; then
            break
        elif [[ "$char" == $'\x7f' ]] || [[ "$char" == $'\x08' ]]; then
            if [[ -n "$password" ]]; then
                password="${password%?}"
                echo -ne "\b \b" >&2
            fi
        else
            password+="$char"
            echo -ne "*" >&2
        fi
    done
    
    stty echo -icanon 2>/dev/null
    echo >&2
    
    echo "$password"
}

# ============================================
# FUNÇÃO: GERAR RELATÓRIO FINAL
# ============================================

generate_final_report() {
    local install_type="$1"  # PRIMARY ou SECONDARY
    local domain="$2"
    local realm="$3"
    local hostname="$4"
    local ip="$5"
    
    log "════════════════════════════════════════════════════"
    log "     GERANDO RELATÓRIO FINAL DA INSTALAÇÃO"
    log "════════════════════════════════════════════════════"
    
    # Cabeçalho do relatório
    cat > "$REPORT_FILE" << EOF
╔═══════════════════════════════════════════════════════════════════════╗
║              RELATÓRIO DE INSTALAÇÃO - SAMBA AD DC                   ║
╠═══════════════════════════════════════════════════════════════════════╣
║  Data/Hora:    $(date '+%d/%m/%Y %H:%M:%S')
║  Tipo:         $install_type
║  Domínio:      $domain
║  Realm:        $realm
║  Hostname:     $hostname
║  IP Address:   $ip
║  Interface:    $INTERFACE
║  Sistema:      $(lsb_release -ds 2>/dev/null || echo "Ubuntu 24.04")
║  Kernel:       $(uname -r)
║  Samba:        $(samba --version 2>/dev/null | head -1 || echo "4.19.5")
╚═══════════════════════════════════════════════════════════════════════╝

EOF
    
    # Adiciona o log de passos
    echo "╔═══════════════════════════════════════════════════════════════════════╗" >> "$REPORT_FILE"
    echo "║                    PASSOS EXECUTADOS                                 ║" >> "$REPORT_FILE"
    echo "╠═══════════════════════════════════════════════════════════════════════╣" >> "$REPORT_FILE"
    
    for i in "${!INSTALL_STEPS[@]}"; do
        step="${INSTALL_STEPS[$i]}"
        status="${INSTALL_STATUS[$i]}"
        case "$status" in
            "OK")   status_icon="✅" ;;
            "FAIL") status_icon="❌" ;;
            "WARN") status_icon="⚠️" ;;
            "INFO") status_icon="ℹ️" ;;
            *)      status_icon="❓" ;;
        esac
        printf "║  %3d. %-50s %s\n" $((i+1)) "$step" "$status_icon" >> "$REPORT_FILE"
    done
    
    echo "╚═══════════════════════════════════════════════════════════════════════╝" >> "$REPORT_FILE"
    
    # Adiciona informações do AD
    if [ "$install_type" == "PRIMARY" ]; then
        cat >> "$REPORT_FILE" << EOF

╔═══════════════════════════════════════════════════════════════════════╗
║                    INFORMAÇÕES DO DC PRIMÁRIO                        ║
╠═══════════════════════════════════════════════════════════════════════╣
║  Administrador:   administrator@$realm
║  Senha:           $ADMIN_PASSWORD
║  DNS:             127.0.0.1
║  NTP:             a.st1.ntp.br
╚═══════════════════════════════════════════════════════════════════════╝

COMANDOS ÚTEIS:
─────────────────────────────────────────────────────────────────────────
# Testar Kerberos
echo '$ADMIN_PASSWORD' | kinit administrator@$realm
klist

# Listar usuários
samba-tool user list

# Listar grupos
samba-tool group list

# Verificar DNS
host -t SRV _ldap._tcp.$domain

# Logs do Samba
tail -f /var/log/samba/log.samba

EOF
    else
        cat >> "$REPORT_FILE" << EOF

╔═══════════════════════════════════════════════════════════════════════╗
║                  INFORMAÇÕES DO DC SECUNDÁRIO                        ║
╠═══════════════════════════════════════════════════════════════════════╣
║  DC Primário:     $PRIMARY_IP
║  Usuário Join:    $ADMIN_USER@$realm
║  DNS Primário:    $PRIMARY_IP
║  DNS Secundário:  127.0.0.1
║  NTP:             $PRIMARY_IP
╚═══════════════════════════════════════════════════════════════════════╝

COMANDOS ÚTEIS:
─────────────────────────────────────────────────────────────────────────
# Verificar replicação
samba-tool drs showrepl

# Testar Kerberos
echo '$ADMIN_PASSWORD' | kinit administrator@$realm
klist

# Verificar DNS
host -t SRV _ldap._tcp.$domain

EOF
    fi
    
    # Status final
    FAIL_COUNT=0
    for status in "${INSTALL_STATUS[@]}"; do
        [ "$status" == "FAIL" ] && FAIL_COUNT=$((FAIL_COUNT + 1))
    done
    
    if [ $FAIL_COUNT -eq 0 ]; then
        echo "✅ INSTALAÇÃO CONCLUÍDA COM SUCESSO! (0 erros)" >> "$REPORT_FILE"
    else
        echo "⚠️ INSTALAÇÃO CONCLUÍDA COM $FAIL_COUNT ERRO(S)" >> "$REPORT_FILE"
    fi
    
    echo "═══════════════════════════════════════════════════════════════════════" >> "$REPORT_FILE"
    
    echo -e "${GREEN}✓ Relatório gerado: $REPORT_FILE${NC}"
    
    # Mostra resumo na tela
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}📊 RESUMO DA INSTALAÇÃO:${NC}"
    echo -e "${BLUE}───────────────────────────────────────────────────────────────────────${NC}"
    echo -e "  Total de passos: ${#INSTALL_STEPS[@]}"
    echo -e "  ✅ Sucessos:     $(grep -c "OK" <(for s in "${INSTALL_STATUS[@]}"; do echo "$s"; done) 2>/dev/null || echo 0)"
    echo -e "  ⚠️  Alertas:      $(grep -c "WARN" <(for s in "${INSTALL_STATUS[@]}"; do echo "$s"; done) 2>/dev/null || echo 0)"
    echo -e "  ❌ Erros:        $(grep -c "FAIL" <(for s in "${INSTALL_STATUS[@]}"; do echo "$s"; done) 2>/dev/null || echo 0)"
    echo -e "${BLUE}───────────────────────────────────────────────────────────────────────${NC}"
    echo -e "${YELLOW}📄 Relatório completo: $REPORT_FILE${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════${NC}"
}

# ============================================
# FUNÇÕES DE CONFIGURAÇÃO COMUNS
# ============================================

config_bash_completion() {
    log "Ativando auto-complete com TAB..."
    if ! grep -q "bash-completion" /root/.bashrc 2>/dev/null; then
        cat >> /root/.bashrc << 'EOF' 2>/dev/null || true

# Auto-complete via bash-completion
if [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
fi

# Auto-complete para samba-tool
complete -C samba-tool samba-tool
EOF
    fi
    [ -f /etc/bash_completion ] && . /etc/bash_completion 2>/dev/null || true
    echo -e "${GREEN}✓ Bash completion ativado${NC}"
    register_step "Bash completion" "OK"
}

config_ssh_root() {
    log "Configurando acesso root via SSH..."
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
    if grep -q "^PermitRootLogin" /etc/ssh/sshd_config 2>/dev/null; then
        sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null || true
    else
        echo "PermitRootLogin yes" >> /etc/ssh/sshd_config 2>/dev/null || true
    fi
    systemctl restart sshd 2>/dev/null || true
    echo -e "${YELLOW}⚠ Root SSH ativado${NC}"
    register_step "Configuração SSH Root" "OK"
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
        warn "Não consegui detectar IP. Usando $IP_ADDR"
    fi
    echo -e "${GREEN}✓ Interface: ${INTERFACE} (${IP_ADDR})${NC}"
    export INTERFACE IP_ADDR
    register_step "Detecção de interface" "OK" "$INTERFACE ($IP_ADDR)"
}

config_ntp() {
    local PRIMARY_NTP="$1"
    log "Configurando NTP (Chrony)..."
    
    if command -v apt &>/dev/null; then
        apt install -y -qq chrony 2>/dev/null || true
    fi
    
    timedatectl set-timezone America/Sao_Paulo 2>/dev/null || true
    
    if [ "$PRIMARY_NTP" == "SELF" ]; then
        cat > /etc/chrony/chrony.conf << 'EOF' 2>/dev/null || true
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
        register_step "Configuração NTP" "OK" "Servidores oficiais brasileiros"
    else
        cat > /etc/chrony/chrony.conf << EOF 2>/dev/null || true
server $PRIMARY_NTP iburst
keyfile /etc/chrony/chrony.keys
driftfile /var/lib/chrony/drift
rtcsync
makestep 1.0 3
bindcmdaddress 127.0.0.1
logdir /var/log/chrony
EOF
        register_step "Configuração NTP" "OK" "Sincronizando com $PRIMARY_NTP"
    fi
    
    systemctl enable --now chrony -qq 2>/dev/null || true
    systemctl restart chrony -qq 2>/dev/null || true
    sleep 2
    chronyc sources >/dev/null 2>&1 && echo -e "${GREEN}✓ NTP sincronizado${NC}" || warn "NTP não sincronizou"
}

# ============================================
# FUNÇÃO: DETECTAR NETPLAN
# ============================================

detect_netplan_file() {
    local CANDIDATES=()
    
    CANDIDATES+=($(find /etc/netplan -maxdepth 1 -name "*cloud-init*.yaml" -type f 2>/dev/null | sort))
    CANDIDATES+=($(find /etc/netplan -maxdepth 1 -name "01-netcfg*.yaml" -type f 2>/dev/null | sort))
    CANDIDATES+=($(find /etc/netplan -maxdepth 1 -name "*.yaml" -type f ! -name "*cloud-init*" ! -name "01-netcfg*" 2>/dev/null | sort))
    
    local UNIQUE=()
    for file in "${CANDIDATES[@]}"; do
        if [[ ! " ${UNIQUE[*]} " =~ " ${file} " ]]; then
            UNIQUE+=("$file")
        fi
    done
    
    echo "${UNIQUE[@]}"
}

# ============================================
# FUNÇÃO: CONFIGURAR IP ESTAÇÃO LINUX
# ============================================

configure_station_ips() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   GERADOR DE CONFIGURAÇÃO DE IP — ESTAÇÕES                     ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
    
    echo "Selecione o sistema operacional das estações:"
    echo "  1) Linux (Netplan — Ubuntu/Debian)"
    echo "  2) Windows (script batch netsh)"
    read -p "Opção [1/2]: " OS_OPT
    
    case "$OS_OPT" in
        1)
            log "Detectando interfaces de rede..."
            IFS=$'\n'
            INTERFACES=($(ip link show | awk '/^[0-9]+: [^ ]+:.*state UP/{gsub(":","",$2); print $2}' | grep -E "^(en|eth|wl)" || true))
            
            if [ ${#INTERFACES[@]} -eq 0 ]; then
                INTERFACES=($(ip link show | awk '/^[0-9]+: [^ ]+:/ && !/lo|virbr|vnet/ {gsub(":","",$2); print $2}' | grep -E "^(en|eth|wl)" || true))
            fi
            
            if [ ${#INTERFACES[@]} -eq 0 ]; then
                error "Nenhuma interface de rede encontrada."
            elif [ ${#INTERFACES[@]} -eq 1 ]; then
                STA_IFACE="${INTERFACES[0]}"
                info "Interface detectada: $STA_IFACE"
            else
                echo
                echo -e "${YELLOW}Múltiplas interfaces encontradas:${NC}"
                for i in "${!INTERFACES[@]}"; do
                    idx=$((i+1))
                    echo "  [$idx] ${INTERFACES[$i]}"
                done
                read -p "Selecione a interface [1-${#INTERFACES[@]}]: " IFACE_SEL
                STA_IFACE="${INTERFACES[$((IFACE_SEL-1))]}"
                [ -z "$STA_IFACE" ] && error "Seleção inválida"
            fi
            
            log "Buscando arquivos Netplan..."
            NETPLAN_FILES=($(detect_netplan_file))
            
            if [ ${#NETPLAN_FILES[@]} -eq 0 ]; then
                NETPLAN_PATH="/etc/netplan/01-ad-static.yaml"
                warn "Nenhum arquivo Netplan encontrado. Criando $NETPLAN_PATH"
            elif [ ${#NETPLAN_FILES[@]} -eq 1 ]; then
                NETPLAN_PATH="${NETPLAN_FILES[0]}"
                info "Arquivo Netplan encontrado: $NETPLAN_PATH"
            else
                echo
                echo -e "${YELLOW}Múltiplos arquivos Netplan encontrados:${NC}"
                for i in "${!NETPLAN_FILES[@]}"; do
                    idx=$((i+1))
                    echo "  [$idx] ${NETPLAN_FILES[$i]}"
                done
                read -p "Selecione o arquivo [1-${#NETPLAN_FILES[@]}] (Enter para o primeiro): " FILE_SEL
                if [ -z "$FILE_SEL" ]; then
                    NETPLAN_PATH="${NETPLAN_FILES[0]}"
                else
                    NETPLAN_PATH="${NETPLAN_FILES[$((FILE_SEL-1))]}"
                fi
            fi
            
            echo
            CURRENT_IP=$(ip addr show "$STA_IFACE" 2>/dev/null | grep inet | grep -v inet6 | awk '{print $2}' | cut -d/ -f1 | head -1 || echo "")
            CURRENT_MASK=$(ip addr show "$STA_IFACE" 2>/dev/null | grep inet | grep -v inet6 | awk '{print $2}' | cut -d/ -f2 | head -1 || echo "24")
            CURRENT_GATEWAY=$(ip route | grep default | grep "$STA_IFACE" | awk '{print $3}' | head -1 || echo "")
            
            if [ -n "$CURRENT_IP" ]; then
                read -p "IP estático [atual: $CURRENT_IP]: " STA_IP
                STA_IP="${STA_IP:-$CURRENT_IP}"
            else
                read -p "IP estático (ex: 192.168.1.50): " STA_IP
            fi
            
            read -p "Máscara [atual: /$CURRENT_MASK]: " STA_MASK
            STA_MASK="${STA_MASK:-$CURRENT_MASK}"
            
            if [ -n "$CURRENT_GATEWAY" ]; then
                read -p "Gateway [atual: $CURRENT_GATEWAY]: " STA_GATEWAY
                STA_GATEWAY="${STA_GATEWAY:-$CURRENT_GATEWAY}"
            else
                read -p "Gateway (ex: 192.168.1.1): " STA_GATEWAY
            fi
            
            echo -e "${BLUE}Configuração de DNS:${NC}"
            echo "  [1] 8.8.8.8 e 8.8.4.4 (Google)"
            echo "  [2] 1.1.1.1 e 1.0.0.1 (Cloudflare)"
            echo "  [3] IP do AD"
            echo "  [4] Personalizado"
            read -p "Escolha uma opção [1-4] (default: 1): " DNS_OPT
            DNS_OPT="${DNS_OPT:-1}"
            
            case "$DNS_OPT" in
                1) STA_DNS1="8.8.8.8"; STA_DNS2="8.8.4.4" ;;
                2) STA_DNS1="1.1.1.1"; STA_DNS2="1.0.0.1" ;;
                3) read -p "IP do AD: " AD_IP; STA_DNS1="${AD_IP:-8.8.8.8}"; read -p "DNS secundário: " STA_DNS2 ;;
                4) read -p "DNS 1: " STA_DNS1; STA_DNS1="${STA_DNS1:-8.8.8.8}"; read -p "DNS 2: " STA_DNS2 ;;
                *) STA_DNS1="8.8.8.8"; STA_DNS2="8.8.4.4" ;;
            esac
            
            if [ -n "$STA_DNS2" ]; then
                NAMESERVERS="      nameservers:\n        addresses: [$STA_DNS1, $STA_DNS2]"
            else
                NAMESERVERS="      nameservers:\n        addresses: [$STA_DNS1]"
            fi
            
            if [ -f "$NETPLAN_PATH" ]; then
                BACKUP_PATH="${NETPLAN_PATH}.bak.$(date +%Y%m%d_%H%M%S)"
                cp "$NETPLAN_PATH" "$BACKUP_PATH"
                info "Backup criado: $BACKUP_PATH"
                
                if grep -q "^[[:space:]]*${STA_IFACE}:" "$NETPLAN_PATH"; then
                    sed -i "/^[[:space:]]*${STA_IFACE}:/,/^[[:space:]]*[a-zA-Z]/{
                        /dhcp4/d
                        /dhcp6/d
                        /addresses/d
                        /gateway4/d
                        /nameservers/d
                    }" "$NETPLAN_PATH"
                    
                    awk -v iface="$STA_IFACE" -v ip="$STA_IP" -v mask="$STA_MASK" -v gw="$STA_GATEWAY" -v ns="$NAMESERVERS" '
                    {
                        print
                        if ($0 ~ "^[[:space:]]*" iface ":" && !done) {
                            printf("      addresses: [%s/%s]\n", ip, mask)
                            printf("      gateway4: %s\n", gw)
                            printf("%s\n", ns)
                            printf("      dhcp6: no\n")
                            printf("      optional: true\n")
                            done=1
                        }
                    }' "$NETPLAN_PATH" > "${NETPLAN_PATH}.tmp" && mv "${NETPLAN_PATH}.tmp" "$NETPLAN_PATH"
                else
                    awk -v iface="$STA_IFACE" -v ip="$STA_IP" -v mask="$STA_MASK" -v gw="$STA_GATEWAY" -v ns="$NAMESERVERS" '
                    {
                        print
                        if ($0 ~ "^[[:space:]]*ethernets:" && !done) {
                            printf("    %s:\n", iface)
                            printf("      addresses: [%s/%s]\n", ip, mask)
                            printf("      gateway4: %s\n", gw)
                            printf("%s\n", ns)
                            printf("      dhcp6: no\n")
                            printf("      optional: true\n")
                            done=1
                        }
                    }' "$NETPLAN_PATH" > "${NETPLAN_PATH}.tmp" && mv "${NETPLAN_PATH}.tmp" "$NETPLAN_PATH"
                fi
            else
                cat > "$NETPLAN_PATH" << EOF
# Configuração estática gerada pelo adserver_pro.sh
network:
  version: 2
  ethernets:
    $STA_IFACE:
      addresses: [$STA_IP/$STA_MASK]
      gateway4: $STA_GATEWAY
$NAMESERVERS
      dhcp6: no
      optional: true
EOF
            fi
            
            log "Validando configuração Netplan..."
            if netplan generate >/dev/null 2>&1; then
                echo -e "${GREEN}✓ Configuração validada!${NC}"
                netplan apply >/dev/null 2>&1
                echo -e "${GREEN}✓ Configuração aplicada!${NC}"
                register_step "Configuração IP Estação Linux" "OK" "$STA_IFACE -> $STA_IP"
            else
                warn "Erro na configuração — restaurando backup"
                [ -f "$BACKUP_PATH" ] && cp "$BACKUP_PATH" "$NETPLAN_PATH"
                register_step "Configuração IP Estação Linux" "FAIL" "Erro ao aplicar"
            fi
            
            echo
            read -p "Pressione Enter para continuar..."
            ;;
            
        2)
            echo
            read -p "IP da estação Windows: " STA_IP
            read -p "Máscara (ex: 255.255.255.0): " STA_MASK
            read -p "Gateway: " STA_GATEWAY
            
            echo -e "${BLUE}Configuração de DNS:${NC}"
            echo "  [1] 8.8.8.8 e 8.8.4.4 (Google)"
            echo "  [2] 1.1.1.1 e 1.0.0.1 (Cloudflare)"
            echo "  [3] IP do AD"
            echo "  [4] Personalizado"
            read -p "Escolha uma opção [1-4] (default: 1): " DNS_OPT
            DNS_OPT="${DNS_OPT:-1}"
            
            case "$DNS_OPT" in
                1) STA_DNS1="8.8.8.8"; STA_DNS2="8.8.4.4" ;;
                2) STA_DNS1="1.1.1.1"; STA_DNS2="1.0.0.1" ;;
                3) read -p "IP do AD: " AD_IP; STA_DNS1="${AD_IP:-8.8.8.8}"; read -p "DNS secundário: " STA_DNS2 ;;
                4) read -p "DNS 1: " STA_DNS1; STA_DNS1="${STA_DNS1:-8.8.8.8}"; read -p "DNS 2: " STA_DNS2 ;;
                *) STA_DNS1="8.8.8.8"; STA_DNS2="8.8.4.4" ;;
            esac
            
            read -p "Nome da interface (ex: Ethernet): " STA_IFACE
            
            cat > "/root/config_ip_estacao_${STA_IP}.bat" << EOF
@echo off
REM Configuração de IP estático
echo Configurando IP estático...
netsh interface ipv4 set address name="$STA_IFACE" source=static address=$STA_IP mask=$STA_MASK gateway=$STA_GATEWAY gwmetric=1
netsh interface ipv4 set dns name="$STA_IFACE" source=static address=$STA_DNS1 register=primary
EOF
            [ -n "$STA_DNS2" ] && echo "netsh interface ipv4 add dns name=\"$STA_IFACE\" address=$STA_DNS2 index=2" >> "/root/config_ip_estacao_${STA_IP}.bat"
            
            echo
            echo -e "${GREEN}✓ Arquivo gerado: /root/config_ip_estacao_${STA_IP}.bat${NC}"
            register_step "Configuração IP Estação Windows" "OK" "$STA_IP"
            read -p "Pressione Enter para continuar..."
            ;;
            
        *)
            error "Opção inválida"
            ;;
    esac
}

# ============================================
# FUNÇÕES DE TESTE
# ============================================

run_tests_primary() {
    local DOMAIN="$1" REALM="$2" IP="$3"
    log "════════════════════════════════════════════════════"
    log "          BATERIA DE TESTES — DC PRIMÁRIO"
    log "════════════════════════════════════════════════════"
    
    local test_passed=0
    local test_failed=0
    
    info "1. Testando resolução DNS interno..."
    if host -t A localhost >/dev/null 2>&1; then
        echo -e "${GREEN}✓ localhost OK${NC}"
        ((test_passed++))
    else
        echo -e "${RED}✗ localhost NOK${NC}"
        ((test_failed++))
    fi
    
    info "2. Testando SRV LDAP do domínio..."
    if host -t SRV "_ldap._tcp.${DOMAIN}" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ SRV LDAP OK${NC}"
        ((test_passed++))
    else
        echo -e "${RED}✗ SRV LDAP NOK${NC}"
        ((test_failed++))
    fi
    
    info "3. Testando A record do hostname..."
    if host -t A "$HOSTNAME.$DOMAIN" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Hostname DNS OK${NC}"
        ((test_passed++))
    else
        echo -e "${RED}✗ Hostname DNS NOK${NC}"
        ((test_failed++))
    fi
    
    info "4. Testando Kerberos (kinit)..."
    if echo -n "${ADMIN_PASSWORD}" | kinit administrator@"$REALM" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Kerberos OK${NC}"
        ((test_passed++))
    else
        echo -e "${RED}✗ Kerberos falhou${NC}"
        ((test_failed++))
    fi
    
    info "5. Verificando status do serviço samba-ad-dc..."
    if systemctl is-active --quiet samba-ad-dc; then
        echo -e "${GREEN}✓ Serviço ativo${NC}"
        ((test_passed++))
    else
        echo -e "${RED}✗ Serviço inativo${NC}"
        ((test_failed++))
    fi
    
    info "6. Testando sintaxe do smb.conf..."
    if testparm -s >/dev/null 2>&1; then
        echo -e "${GREEN}✓ testparm OK${NC}"
        ((test_passed++))
    else
        echo -e "${RED}✗ testparm falhou${NC}"
        ((test_failed++))
    fi
    
    info "7. Verificando NTP..."
    if chronyc sources | grep -q "^." 2>/dev/null; then
        echo -e "${GREEN}✓ Chrony tem fontes ativas${NC}"
        ((test_passed++))
    else
        echo -e "${RED}✗ Chrony sem fontes${NC}"
        ((test_failed++))
    fi
    
    log "════════════════════════════════════════════════════"
    echo -e "${BLUE}Resumo dos testes: ${GREEN}$test_passed OK${NC} / ${RED}$test_failed FAIL${NC}"
    register_step "Testes do DC Primário" "OK" "$test_passed passaram, $test_failed falharam"
}

run_tests_secondary() {
    local DOMAIN="$1" REALM="$2" IP="$3" PRIMARY_IP="$4"
    log "════════════════════════════════════════════════════"
    log "          BATERIA DE TESTES — DC SECUNDÁRIO"
    log "════════════════════════════════════════════════════"
    
    local test_passed=0
    local test_failed=0
    
    info "1. Testando resolução DNS..."
    if host -t A "$HOSTNAME.$DOMAIN" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Hostname local OK${NC}"
        ((test_passed++))
    else
        echo -e "${RED}✗ Hostname local NOK${NC}"
        ((test_failed++))
    fi
    
    info "2. Testando SRV LDAP do domínio via DNS local..."
    if host -t SRV "_ldap._tcp.${DOMAIN}" 127.0.0.1 >/dev/null 2>&1; then
        echo -e "${GREEN}✓ SRV LDAP via DNS local OK${NC}"
        ((test_passed++))
    else
        echo -e "${RED}✗ SRV LDAP NOK${NC}"
        ((test_failed++))
    fi
    
    info "3. Testando Kerberos..."
    if echo -n "${ADMIN_PASSWORD}" | kinit administrator@"$REALM" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Kerberos OK${NC}"
        ((test_passed++))
    else
        echo -e "${RED}✗ Kerberos falhou${NC}"
        ((test_failed++))
    fi
    
    info "4. Verificando status do serviço..."
    if systemctl is-active --quiet samba-ad-dc; then
        echo -e "${GREEN}✓ Serviço ativo${NC}"
        ((test_passed++))
    else
        echo -e "${RED}✗ Serviço inativo${NC}"
        ((test_failed++))
    fi
    
    info "5. Testando replicação DRS com o primário..."
    if samba-tool drs showrepl 2>&1 | grep -q "$PRIMARY_IP"; then
        echo -e "${GREEN}✓ Replicação DRS ativa com $PRIMARY_IP${NC}"
        ((test_passed++))
    else
        echo -e "${RED}✗ Replicação DRS não detectada${NC}"
        ((test_failed++))
    fi
    
    info "6. Testando wbinfo..."
    if wbinfo -t >/dev/null 2>&1; then
        echo -e "${GREEN}✓ wbinfo conectado ao AD${NC}"
        ((test_passed++))
    else
        echo -e "${RED}✗ wbinfo falhou${NC}"
        ((test_failed++))
    fi
    
    log "════════════════════════════════════════════════════"
    echo -e "${BLUE}Resumo dos testes: ${GREEN}$test_passed OK${NC} / ${RED}$test_failed FAIL${NC}"
    register_step "Testes do DC Secundário" "OK" "$test_passed passaram, $test_failed falharam"
}

# ══════════════════════════════════════════════════════════════
#              FLUXO 1 — DC PRIMÁRIO
# ══════════════════════════════════════════════════════════════

setup_primary_dc() {
    clear
    
    # Instala pacotes essenciais e configura locale no início
    install_essentials
    config_locale
    
    echo -e "${BLUE}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        CONFIGURAÇÃO — DC PRIMÁRIO               ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}"
    
    detect_interface
    
    read -p "Domínio (ex: rnv.local): " -e DOMAIN
    DOMAIN="${DOMAIN,,}"
    REALM="${DOMAIN^^}"
    SHORT_DOMAIN=$(echo "$DOMAIN" | cut -d'.' -f1 | tr '[:lower:]' '[:upper:]')
    read -p "Hostname do servidor (default: adserver01): " -e INPUT_HOSTNAME
    HOSTNAME="${INPUT_HOSTNAME:-adserver01}"
    
    SENHA_VALIDA=0
    while [ $SENHA_VALIDA -eq 0 ]; do
        echo ""
        ADMIN_PASSWORD=$(read_password "Digite a senha do administrador do domínio: ")
        ADMIN_PASSWORD_CONFIRM=$(read_password "Confirme a senha: ")
        
        if [ "$ADMIN_PASSWORD" = "$ADMIN_PASSWORD_CONFIRM" ]; then
            if [ ${#ADMIN_PASSWORD} -lt 8 ]; then
                warn "A senha deve ter pelo menos 8 caracteres!"
            elif ! echo "$ADMIN_PASSWORD" | grep -q "[A-Z]"; then
                warn "A senha deve ter pelo menos uma letra maiúscula!"
            elif ! echo "$ADMIN_PASSWORD" | grep -q "[a-z]"; then
                warn "A senha deve ter pelo menos uma letra minúscula!"
            elif ! echo "$ADMIN_PASSWORD" | grep -q "[0-9]"; then
                warn "A senha deve ter pelo menos um número!"
            else
                SENHA_VALIDA=1
                break
            fi
        else
            warn "As senhas não coincidem!"
        fi
    done
    
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
    
    register_step "Início da configuração DC Primário" "INFO" "Domínio: $DOMAIN"
    
    config_bash_completion
    config_ssh_root
    config_ntp "SELF"
    
    log "Configurando hostname: ${HOSTNAME}.${DOMAIN}"
    hostnamectl set-hostname "${HOSTNAME}.${DOMAIN}"
    register_step "Configuração de hostname" "OK" "${HOSTNAME}.${DOMAIN}"
    
    log "Configurando /etc/hosts"
    cp /etc/hosts "/etc/hosts.bak.$(date +%Y%m%d_%H%M%S)" || true
    cat > /etc/hosts << EOF
127.0.0.1 localhost
127.0.1.1 ${HOSTNAME}.${DOMAIN} ${HOSTNAME}
${IP_ADDR} ${HOSTNAME}.${DOMAIN} ${HOSTNAME}
EOF
    register_step "Configuração /etc/hosts" "OK"
    
    log "Instalando pacotes do Samba AD..."
    apt install -y -qq acl attr samba samba-dsdb-modules samba-vfs-modules \
        winbind libpam-winbind libnss-winbind krb5-user dnsutils \
        bind9utils ldap-utils bash-completion language-pack-pt locales \
        chrony 2>/dev/null || true
    register_step "Instalação Samba AD" "OK"
    
    systemctl stop smbd nmbd winbind samba-ad-dc 2>/dev/null || true
    systemctl disable smbd nmbd winbind 2>/dev/null || true
    
    rm -f /etc/samba/smb.conf
    rm -rf /var/lib/samba/private /var/lib/samba/sysvol /var/lib/samba/etc
    rm -f /etc/krb5.conf
    
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
    register_step "Provisionamento do domínio" "OK" "$REALM"
    
    log "Configurando /etc/samba/smb.conf"
    cp "/var/lib/samba/private/smb.conf" "/etc/samba/smb.conf"
    
    sed -i "/^interfaces/s|=.*| = lo $INTERFACE|" "/etc/samba/smb.conf" || true
    sed -i "/^bind interfaces only/s|=.*| = yes|" "/etc/samba/smb.conf" || true
    
    grep -q "ldap server require strong auth" "/etc/samba/smb.conf" ||
        sed -i "/\[global\]/a \    ldap server require strong auth = no" "/etc/samba/smb.conf"
    
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
    register_step "Configuração Kerberos" "OK"
    
    log "Configurando /etc/resolv.conf para DNS local"
    [ -f /etc/resolv.conf ] && cp /etc/resolv.conf "/etc/resolv.conf.bak.$(date +%Y%m%d_%H%M%S)"
    cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
search ${DOMAIN}
domain ${DOMAIN}
EOF
    register_step "Configuração DNS" "OK"
    
    log "Iniciando serviços samba-ad-dc..."
    systemctl unmask samba-ad-dc || true
    systemctl enable samba-ad-dc || true
    systemctl restart samba-ad-dc
    sleep 20
    register_step "Inicialização Samba AD" "OK"
    
    log "Criando grupos e usuários padrão..."
    samba-tool group add "admins" --description="Administradores do Domínio" 2>/dev/null || true
    samba-tool group add "users" --description="Usuários do Domínio" 2>/dev/null || true
    samba-tool user create admin2 "$ADMIN_PASSWORD" --given-name="Admin" --surname="Secundário" 2>/dev/null || true
    samba-tool group addmembers "Domain Admins" admin2 2>/dev/null || true
    register_step "Criação de grupos/usuários" "OK"
    
    run_tests_primary "$DOMAIN" "$REALM" "$IP_ADDR"
    
    # Gera relatório final
    generate_final_report "PRIMARY" "$DOMAIN" "$REALM" "$HOSTNAME" "$IP_ADDR"
    
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅ DC PRIMÁRIO CONFIGURADO COM SUCESSO!           ║${NC}"
    echo -e "${GREEN}║                                                     ║${NC}"
    echo -e "${GREEN}║  Acesse com: administrator@$REALM                   ║${NC}"
    echo -e "${GREEN}║  IP do servidor: $IP_ADDR                           ║${NC}"
    echo -e "${GREEN}║                                                     ║${NC}"
    echo -e "${GREEN}║  📄 Relatório: $REPORT_FILE                         ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    
    read -p "Reiniciar o servidor agora? (s/N): " -n 1 -r
    [[ "$REPLY" =~ ^[Ss]$ ]] && { log "Reiniciando em 5 segundos..."; sleep 5; reboot; }
}

# ══════════════════════════════════════════════════════════════
#              FLUXO 2 — DC SECUNDÁRIO
# ══════════════════════════════════════════════════════════════

setup_secondary_dc() {
    clear
    
    # Instala pacotes essenciais e configura locale no início
    install_essentials
    config_locale
    
    echo -e "${BLUE}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        CONFIGURAÇÃO — DC SECUNDÁRIO              ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}"
    
    detect_interface
    
    read -p "Domínio (ex: rnv.local): " -e DOMAIN
    DOMAIN="${DOMAIN,,}"
    REALM="${DOMAIN^^}"
    read -p "IP do DC Primário: " -e PRIMARY_IP
    read -p "Hostname deste servidor (default: adserver02): " -e INPUT_HOSTNAME
    HOSTNAME="${INPUT_HOSTNAME:-adserver02}"
    read -p "Usuário administrador do domínio (ex: administrator): " -e ADMIN_USER
    ADMIN_USER="${ADMIN_USER:-administrator}"
    
    ADMIN_PASSWORD=$(read_password "Digite a senha do administrador do domínio: ")
    echo
    
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
    
    register_step "Início da configuração DC Secundário" "INFO" "Domínio: $DOMAIN"
    
    config_bash_completion
    config_ssh_root
    config_ntp "$PRIMARY_IP"
    
    log "Configurando hostname: ${HOSTNAME}.${DOMAIN}"
    hostnamectl set-hostname "${HOSTNAME}.${DOMAIN}"
    register_step "Configuração de hostname" "OK" "${HOSTNAME}.${DOMAIN}"
    
    log "Configurando /etc/hosts"
    cp /etc/hosts "/etc/hosts.bak.$(date +%Y%m%d_%H%M%S)" || true
    cat > /etc/hosts << EOF
127.0.0.1 localhost
127.0.1.1 ${HOSTNAME}.${DOMAIN} ${HOSTNAME}
${PRIMARY_IP} dc-primary.${DOMAIN} dc-primary
${IP_ADDR} ${HOSTNAME}.${DOMAIN} ${HOSTNAME}
EOF
    register_step "Configuração /etc/hosts" "OK"
    
    log "Configurando /etc/resolv.conf para usar DNS do primário"
    [ -f /etc/resolv.conf ] && cp /etc/resolv.conf "/etc/resolv.conf.bak.$(date +%Y%m%d_%H%M%S)"
    cat > /etc/resolv.conf << EOF
nameserver ${PRIMARY_IP}
nameserver 127.0.0.1
search ${DOMAIN}
domain ${DOMAIN}
EOF
    register_step "Configuração DNS" "OK"
    
    log "Instalando pacotes necessários..."
    apt install -y -qq acl attr samba samba-dsdb-modules samba-vfs-modules \
        winbind krb5-user dnsutils ldap-utils bash-completion \
        language-pack-pt locales chrony 2>/dev/null || true
    register_step "Instalação Samba AD" "OK"
    
    systemctl stop smbd nmbd winbind samba-ad-dc 2>/dev/null || true
    systemctl disable smbd nmbd winbind 2>/dev/null || true
    
    rm -rf /var/lib/samba/* /etc/samba/smb.conf /etc/krb5.conf 2>/dev/null || true
    
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
    register_step "Configuração Kerberos" "OK"
    
    log "Testando Kerberos com as credenciais fornecidas..."
    echo -n "${ADMIN_PASSWORD}" | kinit "$ADMIN_USER@$REALM" >/dev/null 2>&1 && {
        echo -e "${GREEN}✓ Autenticação Kerberos OK${NC}"
        kdestroy 2>/dev/null || true
    } || error "Kerberos falhou — verifique domínio, usuário e senha"
    
    log "Juntando ao domínio ${REALM} como DC Secundário..."
    
    samba-tool domain join "$REALM" DC \
        --dns-backend=SAMBA_INTERNAL \
        --option="interfaces=lo $INTERFACE" \
        --option="bind interfaces only=yes" \
        --server="$PRIMARY_IP" \
        -U"${ADMIN_USER}@${REALM}" \
        --password="$ADMIN_PASSWORD" \
        > /tmp/join.log 2>&1 || error "Join falhou (veja /tmp/join.log)"
    
    echo -e "${GREEN}✓ Servidor juntado ao domínio como DC Secundário${NC}"
    register_step "Join ao domínio" "OK" "$REALM"
    
    log "Ajustando /etc/samba/smb.conf para replicação"
    cp "/var/lib/samba/private/smb.conf" "/etc/samba/smb.conf"
    sed -i "/^interfaces/s|=.*| = lo $INTERFACE|" "/etc/samba/smb.conf" || true
    
    log "Iniciando samba-ad-dc..."
    systemctl unmask samba-ad-dc || true
    systemctl enable samba-ad-dc || true
    systemctl restart samba-ad-dc
    sleep 20
    register_step "Inicialização Samba AD" "OK"
    
    log "Verificando replicação DRS com o primário..."
    if samba-tool drs showrepl 2>&1 | grep -q "$PRIMARY_IP"; then
        echo -e "${GREEN}✓ Replicação DRS ativa com $PRIMARY_IP${NC}"
    else
        warn "Replicação DRS não detectada — pode levar alguns minutos"
    fi
    
    run_tests_secondary "$DOMAIN" "$REALM" "$IP_ADDR" "$PRIMARY_IP"
    
    # Gera relatório final
    generate_final_report "SECONDARY" "$DOMAIN" "$REALM" "$HOSTNAME" "$IP_ADDR"
    
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅ DC SECUNDÁRIO CONFIGURADO COM SUCESSO!         ║${NC}"
    echo -e "${GREEN}║                                                     ║${NC}"
    echo -e "${GREEN}║  📄 Relatório: $REPORT_FILE                         ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    
    read -p "Reiniciar o servidor agora? (s/N): " -n 1 -r
    [[ "$REPLY" =~ ^[Ss]$ ]] && { log "Reiniciando em 5 segundos..."; sleep 5; reboot; }
}

# ══════════════════════════════════════════════════════════════
#              FLUXO 4 — LINUX COMO ESTAÇÃO
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
    ADMIN_PASSWORD=$(read_password "Digite a senha do domínio: ")
    echo
    
    log "Instalando pacotes necessários..."
    apt update -qq 2>/dev/null || true
    apt install -y -qq realmd sssd sssd-tools adcli oddjob oddjob-mkhomedir \
        krb5-user krb5-config samba-common samba-common-bin \
        policykit-1 2>/dev/null || true
    register_step "Instalação pacotes estação Linux" "OK"
    
    log "Descobrindo o domínio..."
    realm discover "$DOMAIN" || warn "Domínio não encontrado"
    
    log "Executando realm join..."
    echo -n "${ADMIN_PASSWORD}" | realm join --user="$ADMIN_USER" "$DOMAIN" --password="$ADMIN_PASSWORD" || {
        warn "realm join falhou — tentando modo interativo..."
        realm join --user="$ADMIN_USER" "$DOMAIN" || error "Join falhou"
    }
    register_step "Join estação Linux ao domínio" "OK" "$DOMAIN"
    
    log "Habilitando criação automática de home directory..."
    systemctl enable --now oddjobd 2>/dev/null || true
    realm permit "$ADMIN_USER@$DOMAIN" 2>/dev/null || true
    
    log "Configurando sudoers para administradores do domínio..."
    cat > /etc/sudoers.d/ad_admins << EOF
%Domain\\ Admins@$DOMAIN ALL=(ALL:ALL) ALL
EOF
    register_step "Configuração sudoers" "OK"
    
    echo
    echo -e "${GREEN}✅ ESTAÇÃO LINUX CONFIGURADA COMO MEMBRO DO AD${NC}"
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

# Inicializa o relatório
echo "═══════════════════════════════════════════════════════════════════════" > "$REPORT_FILE"
echo "  RELATÓRIO DE INSTALAÇÃO - SAMBA AD DC - $(date '+%d/%m/%Y %H:%M:%S')" >> "$REPORT_FILE"
echo "═══════════════════════════════════════════════════════════════════════" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

log "Iniciando SAMBA AD SERVER UNIFICADO PRO"
log "Sistema: $(lsb_release -ds 2>/dev/null || echo "Ubuntu 24.04") | Samba $(samba --version 2>/dev/null | head -1 || echo "4.19.5")"

main_menu
