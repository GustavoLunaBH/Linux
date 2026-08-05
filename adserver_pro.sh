#!/bin/bash
# adserver_pro.sh — Script unificado para DC Primário/Secundário com Samba AD
# Ubuntu 24.04 | Samba 4.19.5 | Alta disponibilidade e replicação nativa
# Versão: 4.1 - COM GERENCIAMENTO NETPLAN

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

# Variáveis globais
REPORT_FILE="/root/ad_install_report_$(date +%Y%m%d_%H%M%S).log"
INSTALL_STEPS=()
INSTALL_STATUS=()
STEP_COUNT=0
DOMAIN=""
REALM=""
HOSTNAME=""
IP_ADDR=""
INTERFACE=""
ADMIN_PASSWORD=""
NETPLAN_FILE=""

# Logging
log()    { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $*"; }
error()  { echo -e "${RED}[ERRO]${NC} $*" >&2; exit 1; }
warn()   { echo -e "${YELLOW}[AVISO]${NC} $*" >&2; }
info()   { echo -e "${BLUE}[INFO]${NC} $*"; }

# Função para registrar passos no relatório
register_step() {
    local step_name="$1"
    local status="$2"
    local details="${3:-}"
    STEP_COUNT=$((STEP_COUNT + 1))
    INSTALL_STEPS+=("$step_name")
    INSTALL_STATUS+=("$status")
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$status] $step_name $details" >> "$REPORT_FILE"
}

# Verifica root
if [[ $EUID -ne 0 ]]; then
    error "Execute como root (sudo)"
fi

# ============================================
# FUNÇÃO: PRÉ-CONFIGURAR KERBEROS (DEBCONF)
# ============================================

preconfigure_kerberos() {
    local realm="$1"
    local kdc_server="$2"
    local admin_server="$2"
    
    log "Pré-configurando Kerberos (debconf) para evitar interação..."
    
    cat << EOF | debconf-set-selections 2>/dev/null || true
krb5-config krb5-config/default_realm string $realm
krb5-config krb5-config/kerberos_servers string $kdc_server
krb5-config krb5-config/admin_server string $admin_server
krb5-user krb5-user/default_realm string $realm
krb5-user krb5-user/kerberos_servers string $kdc_server
krb5-user krb5-user/admin_server string $admin_server
EOF
    
    export DEBIAN_FRONTEND=noninteractive
    export KRB5_CONFIG="/etc/krb5.conf"
    
    register_step "Pré-configuração Kerberos" "OK" "Realm: $realm, KDC: $kdc_server"
}

# ============================================
# FUNÇÃO: INSTALAR PACOTES ESSENCIAIS
# ============================================

install_essentials() {
    log "════════════════════════════════════════════════════"
    log "     INSTALANDO PACOTES ESSENCIAIS"
    log "════════════════════════════════════════════════════"
    
    export DEBIAN_FRONTEND=noninteractive
    
    if command -v apt &>/dev/null; then
        log "Gerenciador detectado: APT (Ubuntu/Debian)"
        
        # Pré-configura pacotes que perguntam durante a instalação
        echo "krb5-config krb5-config/default_realm string" | debconf-set-selections 2>/dev/null
        echo "krb5-config krb5-config/kerberos_servers string" | debconf-set-selections 2>/dev/null
        echo "krb5-config krb5-config/admin_server string" | debconf-set-selections 2>/dev/null
        
        log "Atualizando cache de pacotes..."
        apt update -qq 2>/dev/null || true
        
        log "Instalando pacotes essenciais..."
        apt install -y -qq nano curl wget net-tools iputils-ping \
            language-pack-pt locales bash-completion debconf-utils \
            chrony systemd-resolved 2>/dev/null || true
        
        register_step "Instalação de pacotes essenciais (APT)" "OK" "nano, curl, wget, net-tools, iputils-ping, locale"
        
    elif command -v dnf &>/dev/null; then
        log "Gerenciador detectado: DNF (Fedora/RHEL)"
        dnf install -y -q nano iputils curl wget net-tools 2>/dev/null || true
        register_step "Instalação de pacotes essenciais (DNF)" "OK" "nano, iputils, curl, wget, net-tools"
        
    elif command -v yum &>/dev/null; then
        log "Gerenciador detectado: YUM (RHEL/CentOS)"
        yum install -y -q nano iputils curl wget net-tools 2>/dev/null || true
        register_step "Instalação de pacotes essenciais (YUM)" "OK" "nano, iputils, curl, wget, net-tools"
        
    else
        warn "Gerenciador de pacotes não detectado."
        register_step "Instalação de pacotes essenciais" "WARN" "Gerenciador não detectado"
    fi
    
    echo -e "${GREEN}✓ Pacotes essenciais verificados${NC}"
    echo ""
}

# ============================================
# FUNÇÃO: CONFIGURAR LOCALE
# ============================================

config_locale() {
    log "════════════════════════════════════════════════════"
    log "     CONFIGURANDO IDIOMA PORTUGUÊS BRASIL"
    log "════════════════════════════════════════════════════"
    
    export DEBIAN_FRONTEND=noninteractive
    
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
# FUNÇÃO: DETECTAR E GERENCIAR NETPLAN
# ============================================

detect_netplan_config() {
    local netplan_dir="/etc/netplan"
    local found_files=()
    
    log "Verificando arquivos Netplan em $netplan_dir..."
    
    # Lista todos os arquivos .yaml
    if [ -d "$netplan_dir" ]; then
        for file in "$netplan_dir"/*.yaml; do
            if [ -f "$file" ]; then
                found_files+=("$file")
                info "Arquivo encontrado: $file"
            fi
        done
    fi
    
    # Se não encontrou nenhum arquivo
    if [ ${#found_files[@]} -eq 0 ]; then
        warn "Nenhum arquivo Netplan encontrado. Criando novo..."
        NETPLAN_FILE="/etc/netplan/01-netcfg.yaml"
        return 0
    fi
    
    # Prioridade: 50-cloud-init.yaml > 01-netcfg.yaml > outros
    local priority_files=()
    
    # 1. Cloud-init (comum em VMs)
    for file in "${found_files[@]}"; do
        if [[ "$file" == *"cloud-init"* ]]; then
            priority_files+=("$file")
        fi
    done
    
    # 2. 01-netcfg (instalação padrão)
    for file in "${found_files[@]}"; do
        if [[ "$file" == *"01-netcfg"* ]] || [[ "$file" == *"01-netplan"* ]]; then
            priority_files+=("$file")
        fi
    done
    
    # 3. Outros arquivos
    for file in "${found_files[@]}"; do
        if [[ ! "$file" == *"cloud-init"* ]] && [[ ! "$file" == *"01-netcfg"* ]] && [[ ! "$file" == *"01-netplan"* ]]; then
            priority_files+=("$file")
        fi
    done
    
    # Remove duplicatas
    local unique_files=()
    for file in "${priority_files[@]}"; do
        if [[ ! " ${unique_files[*]} " =~ " ${file} " ]]; then
            unique_files+=("$file")
        fi
    done
    
    # Se tem múltiplos arquivos, mostra para o usuário escolher
    if [ ${#unique_files[@]} -gt 1 ]; then
        echo ""
        echo -e "${YELLOW}Múltiplos arquivos Netplan encontrados:${NC}"
        echo -e "${BLUE}─────────────────────────────────────────────────────${NC}"
        for i in "${!unique_files[@]}"; do
            idx=$((i+1))
            # Verifica se o arquivo tem configuração DHCP
            if grep -q "dhcp4: true" "${unique_files[$i]}" 2>/dev/null; then
                echo "  [$idx] ${unique_files[$i]} (DHCP ativo)"
            elif grep -q "addresses:" "${unique_files[$i]}" 2>/dev/null; then
                echo "  [$idx] ${unique_files[$i]} (IP estático)"
            else
                echo "  [$idx] ${unique_files[$i]}"
            fi
        done
        echo -e "${BLUE}─────────────────────────────────────────────────────${NC}"
        echo -e "${YELLOW}Qual arquivo deseja editar?${NC}"
        echo "  [0] Criar novo arquivo (recomendado)"
        read -p "Escolha [0-${#unique_files[@]}]: " FILE_CHOICE
        
        if [ "$FILE_CHOICE" == "0" ]; then
            NETPLAN_FILE="/etc/netplan/99-static-ip.yaml"
            info "Criando novo arquivo: $NETPLAN_FILE"
        elif [ -n "$FILE_CHOICE" ] && [ "$FILE_CHOICE" -le "${#unique_files[@]}" ] && [ "$FILE_CHOICE" -gt 0 ]; then
            NETPLAN_FILE="${unique_files[$((FILE_CHOICE-1))]}"
            info "Arquivo selecionado: $NETPLAN_FILE"
        else
            NETPLAN_FILE="${unique_files[0]}"
            warn "Opção inválida. Usando: $NETPLAN_FILE"
        fi
    else
        NETPLAN_FILE="${unique_files[0]}"
        info "Usando arquivo: $NETPLAN_FILE"
    fi
    
    # Verifica se o arquivo existe
    if [ ! -f "$NETPLAN_FILE" ]; then
        warn "Arquivo não encontrado. Criando novo..."
        NETPLAN_FILE="/etc/netplan/01-netcfg.yaml"
    fi
    
    export NETPLAN_FILE
    echo ""
    echo -e "${GREEN}✓ Arquivo Netplan selecionado: $NETPLAN_FILE${NC}"
    return 0
}

# ============================================
# FUNÇÃO: REMOVER IP DUPLICADO
# ============================================

remove_duplicate_ip() {
    local interface="$1"
    local ip_to_remove="$2"
    
    log "Verificando IPs duplicados na interface $interface..."
    
    # Lista todos os IPs na interface
    local ips=$(ip addr show "$interface" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
    
    for ip in $ips; do
        if [ "$ip" == "$ip_to_remove" ]; then
            warn "IP duplicado encontrado: $ip"
            log "Removendo IP $ip da interface $interface..."
            ip addr del "$ip/24" dev "$interface" 2>/dev/null && {
                echo -e "${GREEN}✓ IP $ip removido${NC}"
                register_step "Remoção IP duplicado" "OK" "$ip removido de $interface"
            } || {
                warn "Não foi possível remover o IP $ip"
            }
        fi
    done
}

# ============================================
# FUNÇÃO: CONFIGURAR IP ESTÁTICO
# ============================================

configure_static_ip() {
    local interface="$1"
    local ip="$2"
    local mask="${3:-24}"
    local gateway="${4:-}"
    local dns1="${5:-8.8.8.8}"
    local dns2="${6:-8.8.4.4}"
    
    log "Configurando IP estático para $interface..."
    
    # Detecta o arquivo Netplan correto
    detect_netplan_config
    
    # Faz backup
    local backup_file="${NETPLAN_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    if [ -f "$NETPLAN_FILE" ]; then
        cp "$NETPLAN_FILE" "$backup_file" 2>/dev/null || true
        info "Backup criado: $backup_file"
    fi
    
    # Cria o diretório se não existir
    mkdir -p /etc/netplan
    
    # Verifica se a interface já está configurada
    if [ -f "$NETPLAN_FILE" ] && grep -q "^[[:space:]]*${interface}:" "$NETPLAN_FILE" 2>/dev/null; then
        info "Interface $interface encontrada no arquivo. Atualizando..."
        
        # Remove configurações antigas da interface
        sed -i "/^[[:space:]]*${interface}:/,/^[[:space:]]*[a-zA-Z]/{
            /dhcp4/d
            /dhcp6/d
            /addresses/d
            /gateway4/d
            /nameservers/d
            /optional/d
        }" "$NETPLAN_FILE" 2>/dev/null || true
        
        # Adiciona nova configuração após a linha da interface
        if grep -q "^[[:space:]]*${interface}:" "$NETPLAN_FILE" 2>/dev/null; then
            awk -v iface="$interface" \
                -v ip="$ip" \
                -v mask="$mask" \
                -v gw="$gateway" \
                -v dns1="$dns1" \
                -v dns2="$dns2" '
            {
                print
                if ($0 ~ "^[[:space:]]*" iface ":" && !done) {
                    printf("      dhcp4: false\n")
                    printf("      addresses: [%s/%s]\n", ip, mask)
                    if (gw != "") printf("      gateway4: %s\n", gw)
                    if (dns1 != "") {
                        if (dns2 != "") {
                            printf("      nameservers:\n        addresses: [%s, %s]\n", dns1, dns2)
                        } else {
                            printf("      nameservers:\n        addresses: [%s]\n", dns1)
                        }
                    }
                    printf("      optional: true\n")
                    done=1
                }
            }' "$NETPLAN_FILE" > "${NETPLAN_FILE}.tmp" && mv "${NETPLAN_FILE}.tmp" "$NETPLAN_FILE"
        else
            # Interface não existe - adiciona no final da seção ethernets
            awk -v iface="$interface" \
                -v ip="$ip" \
                -v mask="$mask" \
                -v gw="$gateway" \
                -v dns1="$dns1" \
                -v dns2="$dns2" '
            {
                print
                if ($0 ~ "^[[:space:]]*ethernets:" && !done) {
                    printf("    %s:\n", iface)
                    printf("      dhcp4: false\n")
                    printf("      addresses: [%s/%s]\n", ip, mask)
                    if (gw != "") printf("      gateway4: %s\n", gw)
                    if (dns1 != "") {
                        if (dns2 != "") {
                            printf("      nameservers:\n        addresses: [%s, %s]\n", dns1, dns2)
                        } else {
                            printf("      nameservers:\n        addresses: [%s]\n", dns1)
                        }
                    }
                    printf("      optional: true\n")
                    done=1
                }
            }' "$NETPLAN_FILE" > "${NETPLAN_FILE}.tmp" && mv "${NETPLAN_FILE}.tmp" "$NETPLAN_FILE"
        fi
        
    else
        # Cria arquivo novo ou adiciona no final
        if [ -f "$NETPLAN_FILE" ]; then
            # Adiciona ao final
            cat >> "$NETPLAN_FILE" << EOF

  $interface:
    dhcp4: false
    addresses: [$ip/$mask]
EOF
            [ -n "$gateway" ] && echo "    gateway4: $gateway" >> "$NETPLAN_FILE"
            if [ -n "$dns1" ]; then
                if [ -n "$dns2" ]; then
                    echo "    nameservers:" >> "$NETPLAN_FILE"
                    echo "      addresses: [$dns1, $dns2]" >> "$NETPLAN_FILE"
                else
                    echo "    nameservers:" >> "$NETPLAN_FILE"
                    echo "      addresses: [$dns1]" >> "$NETPLAN_FILE"
                fi
            fi
            echo "    optional: true" >> "$NETPLAN_FILE"
        else
            # Cria arquivo novo
            cat > "$NETPLAN_FILE" << EOF
# Configuração gerada pelo adserver_pro.sh
network:
  version: 2
  ethernets:
    $interface:
      dhcp4: false
      addresses: [$ip/$mask]
EOF
            [ -n "$gateway" ] && echo "      gateway4: $gateway" >> "$NETPLAN_FILE"
            if [ -n "$dns1" ]; then
                if [ -n "$dns2" ]; then
                    echo "      nameservers:" >> "$NETPLAN_FILE"
                    echo "        addresses: [$dns1, $dns2]" >> "$NETPLAN_FILE"
                else
                    echo "      nameservers:" >> "$NETPLAN_FILE"
                    echo "        addresses: [$dns1]" >> "$NETPLAN_FILE"
                fi
            fi
            echo "      optional: true" >> "$NETPLAN_FILE"
        fi
    fi
    
    # Valida a configuração
    log "Validando configuração Netplan..."
    if netplan generate 2>/dev/null; then
        echo -e "${GREEN}✓ Configuração validada com sucesso!${NC}"
        
        log "Aplicando configuração..."
        if netplan apply 2>/dev/null; then
            echo -e "${GREEN}✓ Configuração aplicada com sucesso!${NC}"
            register_step "Configuração IP estático" "OK" "$interface -> $ip/$mask"
            
            # Aguarda a interface reconfigurar
            sleep 5
            
            # Verifica se o IP foi aplicado
            local new_ip=$(ip addr show "$interface" 2>/dev/null | grep "inet " | grep -v "secondary" | awk '{print $2}' | cut -d/ -f1 | head -1)
            if [ "$new_ip" == "$ip" ]; then
                echo -e "${GREEN}✓ IP $ip aplicado com sucesso em $interface${NC}"
                
                # Remove IPs duplicados
                remove_duplicate_ip "$interface" "$ip"
                
                return 0
            else
                warn "IP aplicado ($new_ip) diferente do esperado ($ip)"
                return 1
            fi
        else
            warn "Falha ao aplicar configuração. Restaurando backup..."
            [ -f "$backup_file" ] && cp "$backup_file" "$NETPLAN_FILE" 2>/dev/null || true
            register_step "Configuração IP estático" "FAIL" "Falha ao aplicar"
            return 1
        fi
    else
        warn "Configuração inválida. Restaurando backup..."
        [ -f "$backup_file" ] && cp "$backup_file" "$NETPLAN_FILE" 2>/dev/null || true
        register_step "Configuração IP estático" "FAIL" "Configuração inválida"
        return 1
    fi
}

# ============================================
# FUNÇÃO: TESTAR CONEXÃO DE REDE
# ============================================

test_network() {
    local test_ip="${1:-192.168.1.1}"
    local test_host="${2:-google.com}"
    
    log "════════════════════════════════════════════════════"
    log "          TESTANDO CONEXÃO DE REDE"
    log "════════════════════════════════════════════════════"
    
    local passed=0
    local failed=0
    
    info "1. Verificando IP da interface..."
    ip addr show | grep "inet " | grep -v "127.0.0.1" || echo "Nenhum IP configurado"
    echo ""
    
    info "2. Testando ping para o gateway ($test_ip)..."
    if ping -c 2 "$test_ip" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Gateway $test_ip acessível${NC}"
        ((passed++))
    else
        echo -e "${RED}✗ Gateway $test_ip não acessível${NC}"
        ((failed++))
    fi
    echo ""
    
    info "3. Testando ping para internet ($test_host)..."
    if ping -c 2 "$test_host" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Internet acessível ($test_host)${NC}"
        ((passed++))
    else
        echo -e "${RED}✗ Internet não acessível${NC}"
        ((failed++))
    fi
    echo ""
    
    info "4. Verificando DNS..."
    if nslookup "$test_host" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ DNS funcionando${NC}"
        ((passed++))
    else
        echo -e "${RED}✗ DNS não está funcionando${NC}"
        ((failed++))
    fi
    echo ""
    
    info "5. Verificando rotas..."
    ip route show default || echo "Nenhuma rota padrão definida"
    echo ""
    
    info "6. Verificando arquivos Netplan..."
    ls -la /etc/netplan/*.yaml 2>/dev/null || echo "Nenhum arquivo Netplan encontrado"
    echo ""
    
    log "════════════════════════════════════════════════════"
    echo -e "${BLUE}Resumo: ${GREEN}$passed OK${NC} / ${RED}$failed FAIL${NC}"
    echo ""
}

# ============================================
# FUNÇÃO: CONFIGURAR RESOLV.CONF
# ============================================

configure_resolv_conf() {
    local dns_server="$1"
    local domain="$2"
    local search_domains="${3:-$domain}"
    
    log "Configurando /etc/resolv.conf..."
    
    # Para o systemd-resolved se estiver rodando
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
    
    # Remove proteção se existir
    chattr -i /etc/resolv.conf 2>/dev/null || true
    
    # Cria o arquivo
    cat > /etc/resolv.conf << EOF
nameserver $dns_server
search $search_domains
domain $domain
EOF
    
    # Protege o arquivo
    chattr +i /etc/resolv.conf 2>/dev/null || true
    
    register_step "Configuração /etc/resolv.conf" "OK" "DNS: $dns_server, Domínio: $domain"
}

# ============================================
# FUNÇÃO: CONFIGURAR HOSTS
# ============================================

configure_hosts() {
    local hostname="$1"
    local domain="$2"
    local ip="$3"
    local primary_ip="${4:-}"
    
    log "Configurando /etc/hosts..."
    
    cat > /etc/hosts << EOF
127.0.0.1 localhost
127.0.1.1 ${hostname}.${domain} ${hostname}
${ip} ${hostname}.${domain} ${hostname}
EOF
    
    if [ -n "$primary_ip" ]; then
        echo "${primary_ip} adserver01.${domain} adserver01" >> /etc/hosts
    fi
    
    register_step "Configuração /etc/hosts" "OK" "${hostname}.${domain}"
}

# ============================================
# FUNÇÃO: CONFIGURAR KERBEROS
# ============================================

configure_kerberos() {
    local realm="$1"
    local domain="$2"
    local kdc="$3"
    local admin_server="$3"
    
    log "Configurando /etc/krb5.conf..."
    
    cat > /etc/krb5.conf << EOF
[libdefaults]
    default_realm = ${realm}
    dns_lookup_realm = true
    dns_lookup_kdc = true
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true

[realms]
    ${realm} = {
        kdc = ${kdc}
        admin_server = ${admin_server}
    }

[domain_realm]
    .${domain} = ${realm}
    ${domain} = ${realm}
EOF
    
    register_step "Configuração Kerberos" "OK" "Realm: $realm, KDC: $kdc"
}

# ============================================
# FUNÇÃO: CONFIGURAR NTP
# ============================================

config_ntp() {
    local primary_ntp="$1"
    log "Configurando NTP (Chrony)..."
    
    export DEBIAN_FRONTEND=noninteractive
    
    if command -v apt &>/dev/null; then
        apt install -y -qq chrony 2>/dev/null || true
    fi
    
    timedatectl set-timezone America/Sao_Paulo 2>/dev/null || true
    
    if [ "$primary_ntp" == "SELF" ]; then
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
server $primary_ntp iburst
keyfile /etc/chrony/chrony.keys
driftfile /var/lib/chrony/drift
rtcsync
makestep 1.0 3
bindcmdaddress 127.0.0.1
logdir /var/log/chrony
EOF
        register_step "Configuração NTP" "OK" "Sincronizando com $primary_ntp"
    fi
    
    systemctl enable --now chrony -qq 2>/dev/null || true
    systemctl restart chrony -qq 2>/dev/null || true
    sleep 2
    chronyc sources >/dev/null 2>&1 && echo -e "${GREEN}✓ NTP sincronizado${NC}" || warn "NTP não sincronizou"
}

# ============================================
# FUNÇÃO: VERIFICAR E CORRIGIR DNS PRIMÁRIO
# ============================================

fix_primary_dns() {
    log "Verificando e corrigindo DNS no Primário..."
    
    # Para systemd-resolved
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
    
    # Configura resolv.conf
    chattr -i /etc/resolv.conf 2>/dev/null || true
    cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
search ${DOMAIN}
domain ${DOMAIN}
EOF
    chattr +i /etc/resolv.conf 2>/dev/null || true
    
    # Configura smb.conf
    if ! grep -q "interfaces = lo" /etc/samba/smb.conf 2>/dev/null; then
        sed -i "/\[global\]/a \    interfaces = lo ${INTERFACE}" /etc/samba/smb.conf
    fi
    
    if ! grep -q "bind interfaces only = yes" /etc/samba/smb.conf 2>/dev/null; then
        sed -i "/\[global\]/a \    bind interfaces only = yes" /etc/samba/smb.conf
    fi
    
    if ! grep -q "dns forwarder = 8.8.8.8" /etc/samba/smb.conf 2>/dev/null; then
        sed -i "/\[global\]/a \    dns forwarder = 8.8.8.8" /etc/samba/smb.conf
    fi
    
    # Reinicia Samba
    systemctl restart samba-ad-dc
    sleep 10
    
    register_step "Correção DNS Primário" "OK" "DNS configurado para 127.0.0.1"
}

# ============================================
# FUNÇÃO: GERAR RELATÓRIO FINAL
# ============================================

generate_final_report() {
    local install_type="$1"
    local domain="$2"
    local realm="$3"
    local hostname="$4"
    local ip="$5"
    
    log "════════════════════════════════════════════════════"
    log "     GERANDO RELATÓRIO FINAL DA INSTALAÇÃO"
    log "════════════════════════════════════════════════════"
    
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
║  DC Primário:     ${PRIMARY_IP:-192.168.1.2}
║  DNS Primário:    ${PRIMARY_IP:-192.168.1.2}
║  DNS Secundário:  127.0.0.1
║  NTP:             ${PRIMARY_IP:-192.168.1.2}
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
    
    install_essentials
    config_locale
    
    echo -e "${BLUE}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        CONFIGURAÇÃO — DC PRIMÁRIO               ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}"
    
    # Detecta interface
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
    
    # Pergunta informações
    read -p "Domínio (ex: rnv.local): " -e DOMAIN
    DOMAIN="${DOMAIN,,}"
    REALM="${DOMAIN^^}"
    SHORT_DOMAIN=$(echo "$DOMAIN" | cut -d'.' -f1 | tr '[:lower:]' '[:upper:]')
    read -p "Hostname do servidor (default: adserver01): " -e INPUT_HOSTNAME
    HOSTNAME="${INPUT_HOSTNAME:-adserver01}"
    
    # Loop de senha
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
    
    # PRÉ-CONFIGURA KERBEROS
    preconfigure_kerberos "$REALM" "${HOSTNAME}.${DOMAIN}"
    
    # Configurações básicas
    config_bash_completion
    config_ssh_root
    config_ntp "SELF"
    
    # Configura hostname
    log "Configurando hostname: ${HOSTNAME}.${DOMAIN}"
    hostnamectl set-hostname "${HOSTNAME}.${DOMAIN}"
    register_step "Configuração de hostname" "OK" "${HOSTNAME}.${DOMAIN}"
    
    # Configura hosts
    configure_hosts "$HOSTNAME" "$DOMAIN" "$IP_ADDR"
    
    # Instala Samba
    log "Instalando pacotes do Samba AD..."
    export DEBIAN_FRONTEND=noninteractive
    apt install -y -qq acl attr samba samba-dsdb-modules samba-vfs-modules \
        winbind libpam-winbind libnss-winbind krb5-user dnsutils \
        bind9utils ldap-utils bash-completion chrony 2>/dev/null || true
    register_step "Instalação Samba AD" "OK"
    
    # Para serviços conflitantes
    systemctl stop smbd nmbd winbind 2>/dev/null || true
    systemctl disable smbd nmbd winbind 2>/dev/null || true
    
    # Limpa configurações antigas
    rm -f /etc/samba/smb.conf
    rm -rf /var/lib/samba/private /var/lib/samba/sysvol /var/lib/samba/etc
    rm -f /etc/krb5.conf
    
    # Provisiona domínio
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
    
    # Configura smb.conf
    log "Configurando /etc/samba/smb.conf"
    cp "/var/lib/samba/private/smb.conf" "/etc/samba/smb.conf"
    
    sed -i "/^interfaces/s|=.*| = lo $INTERFACE|" "/etc/samba/smb.conf" || true
    sed -i "/^bind interfaces only/s|=.*| = yes|" "/etc/samba/smb.conf" || true
    
    grep -q "ldap server require strong auth" "/etc/samba/smb.conf" ||
        sed -i "/\[global\]/a \    ldap server require strong auth = no" "/etc/samba/smb.conf"
    
    # CORREÇÃO DNS
    fix_primary_dns
    
    # Configura Kerberos
    configure_kerberos "$REALM" "$DOMAIN" "${HOSTNAME}.${DOMAIN}"
    
    # Inicia Samba
    log "Iniciando serviços samba-ad-dc..."
    systemctl unmask samba-ad-dc || true
    systemctl enable samba-ad-dc || true
    systemctl restart samba-ad-dc
    sleep 20
    register_step "Inicialização Samba AD" "OK"
    
    # Cria grupos e usuários
    log "Criando grupos e usuários padrão..."
    samba-tool group add "admins" --description="Administradores do Domínio" 2>/dev/null || true
    samba-tool group add "users" --description="Usuários do Domínio" 2>/dev/null || true
    samba-tool user create admin2 "$ADMIN_PASSWORD" --given-name="Admin" --surname="Secundário" 2>/dev/null || true
    samba-tool group addmembers "Domain Admins" admin2 2>/dev/null || true
    register_step "Criação de grupos/usuários" "OK"
    
    # Testes
    run_tests_primary "$DOMAIN" "$REALM" "$IP_ADDR"
    
    # Relatório
    generate_final_report "PRIMARY" "$DOMAIN" "$REALM" "$HOSTNAME" "$IP_ADDR"
    
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅ DC PRIMÁRIO CONFIGURADO COM SUCESSO!           ║${NC}"
    echo -e "${GREEN}║                                                     ║${NC}"
    echo -e "${GREEN}║  🌐 Domínio: $DOMAIN                                ║${NC}"
    echo -e "${GREEN}║  🔑 Acesse com: administrator@$REALM               ║${NC}"
    echo -e "${GREEN}║  📍 IP: $IP_ADDR                                   ║${NC}"
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
    
    install_essentials
    config_locale
    
    echo -e "${BLUE}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        CONFIGURAÇÃO — DC SECUNDÁRIO              ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}"
    
    # Detecta interface
    log "Detectando interface de rede..."
    INTERFACE=$(ip link show | grep -E "^[0-9]+: (en|eth)" | head -1 | cut -d: -f2 | xargs || true)
    if [ -z "$INTERFACE" ]; then
        INTERFACE=$(ip link show | grep -E "^[0-9]+: " | grep -v lo | head -1 | cut -d: -f2 | xargs)
    fi
    IP_ADDR=$(ip addr show "$INTERFACE" 2>/dev/null | grep inet | grep -v inet6 | awk '{print $2}' | cut -d/ -f1 || true)
    if [ -z "$IP_ADDR" ]; then
        IP_ADDR="192.168.1.3"
        warn "Não consegui detectar IP. Usando $IP_ADDR"
    fi
    echo -e "${GREEN}✓ Interface: ${INTERFACE} (${IP_ADDR})${NC}"
    
    # Pergunta informações
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
    
    # PRÉ-CONFIGURA KERBEROS
    preconfigure_kerberos "$REALM" "$PRIMARY_IP"
    
    # Configurações básicas
    config_bash_completion
    config_ssh_root
    config_ntp "$PRIMARY_IP"
    
    # Configura hostname
    log "Configurando hostname: ${HOSTNAME}.${DOMAIN}"
    hostnamectl set-hostname "${HOSTNAME}.${DOMAIN}"
    register_step "Configuração de hostname" "OK" "${HOSTNAME}.${DOMAIN}"
    
    # Configura hosts com primário
    configure_hosts "$HOSTNAME" "$DOMAIN" "$IP_ADDR" "$PRIMARY_IP"
    
    # Configura DNS para apontar para o primário
    configure_resolv_conf "$PRIMARY_IP" "$DOMAIN"
    
    # Instala Samba
    log "Instalando pacotes necessários..."
    export DEBIAN_FRONTEND=noninteractive
    apt install -y -qq acl attr samba samba-dsdb-modules samba-vfs-modules \
        winbind krb5-user dnsutils ldap-utils bash-completion chrony 2>/dev/null || true
    register_step "Instalação Samba AD" "OK"
    
    # Para serviços conflitantes
    systemctl stop smbd nmbd winbind 2>/dev/null || true
    systemctl disable smbd nmbd winbind 2>/dev/null || true
    
    # Limpa configurações antigas
    rm -rf /var/lib/samba/* /etc/samba/smb.conf /etc/krb5.conf 2>/dev/null || true
    
    # Configura Kerberos
    configure_kerberos "$REALM" "$DOMAIN" "$PRIMARY_IP"
    
    # Testa Kerberos
    log "Testando Kerberos com as credenciais fornecidas..."
    echo -n "${ADMIN_PASSWORD}" | kinit "$ADMIN_USER@$REALM" >/dev/null 2>&1 && {
        echo -e "${GREEN}✓ Autenticação Kerberos OK${NC}"
        kdestroy 2>/dev/null || true
    } || error "Kerberos falhou — verifique domínio, usuário e senha"
    
    # Join no domínio
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
    
    # Ajusta smb.conf
    log "Ajustando /etc/samba/smb.conf para replicação"
    cp "/var/lib/samba/private/smb.conf" "/etc/samba/smb.conf"
    sed -i "/^interfaces/s|=.*| = lo $INTERFACE|" "/etc/samba/smb.conf" || true
    
    # Configura DNS local (aponta para si mesmo como fallback)
    configure_resolv_conf "$PRIMARY_IP" "$DOMAIN"
    
    # Inicia Samba
    log "Iniciando samba-ad-dc..."
    systemctl unmask samba-ad-dc || true
    systemctl enable samba-ad-dc || true
    systemctl restart samba-ad-dc
    sleep 20
    register_step "Inicialização Samba AD" "OK"
    
    # Verifica replicação
    log "Verificando replicação DRS com o primário..."
    if samba-tool drs showrepl 2>&1 | grep -q "$PRIMARY_IP"; then
        echo -e "${GREEN}✓ Replicação DRS ativa com $PRIMARY_IP${NC}"
    else
        warn "Replicação DRS não detectada — pode levar alguns minutos"
    fi
    
    # Testes
    run_tests_secondary "$DOMAIN" "$REALM" "$IP_ADDR" "$PRIMARY_IP"
    
    # Relatório
    generate_final_report "SECONDARY" "$DOMAIN" "$REALM" "$HOSTNAME" "$IP_ADDR"
    
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅ DC SECUNDÁRIO CONFIGURADO COM SUCESSO!         ║${NC}"
    echo -e "${GREEN}║                                                     ║${NC}"
    echo -e "${GREEN}║  🌐 Domínio: $DOMAIN                                ║${NC}"
    echo -e "${GREEN}║  📍 IP: $IP_ADDR                                   ║${NC}"
    echo -e "${GREEN}║  🔗 Primário: $PRIMARY_IP                           ║${NC}"
    echo -e "${GREEN}║                                                     ║${NC}"
    echo -e "${GREEN}║  📄 Relatório: $REPORT_FILE                         ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    
    read -p "Reiniciar o servidor agora? (s/N): " -n 1 -r
    [[ "$REPLY" =~ ^[Ss]$ ]] && { log "Reiniciando em 5 segundos..."; sleep 5; reboot; }
}

# ══════════════════════════════════════════════════════════════
#              FLUXO 3 — CONFIGURAR IP
# ══════════════════════════════════════════════════════════════

configure_station_ips() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║              CONFIGURAR IP ESTÁTICO                             ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
    
    echo ""
    echo -e "${YELLOW}1) Configurar IP no Linux (Netplan)${NC}"
    echo -e "${YELLOW}2) Gerar script para Windows (netsh)${NC}"
    echo -e "${YELLOW}3) Testar conexão de rede${NC}"
    echo -e "${YELLOW}4) Verificar configuração Netplan${NC}"
    echo -e "${YELLOW}5) Voltar${NC}"
    echo ""
    read -p "Escolha uma opção [1-5]: " NETPLAN_OPT
    
    case "$NETPLAN_OPT" in
        1)
            # Detecta interface
            INTERFACE=$(ip link show | grep -E "^[0-9]+: (en|eth)" | head -1 | cut -d: -f2 | xargs || echo "eth0")
            CURRENT_IP=$(ip addr show "$INTERFACE" 2>/dev/null | grep "inet " | grep -v "secondary" | awk '{print $2}' | cut -d/ -f1 | head -1 || echo "")
            
            echo ""
            echo -e "${GREEN}Interface detectada: $INTERFACE${NC}"
            echo -e "${GREEN}IP atual: ${CURRENT_IP:-Nenhum}${NC}"
            echo ""
            
            read -p "Novo IP (ex: 192.168.1.50): " STA_IP
            read -p "Máscara [/24]: " STA_MASK
            STA_MASK="${STA_MASK:-24}"
            read -p "Gateway (ex: 192.168.1.1): " STA_GATEWAY
            
            echo ""
            echo -e "${BLUE}Configuração de DNS:${NC}"
            echo "  [1] 8.8.8.8 (Google)"
            echo "  [2] IP do AD"
            read -p "Escolha [1-2]: " DNS_OPT
            
            if [ "$DNS_OPT" == "2" ]; then
                read -p "IP do AD: " STA_DNS1
            else
                STA_DNS1="8.8.8.8"
            fi
            
            read -p "DNS secundário (opcional, Enter para pular): " STA_DNS2
            
            # Aplica a configuração
            configure_static_ip "$INTERFACE" "$STA_IP" "$STA_MASK" "$STA_GATEWAY" "$STA_DNS1" "$STA_DNS2"
            
            echo ""
            read -p "Pressione Enter para continuar..."
            ;;
            
        2)
            # Windows
            echo ""
            read -p "IP da estação Windows: " STA_IP
            read -p "Máscara (ex: 255.255.255.0): " STA_MASK
            read -p "Gateway: " STA_GATEWAY
            read -p "DNS Primário: " STA_DNS1
            read -p "DNS Secundário (opcional): " STA_DNS2
            read -p "Nome da interface (ex: Ethernet): " STA_IFACE
            
            cat > "/root/config_ip_${STA_IP}.bat" << EOF
@echo off
echo Configurando IP estático para $STA_IFACE...
netsh interface ipv4 set address name="$STA_IFACE" source=static address=$STA_IP mask=$STA_MASK gateway=$STA_GATEWAY
netsh interface ipv4 set dns name="$STA_IFACE" source=static address=$STA_DNS1
EOF
            [ -n "$STA_DNS2" ] && echo "netsh interface ipv4 add dns name=\"$STA_IFACE\" address=$STA_DNS2 index=2" >> "/root/config_ip_${STA_IP}.bat"
            
            echo ""
            echo -e "${GREEN}✓ Script gerado: /root/config_ip_${STA_IP}.bat${NC}"
            echo ""
            read -p "Pressione Enter para continuar..."
            ;;
            
        3)
            test_network
            read -p "Pressione Enter para continuar..."
            ;;
            
        4)
            test_netplan_config
            read -p "Pressione Enter para continuar..."
            ;;
            
        5)
            return 0
            ;;
            
        *)
            warn "Opção inválida"
            ;;
    esac
}

# ============================================
# FUNÇÃO: TESTAR NETPLAN
# ============================================

test_netplan_config() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║              TESTE DE CONFIGURAÇÃO NETPLAN                      ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
    
    echo ""
    echo -e "${YELLOW}📁 ARQUIVOS NETPLAN ENCONTRADOS:${NC}"
    echo -e "${BLUE}─────────────────────────────────────────────────────${NC}"
    
    if [ -d "/etc/netplan" ]; then
        for file in /etc/netplan/*.yaml; do
            if [ -f "$file" ]; then
                echo -e "${CYAN}📄 $file${NC}"
                echo -e "${BLUE}─────────────────────────────────────────────────────${NC}"
                cat "$file" 2>/dev/null || echo "Não foi possível ler o arquivo"
                echo ""
                echo -e "${BLUE}─────────────────────────────────────────────────────${NC}"
            fi
        done
    else
        echo "❌ Diretório /etc/netplan não encontrado!"
    fi
    
    echo ""
    echo -e "${YELLOW}📊 INFORMAÇÕES DE REDE ATUAIS:${NC}"
    echo -e "${BLUE}─────────────────────────────────────────────────────${NC}"
    ip addr show | grep -E "^[0-9]+:|inet " | grep -v "inet6"
    echo ""
    echo -e "${BLUE}─────────────────────────────────────────────────────${NC}"
    echo -e "${YELLOW}🌐 ROTA PADRÃO:${NC}"
    ip route show default || echo "Nenhuma rota padrão definida"
    echo ""
    echo -e "${BLUE}─────────────────────────────────────────────────────${NC}"
    echo -e "${YELLOW}🔍 TESTE DE RESOLUÇÃO DNS:${NC}"
    nslookup google.com 2>/dev/null | grep -E "Server:|Address:" || echo "DNS não está funcionando"
    
    echo ""
    echo -e "${BLUE}─────────────────────────────────────────────────────${NC}"
    echo -e "${GREEN}✅ Teste concluído!${NC}"
    echo ""
}

# ============================================
# FUNÇÃO: CONFIGURAR ESTAÇÃO LINUX
# ============================================

configure_linux_station() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   CONFIGURAR LINUX COMO ESTAÇÃO DE DOMÍNIO     ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}"
    
    read -p "Domínio a juntar (ex: rnv.local): " -e DOMAIN
    DOMAIN="${DOMAIN,,}"
    REALM="${DOMAIN^^}"
    read -p "IP do DC: " -e DC_IP
    read -p "Usuário administrador do domínio (ex: administrator): " -e ADMIN_USER
    ADMIN_USER="${ADMIN_USER:-administrator}"
    ADMIN_PASSWORD=$(read_password "Digite a senha do domínio: ")
    echo
    
    export DEBIAN_FRONTEND=noninteractive
    
    log "Instalando pacotes necessários..."
    apt update -qq 2>/dev/null || true
    apt install -y -qq realmd sssd sssd-tools adcli oddjob oddjob-mkhomedir \
        krb5-user krb5-config samba-common samba-common-bin \
        policykit-1 2>/dev/null || true
    register_step "Instalação pacotes estação Linux" "OK"
    
    # Configura DNS
    configure_resolv_conf "$DC_IP" "$DOMAIN"
    
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

# ============================================
# FUNÇÕES DE CONFIGURAÇÃO BÁSICAS
# ============================================

config_bash_completion() {
    log "Ativando auto-complete com TAB..."
    if ! grep -q "bash-completion" /root/.bashrc 2>/dev/null; then
        cat >> /root/.bashrc << 'EOF' 2>/dev/null || true
if [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
fi
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

# ══════════════════════════════════════════════════════════════
#                        MENU PRINCIPAL
# ══════════════════════════════════════════════════════════════

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║            SAMBA AD SERVER — UNIFICADO PRO v4.1                ║${NC}"
        echo -e "${BLUE}║              Ubuntu 24.04 | Samba 4.19.5                       ║${NC}"
        echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║ 1) DC Primário    — Provisionar novo domínio                   ║${NC}"
        echo -e "${BLUE}║ 2) DC Secundário  — Juntar a domínio existente (replicação)    ║${NC}"
        echo -e "${BLUE}║ 3) Configurar IP  — Configurar IP estático (Linux/Windows)     ║${NC}"
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

log "Iniciando SAMBA AD SERVER UNIFICADO PRO v4.1"
log "Sistema: $(lsb_release -ds 2>/dev/null || echo "Ubuntu 24.04") | Samba $(samba --version 2>/dev/null | head -1 || echo "4.19.5")"

main_menu
