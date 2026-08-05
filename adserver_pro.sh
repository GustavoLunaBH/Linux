#!/bin/bash
# adserver_pro.sh — Script unificado para DC Primário/Secundário com Samba AD
# Ubuntu 24.04 | Samba 4.19.5 | Alta disponibilidade e replicação nativa
# Versão: 2.1

set -euo pipefail  # Aborta em erro, undefined var, pipe fail

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

# Logging
log()    { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $*"; }
error()  { echo -e "${RED}[ERRO]${NC} $*" >&2; exit 1; }
warn()   { echo -e "${YELLOW}[AVISO]${NC} $*" >&2; }
info()   { echo -e "${BLUE}[INFO]${NC} $*"; }
debug()  { [[ "${DEBUG:-0}" == "1" ]] && echo -e "${CYAN}[DEBUG]${NC} $*"; }

# Verifica root
if [[ $EUID -ne 0 ]]; then
    error "Execute como root (sudo)"
fi

# ============================================
# FUNÇÃO: INSTALAR PACOTES ESSENCIAIS
# ============================================

install_essentials() {
    log "Verificando e instalando pacotes essenciais..."
    
    # Detecta o gerenciador de pacotes
    if command -v apt &>/dev/null; then
        PKG_MANAGER="apt"
        PKG_UPDATE="apt update -qq"
        PKG_INSTALL="apt install -y -qq"
        ESSENTIALS="nano iputils-ping iputils-tracepath curl wget net-tools"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
        PKG_UPDATE="dnf check-update -q"
        PKG_INSTALL="dnf install -y -q"
        ESSENTIALS="nano iputils curl wget net-tools"
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"
        PKG_UPDATE="yum check-update -q"
        PKG_INSTALL="yum install -y -q"
        ESSENTIALS="nano iputils curl wget net-tools"
    elif command -v zypper &>/dev/null; then
        PKG_MANAGER="zypper"
        PKG_UPDATE="zypper refresh -q"
        PKG_INSTALL="zypper install -y -q"
        ESSENTIALS="nano iputils curl wget net-tools"
    else
        warn "Gerenciador de pacotes não detectado. Pulando instalação de pacotes."
        return 0
    fi
    
    info "Gerenciador detectado: $PKG_MANAGER"
    
    # Atualiza cache (se aplicável)
    if [[ "$PKG_MANAGER" != "dnf" ]] || [[ "$PKG_MANAGER" != "yum" ]]; then
        eval "$PKG_UPDATE" 2>/dev/null || true
    fi
    
    # Instala cada pacote individualmente
    for pkg in $ESSENTIALS; do
        if ! command -v "$pkg" &>/dev/null && [[ "$pkg" != "iputils-ping" ]] && [[ "$pkg" != "iputils" ]]; then
            if [[ "$pkg" == "nano" ]] && ! command -v nano &>/dev/null; then
                log "Instalando $pkg..."
                eval "$PKG_INSTALL $pkg" 2>/dev/null || warn "Falha ao instalar $pkg"
            elif [[ "$pkg" == "iputils-ping" ]] || [[ "$pkg" == "iputils" ]]; then
                if ! command -v ping &>/dev/null; then
                    log "Instalando iputils..."
                    if [[ "$PKG_MANAGER" == "apt" ]]; then
                        eval "$PKG_INSTALL iputils-ping" 2>/dev/null || warn "Falha ao instalar iputils-ping"
                    else
                        eval "$PKG_INSTALL iputils" 2>/dev/null || warn "Falha ao instalar iputils"
                    fi
                fi
            else
                if ! command -v "$pkg" &>/dev/null; then
                    log "Instalando $pkg..."
                    eval "$PKG_INSTALL $pkg" 2>/dev/null || warn "Falha ao instalar $pkg"
                fi
            fi
        fi
    done
    
    echo -e "${GREEN}✓ Pacotes essenciais verificados${NC}"
}

# ============================================
# FUNÇÃO MELHORADA: LER SENHA COM SEGURANÇA
# ============================================

read_password() {
    local prompt="$1"
    local password=""
    local char=""
    local IFS=""
    
    echo -ne "${BLUE}$prompt${NC}" >&2
    stty -echo -icanon min 1 time 0
    
    while IFS= read -r -n 1 char; do
        if [[ -z "$char" ]]; then
            # Enter pressionado
            break
        elif [[ "$char" == $'\x7f' ]] || [[ "$char" == $'\x08' ]]; then
            # Backspace
            if [[ -n "$password" ]]; then
                password="${password%?}"
                echo -ne "\b \b" >&2
            fi
        else
            password+="$char"
            echo -ne "*" >&2
        fi
    done
    
    stty echo -icanon
    echo >&2
    echo "$password"
}

# ============================================
# FUNÇÕES DE CONFIGURAÇÃO COMUNS
# ============================================

config_locale() {
    log "Configurando idioma Português Brasil..."
    apt update -qq 2>/dev/null || true
    apt install -y -qq language-pack-pt locales bash-completion 2>/dev/null || true
    locale-gen pt_BR.UTF-8 2>/dev/null || true
    update-locale LANG=pt_BR.UTF-8 LANGUAGE=pt_BR:pt LC_ALL=pt_BR.UTF-8 2>/dev/null || true
    export LANG=pt_BR.UTF-8 LANGUAGE=pt_BR:pt LC_ALL=pt_BR.UTF-8
    echo -e "${GREEN}✓ Locale pt_BR configurado${NC}"
}

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
}

config_ssh_root() {
    log "Configurando acesso root via SSH (atenção: risco de segurança)..."
    warn "ATENÇÃO: Permitir root via SSH expõe o servidor a ataques. Use apenas em redes confiáveis!"
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
    if grep -q "^PermitRootLogin" /etc/ssh/sshd_config 2>/dev/null; then
        sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null || true
    else
        echo "PermitRootLogin yes" >> /etc/ssh/sshd_config 2>/dev/null || true
    fi
    systemctl restart sshd 2>/dev/null || warn "Não foi possível reiniciar sshd — verifique manualmente"
    echo -e "${YELLOW}⚠ Root SSH ativado — revise /etc/ssh/sshd_config${NC}"
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
        warn "Não consegui detectar IP. Usando $IP_ADDR (edite manualmente se necessário)"
    fi
    echo -e "${GREEN}✓ Interface: ${INTERFACE} (${IP_ADDR})${NC}"
    export INTERFACE IP_ADDR
}

config_ntp() {
    local PRIMARY_NTP="$1"
    log "Configurando NTP (Chrony)..."
    apt install -y -qq chrony 2>/dev/null || true
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
        info "NTP primário configurado com servidores oficiais brasileiros"
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
        info "NTP secundário configurado para sincronizar com DC primário ($PRIMARY_NTP)"
    fi
    
    systemctl enable --now chrony -qq 2>/dev/null || true
    systemctl restart chrony -qq 2>/dev/null || true
    sleep 2
    chronyc sources >/dev/null 2>&1 && echo -e "${GREEN}✓ NTP sincronizado${NC}" || warn "NTP não sincronizou — verifique com 'chronyc sources'"
}

validate_password() {
    local pw="$1"
    [ ${#pw} -lt 8 ] && return 1
    echo "$pw" | grep -q "[A-Z]" || return 2
    echo "$pw" | grep -q "[a-z]" || return 3
    echo "$pw" | grep -q "[0-9]" || return 4
    return 0
}

# ============================================
# FUNÇÃO MELHORADA: DETECTAR NETPLAN
# ============================================

detect_netplan_file() {
    # Busca arquivos Netplan existentes (prioridade: cloud-init -> 01-netcfg -> outros)
    local CANDIDATES=()
    
    # 1. Primeiro, procura por arquivos de cloud-init (mais comuns em VMs)
    CANDIDATES+=($(find /etc/netplan -maxdepth 1 -name "*cloud-init*.yaml" -type f 2>/dev/null | sort))
    
    # 2. Depois procura por 01-netcfg (comum em instalações padrão)
    CANDIDATES+=($(find /etc/netplan -maxdepth 1 -name "01-netcfg*.yaml" -type f 2>/dev/null | sort))
    
    # 3. Por fim, qualquer outro .yaml
    CANDIDATES+=($(find /etc/netplan -maxdepth 1 -name "*.yaml" -type f ! -name "*cloud-init*" ! -name "01-netcfg*" 2>/dev/null | sort))
    
    # Remove duplicatas (mantém ordem de prioridade)
    local UNIQUE=()
    for file in "${CANDIDATES[@]}"; do
        if [[ ! " ${UNIQUE[*]} " =~ " ${file} " ]]; then
            UNIQUE+=("$file")
        fi
    done
    
    echo "${UNIQUE[@]}"
}

# ============================================
# FUNÇÃO MELHORADA: CONFIGURAR IP ESTAÇÃO LINUX
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
            # ================================
            # LINUX — NETPLAN INTELIGENTE
            # ================================
            
            # ① Detectar interface automaticamente
            log "Detectando interfaces de rede disponíveis..."
            IFS=$'\n'
            INTERFACES=($(ip link show | 
                awk '/^[0-9]+: [^ ]+:.*state UP/{gsub(":","",$2); print $2}' | 
                grep -E "^(en|eth|wl)" || true))
            
            if [ ${#INTERFACES[@]} -eq 0 ]; then
                INTERFACES=($(ip link show | 
                    awk '/^[0-9]+: [^ ]+:/ && !/lo|virbr|vnet/ {gsub(":","",$2); print $2}' | 
                    grep -E "^(en|eth|wl)" || true))
            fi
            
            if [ ${#INTERFACES[@]} -eq 0 ]; then
                error "Nenhuma interface de rede encontrada. Conecte o cabo/rede e tente novamente."
            elif [ ${#INTERFACES[@]} -eq 1 ]; then
                STA_IFACE="${INTERFACES[0]}"
                info "Interface detectada automaticamente: $STA_IFACE"
            else
                echo
                echo -e "${YELLOW}Múltiplas interfaces encontradas:${NC}"
                for i in "${!INTERFACES[@]}"; do
                    idx=$((i+1))
                    echo "  [$idx] ${INTERFACES[$i]}"
                done
                read -p "Selecione a interface [1-${#INTERFACES[@]}]: " IFACE_SEL
                STA_IFACE="${INTERFACES[$((IFACE_SEL-1))]}"
                [ -z "$STA_IFACE" ] && error "Seleção de interface inválida"
                info "Interface selecionada: $STA_IFACE"
            fi
            
            # ② Detectar arquivos Netplan
            log "Buscando arquivos Netplan em /etc/netplan/..."
            NETPLAN_FILES=($(detect_netplan_file))
            
            if [ ${#NETPLAN_FILES[@]} -eq 0 ]; then
                NETPLAN_PATH="/etc/netplan/01-ad-static.yaml"
                warn "Nenhum arquivo Netplan encontrado. Criando $NETPLAN_PATH"
            elif [ ${#NETPLAN_FILES[@]} -eq 1 ]; then
                NETPLAN_PATH="${NETPLAN_FILES[0]}"
                info "Arquivo Netplan encontrado: $NETPLAN_PATH"
            else
                echo
                echo -e "${YELLOW}Múltiplos arquivos Netplan encontrados (prioridade):${NC}"
                for i in "${!NETPLAN_FILES[@]}"; do
                    idx=$((i+1))
                    echo "  [$idx] ${NETPLAN_FILES[$i]}"
                done
                read -p "Selecione o arquivo a editar [1-${#NETPLAN_FILES[@]}] (Enter para o primeiro): " FILE_SEL
                if [ -z "$FILE_SEL" ]; then
                    NETPLAN_PATH="${NETPLAN_FILES[0]}"
                    info "Usando arquivo padrão: $NETPLAN_PATH"
                else
                    NETPLAN_PATH="${NETPLAN_FILES[$((FILE_SEL-1))]}"
                    [ -z "$NETPLAN_PATH" ] && error "Seleção de arquivo inválida"
                    info "Arquivo selecionado: $NETPLAN_PATH"
                fi
            fi
            
            # ③ Perguntar configuração de IP (valores inteligentes)
            echo
            CURRENT_IP=$(ip addr show "$STA_IFACE" 2>/dev/null | grep inet | grep -v inet6 | awk '{print $2}' | cut -d/ -f1 | head -1 || echo "")
            CURRENT_MASK=$(ip addr show "$STA_IFACE" 2>/dev/null | grep inet | grep -v inet6 | awk '{print $2}' | cut -d/ -f2 | head -1 || echo "24")
            CURRENT_GATEWAY=$(ip route | grep default | grep "$STA_IFACE" | awk '{print $3}' | head -1 || echo "")
            
            if [ -n "$CURRENT_IP" ]; then
                read -p "IP estático desejado [atual: $CURRENT_IP]: " STA_IP
                STA_IP="${STA_IP:-$CURRENT_IP}"
            else
                read -p "IP estático desejado (ex: 192.168.1.50): " STA_IP
            fi
            
            read -p "Máscara [atual: /$CURRENT_MASK]: " STA_MASK
            STA_MASK="${STA_MASK:-$CURRENT_MASK}"
            
            if [ -n "$CURRENT_GATEWAY" ]; then
                read -p "Gateway [atual: $CURRENT_GATEWAY]: " STA_GATEWAY
                STA_GATEWAY="${STA_GATEWAY:-$CURRENT_GATEWAY}"
            else
                read -p "Gateway (ex: 192.168.1.1): " STA_GATEWAY
            fi
            
            # DNS - melhorado para permitir 8.8.8.8 antes do AD
            echo -e "${BLUE}Configuração de DNS:${NC}"
            echo "  [1] 8.8.8.8 e 8.8.4.4 (Google)"
            echo "  [2] 1.1.1.1 e 1.0.0.1 (Cloudflare)"
            echo "  [3] IP do AD (quando já configurado)"
            echo "  [4] Personalizado"
            read -p "Escolha uma opção [1-4] (default: 1): " DNS_OPT
            DNS_OPT="${DNS_OPT:-1}"
            
            case "$DNS_OPT" in
                1)
                    STA_DNS1="8.8.8.8"
                    STA_DNS2="8.8.4.4"
                    info "DNS configurado: Google (8.8.8.8, 8.8.4.4)"
                    ;;
                2)
                    STA_DNS1="1.1.1.1"
                    STA_DNS2="1.0.0.1"
                    info "DNS configurado: Cloudflare (1.1.1.1, 1.0.0.1)"
                    ;;
                3)
                    read -p "IP do AD (ex: 192.168.1.2): " AD_IP
                    if [ -n "$AD_IP" ]; then
                        STA_DNS1="$AD_IP"
                        read -p "DNS secundário (opcional - Enter para pular): " STA_DNS2
                        info "DNS configurado: AD ($AD_IP)"
                    else
                        warn "IP do AD não informado, usando Google como fallback"
                        STA_DNS1="8.8.8.8"
                        STA_DNS2="8.8.4.4"
                    fi
                    ;;
                4)
                    echo -n -e "${BLUE}DNS 1 (obrigatório): ${NC}"
                    read STA_DNS1
                    [ -z "$STA_DNS1" ] && { warn "DNS 1 é obrigatório, usando 8.8.8.8"; STA_DNS1="8.8.8.8"; }
                    echo -n -e "${BLUE}DNS 2 (opcional — Enter para pular): ${NC}"
                    read STA_DNS2
                    ;;
                *)
                    STA_DNS1="8.8.8.8"
                    STA_DNS2="8.8.4.4"
                    info "Opção inválida, usando Google como padrão"
                    ;;
            esac
            
            # ④ Montar nova configuração YAML
            if [ -n "$STA_DNS2" ]; then
                NAMESERVERS="      nameservers:\n        addresses: [$STA_DNS1, $STA_DNS2]"
            else
                NAMESERVERS="      nameservers:\n        addresses: [$STA_DNS1]"
            fi
            
            # ⑤ Fazer backup e processar arquivo
            if [ -f "$NETPLAN_PATH" ]; then
                BACKUP_PATH="${NETPLAN_PATH}.bak.$(date +%Y%m%d_%H%M%S)"
                cp "$NETPLAN_PATH" "$BACKUP_PATH"
                info "Backup criado: $BACKUP_PATH"
                
                if grep -q "^[[:space:]]*${STA_IFACE}:" "$NETPLAN_PATH"; then
                    info "Interface $STA_IFACE já existe no arquivo — atualizando..."
                    
                    sed -i "/^[[:space:]]*${STA_IFACE}:/,/^[[:space:]]*[a-zA-Z]/{
                        /dhcp4/d
                        /dhcp6/d
                        /addresses/d
                        /gateway4/d
                        /nameservers/d
                    }" "$NETPLAN_PATH"
                    
                    awk -v iface="$STA_IFACE" \
                        -v ip="$STA_IP" \
                        -v mask="$STA_MASK" \
                        -v gw="$STA_GATEWAY" \
                        -v ns="$NAMESERVERS" '
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
                    info "Adicionando nova interface $STA_IFACE ao arquivo existente"
                    
                    awk -v iface="$STA_IFACE" \
                        -v ip="$STA_IP" \
                        -v mask="$STA_MASK" \
                        -v gw="$STA_GATEWAY" \
                        -v ns="$NAMESERVERS" '
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
                info "Arquivo Netplan criado: $NETPLAN_PATH"
            fi
            
            # ⑥ Validar e aplicar
            log "Validando configuração Netplan..."
            if netplan generate >/dev/null 2>&1; then
                echo -e "${GREEN}✓ Configuração validada com sucesso!${NC}"
            else
                warn "netplan generate gerou erros — restaurando backup..."
                [ -f "$BACKUP_PATH" ] && cp "$BACKUP_PATH" "$NETPLAN_PATH"
                error "Configuração inválida. Verifique o arquivo manualmente."
            fi
            
            log "Aplicando configuração (netplan try — reverte em 120s se falhar)..."
            if netplan try >/dev/null 2>&1; then
                echo -e "${GREEN}✓ Configuração aplicada com sucesso!${NC}"
                echo
                echo -e "${YELLOW}⚠ IMPORTANTE:${NC}"
                echo "Se a conexão cair, o sistema reverterá em 120 segundos."
                echo "Mantenha este terminal aberto."
                echo
                echo -e "${GREEN}Arquivo modificado: $NETPLAN_PATH${NC}"
                echo
                
                if [ -f "$BACKUP_PATH" ]; then
                    echo -e "${BLUE}--- Alterações realizadas ---${NC}"
                    diff -u "$BACKUP_PATH" "$NETPLAN_PATH" | grep -E "^[+-][^/-]" | head -20 || echo "Sem alterações visíveis"
                    echo -e "${BLUE}---------------------------${NC}"
                fi
            else
                warn "netplan try falhou — revertendo backup"
                [ -f "$BACKUP_PATH" ] && cp "$BACKUP_PATH" "$NETPLAN_PATH"
                error "Aplicação falhou. Backup restaurado."
            fi
            
            # ⑦ Gerar script de reversão
            SCRIPT_NAME="/root/reverter_netplan_$(basename "$NETPLAN_PATH" .yaml).sh"
            cat > "$SCRIPT_NAME" << EOF
#!/bin/bash
# Reverte configuração Netplan
cp "$BACKUP_PATH" "$NETPLAN_PATH"
netplan apply
echo "✅ Configuração revertida"
EOF
            chmod +x "$SCRIPT_NAME"
            
            echo
            echo -e "${YELLOW}Script de reversão: $SCRIPT_NAME${NC}"
            echo
            read -p "Pressione Enter para continuar..."
            ;;
            
        2)
            # ================================
            # WINDOWS — SCRIPT BATCH
            # ================================
            echo
            read -p "IP da estação Windows (ex: 192.168.1.51): " STA_IP
            read -p "Máscara (ex: 255.255.255.0): " STA_MASK
            read -p "Gateway (ex: 192.168.1.1): " STA_GATEWAY
            
            echo -e "${BLUE}Configuração de DNS:${NC}"
            echo "  [1] 8.8.8.8 e 8.8.4.4 (Google)"
            echo "  [2] 1.1.1.1 e 1.0.0.1 (Cloudflare)"
            echo "  [3] IP do AD"
            echo "  [4] Personalizado"
            read -p "Escolha uma opção [1-4] (default: 1): " DNS_OPT
            DNS_OPT="${DNS_OPT:-1}"
            
            case "$DNS_OPT" in
                1)
                    STA_DNS1="8.8.8.8"
                    STA_DNS2="8.8.4.4"
                    ;;
                2)
                    STA_DNS1="1.1.1.1"
                    STA_DNS2="1.0.0.1"
                    ;;
                3)
                    read -p "IP do AD: " AD_IP
                    STA_DNS1="${AD_IP:-8.8.8.8}"
                    echo -n "DNS secundário (opcional): "
                    read STA_DNS2
                    ;;
                4)
                    read -p "DNS 1: " STA_DNS1
                    STA_DNS1="${STA_DNS1:-8.8.8.8}"
                    read -p "DNS 2: " STA_DNS2
                    ;;
                *)
                    STA_DNS1="8.8.8.8"
                    STA_DNS2="8.8.4.4"
                    ;;
            esac
            
            read -p "Nome da interface (ex: Ethernet): " STA_IFACE
            
            cat > "/root/config_ip_estacao_${STA_IP}.bat" << EOF
@echo off
REM Configuração de IP estático — gerada pelo adserver_pro.sh
REM Execute como Administrador

echo.
echo ⚠ ATENÇÃO: Esta configuração irá substituir o DHCP da interface "$STA_IFACE"
echo.
pause

echo Configurando IP estático...

netsh interface ipv4 set address name="$STA_IFACE" source=static address=$STA_IP mask=$STA_MASK gateway=$STA_GATEWAY gwmetric=1
netsh interface ipv4 set dns name="$STA_IFACE" source=static address=$STA_DNS1 register=primary
EOF
            [ -n "$STA_DNS2" ] && echo "netsh interface ipv4 add dns name=\"$STA_IFACE\" address=$STA_DNS2 index=2" >> "/root/config_ip_estacao_${STA_IP}.bat"
            
            cat >> "/root/config_ip_estacao_${STA_IP}.bat" << EOF

echo.
echo ✅ Configuração aplicada!
echo.
echo Reinicie a interface ou execute:
echo   ipconfig /release
echo   ipconfig /renew
echo.
pause
EOF
            
            echo
            echo -e "${GREEN}✓ Arquivo gerado: /root/config_ip_estacao_${STA_IP}.bat${NC}"
            echo "Copie para a estação Windows e execute como Administrador."
            echo
            read -p "Pressione Enter para continuar..."
            ;;
            
        *)
            error "Opção inválida"
            ;;
    esac
}

# ============================================
# FUNÇÕES DE TESTE — BATERIA FINAL
# ============================================

run_tests_primary() {
    local DOMAIN="$1" REALM="$2" IP="$3"
    log "════════════════════════════════════════════════════"
    log "          BATERIA DE TESTES — DC PRIMÁRIO"
    log "════════════════════════════════════════════════════"
    
    info "1. Testando resolução DNS interno..."
    host -t A localhost >/dev/null && echo -e "${GREEN}✓ localhost OK${NC}" || echo -e "${RED}✗ localhost NOK${NC}"
    
    info "2. Testando SRV LDAP do domínio..."
    host -t SRV "_ldap._tcp.${DOMAIN}" >/dev/null 2>&1 && echo -e "${GREEN}✓ SRV LDAP OK${NC}" || echo -e "${RED}✗ SRV LDAP NOK${NC}"
    
    info "3. Testando A record do hostname..."
    host -t A "$HOSTNAME.$DOMAIN" >/dev/null 2>&1 && echo -e "${GREEN}✓ Hostname DNS OK${NC}" || echo -e "${RED}✗ Hostname DNS NOK${NC}"
    
    info "4. Testando Kerberos (kinit)..."
    echo -n "${ADMIN_PASSWORD}" | kinit administrator@"$REALM" >/dev/null 2>&1 && {
        echo -e "${GREEN}✓ Kerberos OK${NC}"
        klist | grep -q "administrator" && echo -e "  → Ticket válido: $(klist | grep administrator)"
    } || echo -e "${RED}✗ Kerberos falhou${NC}"
    
    info "5. Verificando status do serviço samba-ad-dc..."
    systemctl is-active --quiet samba-ad-dc && echo -e "${GREEN}✓ Serviço ativo${NC}" || echo -e "${RED}✗ Serviço inativo${NC}"
    
    info "6. Testando sintaxe do smb.conf..."
    testparm -s >/dev/null 2>&1 && echo -e "${GREEN}✓ testparm OK${NC}" || echo -e "${RED}✗ testparm falhou${NC}"
    
    info "7. Verificando NTP..."
    chronyc sources | grep -q "^." && echo -e "${GREEN}✓ Chrony tem fontes ativas${NC}" || echo -e "${RED}✗ Chrony sem fontes${NC}"
    
    info "8. Verificando replicação DRS (sem parceiros esperados neste momento)..."
    samba-tool drs showrepl 2>&1 | grep -q "No DRS partners" && echo -e "${YELLOW}→ Nenhum parceiro de replicação configurado (esperado no primário isolado)${NC}" || echo -e "${GREEN}✓ DRS funcional${NC}"
    
    log "════════════════════════════════════════════════════"
}

run_tests_secondary() {
    local DOMAIN="$1" REALM="$2" IP="$3" PRIMARY_IP="$4"
    log "════════════════════════════════════════════════════"
    log "          BATERIA DE TESTES — DC SECUNDÁRIO"
    log "════════════════════════════════════════════════════"
    
    info "1. Testando resolução DNS (deve resolver pelo próprio Samba DNS)..."
    host -t A "$HOSTNAME.$DOMAIN" >/dev/null 2>&1 && echo -e "${GREEN}✓ Hostname local OK${NC}" || echo -e "${RED}✗ Hostname local NOK${NC}"
    
    info "2. Testando SRV LDAP do domínio via DNS local..."
    host -t SRV "_ldap._tcp.${DOMAIN}" 127.0.0.1 >/dev/null 2>&1 && echo -e "${GREEN}✓ SRV LDAP via DNS local OK${NC}" || echo -e "${RED}✗ SRV LDAP NOK${NC}"
    
    info "3. Testando Kerberos..."
    echo -n "${ADMIN_PASSWORD}" | kinit administrator@"$REALM" >/dev/null 2>&1 && {
        echo -e "${GREEN}✓ Kerberos OK${NC}"
        klist | grep -q "administrator" && echo -e "  → Ticket válido"
    } || echo -e "${RED}✗ Kerberos falhou${NC}"
    
    info "4. Verificando status do serviço..."
    systemctl is-active --quiet samba-ad-dc && echo -e "${GREEN}✓ Serviço ativo${NC}" || echo -e "${RED}✗ Serviço inativo${NC}"
    
    info "5. Testando replicação DRS com o primário..."
    if samba-tool drs showrepl 2>&1 | grep -q "$PRIMARY_IP"; then
        echo -e "${GREEN}✓ Replicação DRS ativa com $PRIMARY_IP${NC}"
    else
        echo -e "${RED}✗ Replicação DRS não detectada${NC}"
        warn "Execute 'samba-tool drs showrepl' manualmente para diagnosticar"
    fi
    
    info "6. Testando wbinfo..."
    wbinfo -t >/dev/null 2>&1 && echo -e "${GREEN}✓ wbinfo conectado ao AD${NC}" || echo -e "${RED}✗ wbinfo falhou${NC}"
    
    info "7. Verificando NTP (deve apontar para o primário)..."
    chronyc sources | grep -q "$PRIMARY_IP" && echo -e "${GREEN}✓ NTP sincronizando com primário${NC}" || echo -e "${RED}✗ NTP não apontando para primário${NC}"
    
    log "════════════════════════════════════════════════════"
}

# ══════════════════════════════════════════════════════════════
#              FLUXO 1 — DC PRIMÁRIO (MELHORADO)
# ══════════════════════════════════════════════════════════════

setup_primary_dc() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        CONFIGURAÇÃO — DC PRIMÁRIO               ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}"
    
    # Instala pacotes essenciais ANTES de tudo
    install_essentials
    
    detect_interface
    
    read -p "Domínio (ex: rnv.local): " -e DOMAIN
    DOMAIN="${DOMAIN,,}"
    REALM="${DOMAIN^^}"
    SHORT_DOMAIN=$(echo "$DOMAIN" | cut -d'.' -f1 | tr '[:lower:]' '[:upper:]')
    read -p "Hostname do servidor (default: adserver01): " -e INPUT_HOSTNAME
    HOSTNAME="${INPUT_HOSTNAME:-adserver01}"
    
    # Loop de senha melhorado
    while true; do
        echo -e "${BLUE}Digite a senha do administrador do domínio:${NC}"
        ADMIN_PASSWORD=$(read_password "> ")
        echo -e "${BLUE}Confirme a senha:${NC}"
        ADMIN_PASSWORD_CONFIRM=$(read_password "> ")
        
        if [ "$ADMIN_PASSWORD" = "$ADMIN_PASSWORD_CONFIRM" ]; then
            case "$(validate_password "$ADMIN_PASSWORD"; echo $?) " in
                0) break ;;
                1) warn "A senha deve ter pelo menos 8 caracteres!";;
                2) warn "A senha deve ter pelo menos uma letra maiúscula!";;
                3) warn "A senha deve ter pelo menos uma letra minúscula!";;
                4) warn "A senha deve ter pelo menos um número!";;
            esac
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
    
    config_locale
    config_bash_completion
    config_ssh_root
    config_ntp "SELF"
    
    log "Configurando hostname: ${HOSTNAME}.${DOMAIN}"
    hostnamectl set-hostname "${HOSTNAME}.${DOMAIN}"
    
    log "Configurando /etc/hosts"
    cp /etc/hosts "/etc/hosts.bak.$(date +%Y%m%d_%H%M%S)" || true
    cat > /etc/hosts << EOF
127.0.0.1 localhost
127.0.1.1 ${HOSTNAME}.${DOMAIN} ${HOSTNAME}
${IP_ADDR} ${HOSTNAME}.${DOMAIN} ${HOSTNAME}
EOF
    
    log "Instalando pacotes do Samba AD..."
    apt install -y -qq acl attr samba samba-dsdb-modules samba-vfs-modules \
        winbind libpam-winbind libnss-winbind krb5-user dnsutils \
        bind9utils ldap-utils bash-completion language-pack-pt locales \
        chrony 2>/dev/null || true
    
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
    
    log "Configurando /etc/samba/smb.conf"
    cp "/var/lib/samba/private/smb.conf" "/etc/samba/smb.conf"
    
    sed -i "/^interfaces/s|=.*| = lo $INTERFACE|" "/etc/samba/smb.conf" || true
    sed -i "/^bind interfaces only/s|=.*| = yes|" "/etc/samba/smb.conf" || true
    
    grep -q "ldap server require strong auth" "/etc/samba/smb.conf" ||
        sed -i "/$$global$$/a \    ldap server require strong auth = no" "/etc/samba/smb.conf"
    
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
    
    log "Configurando /etc/resolv.conf para DNS local"
    [ -f /etc/resolv.conf ] && cp /etc/resolv.conf "/etc/resolv.conf.bak.$(date +%Y%m%d_%H%M%S)"
    cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
search ${DOMAIN}
domain ${DOMAIN}
EOF
    
    log "Iniciando serviços samba-ad-dc..."
    systemctl unmask samba-ad-dc || true
    systemctl enable samba-ad-dc || true
    systemctl restart samba-ad-dc
    sleep 20
    
    log "Criando grupos e usuários padrão..."
    samba-tool group add "admins" --description="Administradores do Domínio" 2>/dev/null || warn "Grupo admins já existe"
    samba-tool group add "users" --description="Usuários do Domínio" 2>/dev/null || warn "Grupo users já existe"
    samba-tool user create admin2 "$ADMIN_PASSWORD" --given-name="Admin" --surname="Secundário" 2>/dev/null || warn "Usuário admin2 já existe"
    samba-tool group addmembers "Domain Admins" admin2 2>/dev/null || warn "Não foi possível adicionar admin2 ao grupo Domain Admins"
    
    log "Salvando informações em /root/ad_info.txt"
    cat > /root/ad_info.txt << EOF
╔══════════════════════════════════════════════════════════╗
║              INFORMAÇÕES DO DC PRIMÁRIO                 ║
╠══════════════════════════════════════════════════════════╣
DOMÍNIO:     $DOMAIN
REALM:       $REALM
HOSTNAME:    $HOSTNAME
IP:          $IP_ADDR
INTERFACE:   $INTERFACE
DATA:        $(date)

ADMINISTRADOR: administrator@$REALM
SENHA:       $ADMIN_PASSWORD

COMANDOS ÚTEIS:
────────────────────────────────────────
# Testar Kerberos
echo '$ADMIN_PASSWORD' | kinit administrator@$REALM
klist

# Listar usuários/grupos
samba-tool user list
samba-tool group list

# Testar DNS
host -t SRV _ldap._tcp.$DOMAIN
host -t A $HOSTNAME.$DOMAIN

# Verificar replicação DRS (sem parceiros esperados)
samba-tool drs showrepl

# Logs
tail -f /var/log/samba/log.samba
tail -f /var/log/krb5kdc.log

────────────────────────────────────────
ATENÇÃO: root SSH está ativado! Revise /etc/ssh/sshd_config
em caso de exposição à internet.
╚══════════════════════════════════════════════════════════╝
EOF
    
    run_tests_primary "$DOMAIN" "$REALM" "$IP_ADDR"
    
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅ DC PRIMÁRIO CONFIGURADO COM SUCESSO!           ║${NC}"
    echo -e "${GREEN}║                                                     ║${NC}"
    echo -e "${GREEN}║  Acesse com: administrator@$REALM                   ║${NC}"
    echo -e "${GREEN}║  IP do servidor: $IP_ADDR                           ║${NC}"
    echo -e "${GREEN}║                                                     ║${NC}"
    echo -e "${GREEN}║  Documentação: /root/ad_info.txt                      ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    
    read -p "Reiniciar o servidor agora? (s/N): " -n 1 -r
    [[ "$REPLY" =~ ^[Ss]$ ]] && { log "Reiniciando em 5 segundos..."; sleep 5; reboot; }
}

# ══════════════════════════════════════════════════════════════
#              FLUXO 2 — DC SECUNDÁRIO
# ══════════════════════════════════════════════════════════════

setup_secondary_dc() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        CONFIGURAÇÃO — DC SECUNDÁRIO              ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}"
    
    # Instala pacotes essenciais ANTES de tudo
    install_essentials
    
    detect_interface
    
    read -p "Domínio (ex: rnv.local): " -e DOMAIN
    DOMAIN="${DOMAIN,,}"
    REALM="${DOMAIN^^}"
    read -p "IP do DC Primário: " -e PRIMARY_IP
    read -p "Hostname deste servidor (default: adserver02): " -e INPUT_HOSTNAME
    HOSTNAME="${INPUT_HOSTNAME:-adserver02}"
    read -p "Usuário administrador do domínio (ex: administrator): " -e ADMIN_USER
    ADMIN_USER="${ADMIN_USER:-administrator}"
    
    echo -e "${BLUE}Digite a senha do administrador do domínio:${NC}"
    ADMIN_PASSWORD=$(read_password "> ")
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
    
    config_locale
    config_bash_completion
    config_ssh_root
    config_ntp "$PRIMARY_IP"
    
    log "Configurando hostname: ${HOSTNAME}.${DOMAIN}"
    hostnamectl set-hostname "${HOSTNAME}.${DOMAIN}"
    
    log "Configurando /etc/hosts"
    cp /etc/hosts "/etc/hosts.bak.$(date +%Y%m%d_%H%M%S)" || true
    cat > /etc/hosts << EOF
127.0.0.1 localhost
127.0.1.1 ${HOSTNAME}.${DOMAIN} ${HOSTNAME}
${PRIMARY_IP} dc-primary.${DOMAIN} dc-primary
${IP_ADDR} ${HOSTNAME}.${DOMAIN} ${HOSTNAME}
EOF
    
    log "Configurando /etc/resolv.conf para usar DNS do primário"
    [ -f /etc/resolv.conf ] && cp /etc/resolv.conf "/etc/resolv.conf.bak.$(date +%Y%m%d_%H%M%S)"
    cat > /etc/resolv.conf << EOF
nameserver ${PRIMARY_IP}
nameserver 127.0.0.1
search ${DOMAIN}
domain ${DOMAIN}
EOF
    
    log "Instalando pacotes necessários..."
    apt install -y -qq acl attr samba samba-dsdb-modules samba-vfs-modules \
        winbind krb5-user dnsutils ldap-utils bash-completion \
        language-pack-pt locales chrony 2>/dev/null || true
    
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
    
    log "Testando Kerberos com as credenciais fornecidas..."
    echo -n "${ADMIN_PASSWORD}" | kinit "$ADMIN_USER@$REALM" >/dev/null 2>&1 && {
        echo -e "${GREEN}✓ Autenticação Kerberos OK — credenciais válidas${NC}"
        kdestroy 2>/dev/null || true
    } || error "Kerberos falhou — verifique domínio, usuário e senha"
    
    log "Juntando ao domínio ${REALM} como DC Secundário..."
    info "Isso pode levar alguns minutos..."
    
    samba-tool domain join "$REALM" DC \
        --dns-backend=SAMBA_INTERNAL \
        --option="interfaces=lo $INTERFACE" \
        --option="bind interfaces only=yes" \
        --server="$PRIMARY_IP" \
        -U"${ADMIN_USER}@${REALM}" \
        --password="$ADMIN_PASSWORD" \
        > /tmp/join.log 2>&1 || error "Join falhou (veja /tmp/join.log)"
    
    echo -e "${GREEN}✓ Servidor juntado ao domínio como DC Secundário${NC}"
    
    log "Ajustando /etc/samba/smb.conf para replicação"
    cp "/var/lib/samba/private/smb.conf" "/etc/samba/smb.conf"
    
    sed -i "/^interfaces/s|=.*| = lo $INTERFACE|" "/etc/samba/smb.conf" || true
    
    log "Iniciando samba-ad-dc..."
    systemctl unmask samba-ad-dc || true
    systemctl enable samba-ad-dc || true
    systemctl restart samba-ad-dc
    sleep 20
    
    log "Verificando replicação DRS com o primário..."
    if samba-tool drs showrepl 2>&1 | grep -q "$PRIMARY_IP"; then
        echo -e "${GREEN}✓ Replicação DRS ativa com $PRIMARY_IP${NC}"
    else
        warn "Replicação DRS não detectada — pode levar alguns minutos ou verificar logs"
    fi
    
    log "Salvando informações em /root/ad_info.txt"
    cat > /root/ad_info.txt << EOF
╔══════════════════════════════════════════════════════════╗
║             INFORMAÇÕES DO DC SECUNDÁRIO                ║
╠══════════════════════════════════════════════════════════╣
DOMÍNIO:     $DOMAIN
REALM:       $REALM
DC PRIMÁRIO: $PRIMARY_IP
HOSTNAME:    $HOSTNAME
IP:          $IP_ADDR
INTERFACE:   $INTERFACE
DATA:        $(date)

USUÁRIO JOIN: $ADMIN_USER@$REALM

COMANDOS ÚTEIS:
────────────────────────────────────────
# Testar replicação DRS
samba-tool drs showrepl

# Testar Kerberos
echo '$ADMIN_PASSWORD' | kinit $ADMIN_USER@$REALM
klist

# Testar DNS (deve resolver pelo primário)
host -t SRV _ldap._tcp.$DOMAIN
host -t A $HOSTNAME.$DOMAIN

# Logs
tail -f /var/log/samba/log.samba
tail -f /var/log/krb5kdc.log

────────────────────────────────────────
ATENÇÃO: root SSH está ativado! Revise /etc/ssh/sshd_config
em caso de exposição à internet.
╚══════════════════════════════════════════════════════════╝
EOF
    
    run_tests_secondary "$DOMAIN" "$REALM" "$IP_ADDR" "$PRIMARY_IP"
    
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅ DC SECUNDÁRIO CONFIGURADO COM SUCESSO!         ║${NC}"
    echo -e "${GREEN}║                                                     ║${NC}"
    echo -e "${GREEN}║  Este servidor é um DC PLENO e pode assumir           ║${NC}"
    echo -e "${GREEN}║  as funções do primário se necessário.              ║${NC}"
    echo -e "${GREEN}║                                                     ║${NC}"
    echo -e "${GREEN}║  Documentação: /root/ad_info.txt                      ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    
    read -p "Reiniciar o servidor agora? (s/N): " -n 1 -r
    [[ "$REPLY" =~ ^[Ss]$ ]] && { log "Reiniciando em 5 segundos..."; sleep 5; reboot; }
}

# ══════════════════════════════════════════════════════════════
#              FLUXO 4 — LINUX COMO ESTAÇÃO DE TRABALHO
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
    echo -e "${BLUE}Digite a senha do domínio:${NC}"
    ADMIN_PASSWORD=$(read_password "> ")
    echo
    
    log "Instalando pacotes necessários (realmd, sssd, adcli, oddjobd)..."
    apt update -qq 2>/dev/null || true
    apt install -y -qq realmd sssd sssd-tools adcli oddjob oddjob-mkhomedir \
        krb5-user krb5-config samba-common samba-common-bin \
        policykit-1 2>/dev/null || true
    
    log "Descobrindo o domínio..."
    realm discover "$DOMAIN" || warn "Domínio não encontrado — verifique DNS e conectividade"
    
    log "Executando realm join (pode pedir senha novamente)..."
    echo -n "${ADMIN_PASSWORD}" | realm join --user="$ADMIN_USER" "$DOMAIN" --password="$ADMIN_PASSWORD" || {
        warn "realm join falhou — tentando sem --password (modo interativo)..."
        realm join --user="$ADMIN_USER" "$DOMAIN" || error "Join falhou (verifique logs em /var/log/realmd)"
    }
    
    log "Habilitando criação automática de home directory..."
    systemctl enable --now oddjobd 2>/dev/null || true
    realm permit "$ADMIN_USER@$DOMAIN" 2>/dev/null || true
    
    log "Configurando sudoers para administradores do domínio..."
    cat > /etc/sudoers.d/ad_admins << EOF
# Administradores do AD com permissão sudo
%Domain\\ Admins@$DOMAIN ALL=(ALL:ALL) ALL
EOF
    
    log "Testando resolução de usuário do domínio..."
    id "$ADMIN_USER@$DOMAIN" || warn "Usuário do domínio não resolvido — pode levar alguns minutos"
    
    echo
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅ ESTAÇÃO LINUX CONFIGURADA COMO MEMBRO DO AD   ║${NC}"
    echo -e "${GREEN}║                                                     ║${NC}"
    echo -e "${GREEN}║  Para testar login:                                  ║${NC}"
    echo -e "${GREEN}║  su - $ADMIN_USER@$DOMAIN                           ║${NC}"
    echo -e "${GREEN}║                                                     ║${NC}"
    echo -e "${GREEN}║  Para verificar: realm list / id <usuario>           ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    
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

log "Iniciando SAMBA AD SERVER UNIFICADO PRO"
log "Sistema: Ubuntu 24.04 | Samba $(samba --version 2>/dev/null | head -1)"

# Instala pacotes essenciais logo no início
install_essentials

main_menu
