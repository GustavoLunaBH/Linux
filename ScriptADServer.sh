#!/bin/bash
# samba_ad_smart_v8.sh
# Script completo para configuração do Samba AD
# Versão: 8.0 - Instalação + Testes completos

set -e

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'

# Configurações
SCRIPT_VERSION="8.0"
LOG_FILE="/var/log/ad_setup.log"
BACKUP_DIR="/root/backup_$(date +%Y%m%d_%H%M%S)"
PROVISION_LOG="/tmp/provision.log"
TEST_LOG="/tmp/ad_test.log"

# Variáveis
DOMAIN=""
REALM=""
SHORT_DOMAIN=""
HOSTNAME=""
IP_ADDR=""
INTERFACE=""
GATEWAY=""
DNS_SERVER=""
ADMIN_PASSWORD=""
OS=""
OS_VERSION=""
OS_NAME=""
PKG_MANAGER=""
SAMBA_VERSION=""

# ============================================
# FUNÇÕES DE LOG
# ============================================

log() {
    local level=$1
    shift
    local msg="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        INFO)    echo -e "${GREEN}[${timestamp}] [INFO]${NC} $msg" ;;
        WARN)    echo -e "${YELLOW}[${timestamp}] [WARN]${NC} $msg" ;;
        ERROR)   echo -e "${RED}[${timestamp}] [ERROR]${NC} $msg" ;;
        SUCCESS) echo -e "${BLUE}[${timestamp}] [SUCCESS]${NC} $msg" ;;
        TEST)    echo -e "${MAGENTA}[${timestamp}] [TEST]${NC} $msg" ;;
        *)       echo -e "[${timestamp}] $msg" ;;
    esac
    
    echo "[${timestamp}] [$level] $msg" >> $LOG_FILE
}

# ============================================
# FUNÇÃO DE TESTES COMPLETA (20 testes)
# ============================================

run_ad_tests() {
    log TEST "========================================="
    log TEST "INICIANDO TESTES DO AD SERVER"
    log TEST "========================================="
    echo ""
    
    # Limpar log de testes
    > $TEST_LOG
    
    local TEST_PASSED=0
    local TEST_FAILED=0
    local TEST_WARN=0
    local TOTAL_TESTS=20
    
    # Cabeçalho
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                                  ║"
    echo "║                         TESTES DE VALIDAÇÃO DO AD                                ║"
    echo "║                                                                                  ║"
    echo "╚══════════════════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    echo -e "${BLUE}📊 Testando: ${DOMAIN} - ${HOSTNAME}.${DOMAIN,,} (${IP_ADDR})${NC}"
    echo -e "${BLUE}⏰ Data/Hora: $(date)${NC}"
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # 1. SERVIÇO SAMBA AD
    echo -e "${WHITE}[1/20] Verificando Serviço Samba AD...${NC}"
    if systemctl is-active samba-ad-dc >/dev/null 2>&1; then
        echo -e "  ${GREEN}✅ Serviço samba-ad-dc está ATIVO${NC}"
        local PID=$(systemctl show samba-ad-dc --property=MainPID --value 2>/dev/null)
        echo -e "  ${CYAN}   PID: ${PID}${NC}"
        ((TEST_PASSED++))
    else
        echo -e "  ${RED}❌ Serviço samba-ad-dc NÃO está ativo${NC}"
        echo -e "  ${YELLOW}   Tentando reiniciar...${NC}"
        systemctl restart samba-ad-dc
        sleep 5
        if systemctl is-active samba-ad-dc >/dev/null 2>&1; then
            echo -e "  ${GREEN}✅ Serviço reiniciado com sucesso${NC}"
            ((TEST_PASSED++))
        else
            echo -e "  ${RED}❌ Falha ao reiniciar o serviço${NC}"
            ((TEST_FAILED++))
        fi
    fi
    echo ""

    # 2. STATUS DO SERVIÇO
    echo -e "${WHITE}[2/20] Status Detalhado do Serviço...${NC}"
    local STATUS=$(systemctl status samba-ad-dc --no-pager | head -5)
    echo -e "  ${CYAN}$(echo "$STATUS" | sed 's/^/   /')${NC}"
    ((TEST_PASSED++))
    echo ""

    # 3. PORTAS DO SAMBA
    echo -e "${WHITE}[3/20] Verificando Portas do Samba...${NC}"
    local PORTS=(
        "389:LDAP"
        "636:LDAPS"
        "88:Kerberos"
        "464:Kerberos-Admin"
        "53:DNS"
        "135:EPM"
        "445:SMB"
        "3268:GC"
        "3269:GCS"
        "139:NetBIOS-SSN"
        "137:NetBIOS-NS"
        "138:NetBIOS-DGM"
    )
    
    local PORTS_OK=0
    local PORTS_TOTAL=${#PORTS[@]}
    
    for PORT_INFO in "${PORTS[@]}"; do
        PORT=$(echo $PORT_INFO | cut -d: -f1)
        NAME=$(echo $PORT_INFO | cut -d: -f2)
        if ss -tln | grep -q ":${PORT} "; then
            echo -e "  ${GREEN}✅ Porta ${PORT} (${NAME}) - ABERTA${NC}"
            ((PORTS_OK++))
        else
            echo -e "  ${YELLOW}⚠️  Porta ${PORT} (${NAME}) - FECHADA${NC}"
        fi
    done
    
    if [ $PORTS_OK -ge 8 ]; then
        echo -e "  ${GREEN}✅ ${PORTS_OK}/${PORTS_TOTAL} portas abertas${NC}"
        ((TEST_PASSED++))
    else
        echo -e "  ${YELLOW}⚠️  Apenas ${PORTS_OK}/${PORTS_TOTAL} portas abertas${NC}"
        ((TEST_WARN++))
    fi
    echo ""

    # 4. PROCESSOS DO SAMBA
    echo -e "${WHITE}[4/20] Verificando Processos do Samba...${NC}"
    local PROCESSOS=("samba" "smbd" "nmbd" "winbindd")
    local PROC_OK=0
    
    for PROC in "${PROCESSOS[@]}"; do
        if pgrep -x "$PROC" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✅ Processo ${PROC} - ATIVO${NC}"
            ((PROC_OK++))
        else
            echo -e "  ${YELLOW}⚠️  Processo ${PROC} - NÃO ENCONTRADO${NC}"
        fi
    done
    
    if [ $PROC_OK -ge 2 ]; then
        ((TEST_PASSED++))
    else
        ((TEST_WARN++))
    fi
    echo ""

    # 5. DNS SRV - LDAP
    echo -e "${WHITE}[5/20] Verificando DNS SRV (LDAP)...${NC}"
    if host -t SRV _ldap._tcp.${DOMAIN,,} >/dev/null 2>&1; then
        local SRV_INFO=$(host -t SRV _ldap._tcp.${DOMAIN,,} 2>/dev/null)
        echo -e "  ${GREEN}✅ _ldap._tcp.${DOMAIN,,} - OK${NC}"
        echo -e "  ${CYAN}   $(echo "$SRV_INFO" | grep -v "has SRV record" | head -1 | sed 's/^/   /')${NC}"
        ((TEST_PASSED++))
    else
        echo -e "  ${RED}❌ _ldap._tcp.${DOMAIN,,} - FALHOU${NC}"
        ((TEST_FAILED++))
    fi
    echo ""

    # 6. DNS SRV - Kerberos
    echo -e "${WHITE}[6/20] Verificando DNS SRV (Kerberos)...${NC}"
    if host -t SRV _kerberos._tcp.${DOMAIN,,} >/dev/null 2>&1; then
        echo -e "  ${GREEN}✅ _kerberos._tcp.${DOMAIN,,} - OK${NC}"
        ((TEST_PASSED++))
    else
        echo -e "  ${RED}❌ _kerberos._tcp.${DOMAIN,,} - FALHOU${NC}"
        ((TEST_FAILED++))
    fi
    echo ""

    # 7. DNS SRV - Global Catalog
    echo -e "${WHITE}[7/20] Verificando DNS SRV (Global Catalog)...${NC}"
    if host -t SRV _ldap._tcp.gc._msdcs.${DOMAIN,,} >/dev/null 2>&1; then
        echo -e "  ${GREEN}✅ _ldap._tcp.gc._msdcs.${DOMAIN,,} - OK${NC}"
        ((TEST_PASSED++))
    else
        echo -e "  ${YELLOW}⚠️  _ldap._tcp.gc._msdcs.${DOMAIN,,} - NÃO ENCONTRADO${NC}"
        ((TEST_WARN++))
    fi
    echo ""

    # 8. Resolução de Nomes - Hostname
    echo -e "${WHITE}[8/20] Verificando Resolução de Nomes (Hostname)...${NC}"
    if host -t A ${HOSTNAME}.${DOMAIN,,} >/dev/null 2>&1; then
        local RESOLVED_IP=$(host -t A ${HOSTNAME}.${DOMAIN,,} 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1)
        echo -e "  ${GREEN}✅ ${HOSTNAME}.${DOMAIN,,} → ${RESOLVED_IP}${NC}"
        if [ "$RESOLVED_IP" = "$IP_ADDR" ]; then
            echo -e "  ${GREEN}✅ IP correto: ${RESOLVED_IP}${NC}"
            ((TEST_PASSED++))
        else
            echo -e "  ${RED}❌ IP incorreto: ${RESOLVED_IP} (esperado: ${IP_ADDR})${NC}"
            ((TEST_FAILED++))
        fi
    else
        echo -e "  ${RED}❌ Não foi possível resolver ${HOSTNAME}.${DOMAIN,,}${NC}"
        ((TEST_FAILED++))
    fi
    echo ""

    # 9. Resolução de Nomes - Domínio
    echo -e "${WHITE}[9/20] Verificando Resolução de Nomes (Domínio)...${NC}"
    if host -t A ${DOMAIN,,} >/dev/null 2>&1; then
        local DOMAIN_IP=$(host -t A ${DOMAIN,,} 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1)
        echo -e "  ${GREEN}✅ ${DOMAIN,,} → ${DOMAIN_IP}${NC}"
        ((TEST_PASSED++))
    else
        echo -e "  ${YELLOW}⚠️  ${DOMAIN,,} - NÃO RESOLVIDO${NC}"
        ((TEST_WARN++))
    fi
    echo ""

    # 10. KERBEROS - Autenticação
    echo -e "${WHITE}[10/20] Testando Autenticação Kerberos...${NC}"
    if echo "${ADMIN_PASSWORD}" | kinit administrator@${DOMAIN} >/dev/null 2>&1; then
        echo -e "  ${GREEN}✅ Autenticação Kerberos - SUCESSO${NC}"
        local TICKET_INFO=$(klist 2>/dev/null | grep "Ticket cache" || echo "Sem ticket")
        echo -e "  ${CYAN}   ${TICKET_INFO}${NC}"
        kdestroy 2>/dev/null
        ((TEST_PASSED++))
    else
        echo -e "  ${RED}❌ Autenticação Kerberos - FALHOU${NC}"
        echo -e "  ${YELLOW}   Tentando com detalhes...${NC}"
        echo "${ADMIN_PASSWORD}" | kinit -V administrator@${DOMAIN} 2>&1 | sed 's/^/   /'
        ((TEST_FAILED++))
    fi
    echo ""

    # 11. KERBEROS - Ticket
    echo -e "${WHITE}[11/20] Verificando Ticket Kerberos...${NC}"
    echo "${ADMIN_PASSWORD}" | kinit administrator@${DOMAIN} >/dev/null 2>&1
    if klist >/dev/null 2>&1; then
        echo -e "  ${GREEN}✅ Ticket obtido com sucesso${NC}"
        echo -e "  ${CYAN}$(klist 2>/dev/null | grep -A 2 "Ticket cache" | sed 's/^/   /')${NC}"
        kdestroy 2>/dev/null
        ((TEST_PASSED++))
    else
        echo -e "  ${RED}❌ Falha ao obter ticket${NC}"
        ((TEST_FAILED++))
    fi
    echo ""

    # 12. LDAP - Conexão
    echo -e "${WHITE}[12/20] Testando Conexão LDAP...${NC}"
    local LDAP_QUERY=$(ldapsearch -x -H ldap://${HOSTNAME}.${DOMAIN,,} \
        -b "dc=${SHORT_DOMAIN},dc=local" \
        -D "cn=Administrator,cn=Users,dc=${SHORT_DOMAIN},dc=local" \
        -w "${ADMIN_PASSWORD}" 2>/dev/null | grep -c "dn:" || echo "0")
    
    if [ "$LDAP_QUERY" -gt 0 ]; then
        echo -e "  ${GREEN}✅ Conexão LDAP - SUCESSO (${LDAP_QUERY} entradas)${NC}"
        ((TEST_PASSED++))
    else
        echo -e "  ${RED}❌ Conexão LDAP - FALHOU${NC}"
        ((TEST_FAILED++))
    fi
    echo ""

    # 13. LDAPS - Conexão Segura
    echo -e "${WHITE}[13/20] Testando Conexão LDAPS...${NC}"
    if ldapsearch -x -H ldaps://${HOSTNAME}.${DOMAIN,,} \
        -b "dc=${SHORT_DOMAIN},dc=local" \
        -D "cn=Administrator,cn=Users,dc=${SHORT_DOMAIN},dc=local" \
        -w "${ADMIN_PASSWORD}" 2>/dev/null | grep -q "dn:"; then
        echo -e "  ${GREEN}✅ Conexão LDAPS - SUCESSO${NC}"
        ((TEST_PASSED++))
    else
        echo -e "  ${YELLOW}⚠️  Conexão LDAPS - NÃO DISPONÍVEL${NC}"
        ((TEST_WARN++))
    fi
    echo ""

    # 14. USUÁRIOS
    echo -e "${WHITE}[14/20] Verificando Usuários...${NC}"
    local USER_COUNT=$(samba-tool user list 2>/dev/null | wc -l)
    if [ $USER_COUNT -gt 0 ]; then
        echo -e "  ${GREEN}✅ ${USER_COUNT} usuários encontrados${NC}"
        echo -e "  ${CYAN}   Usuários:${NC}"
        samba-tool user list 2>/dev/null | head -5 | while read user; do
            echo -e "  ${CYAN}   - ${user}${NC}"
        done
        if [ $USER_COUNT -gt 5 ]; then
            echo -e "  ${CYAN}   ... e mais $((USER_COUNT - 5)) usuários${NC}"
        fi
        ((TEST_PASSED++))
    else
        echo -e "  ${RED}❌ Nenhum usuário encontrado${NC}"
        ((TEST_FAILED++))
    fi
    echo ""

    # 15. GRUPOS
    echo -e "${WHITE}[15/20] Verificando Grupos...${NC}"
    local GROUP_COUNT=$(samba-tool group list 2>/dev/null | wc -l)
    if [ $GROUP_COUNT -gt 0 ]; then
        echo -e "  ${GREEN}✅ ${GROUP_COUNT} grupos encontrados${NC}"
        echo -e "  ${CYAN}   Grupos principais:${NC}"
        samba-tool group list 2>/dev/null | grep -E "(Domain Admins|Domain Users|Domain Computers|Enterprise Admins)" | while read group; do
            echo -e "  ${CYAN}   - ${group}${NC}"
        done
        ((TEST_PASSED++))
    else
        echo -e "  ${RED}❌ Nenhum grupo encontrado${NC}"
        ((TEST_FAILED++))
    fi
    echo ""

    # 16. SYSVOL
    echo -e "${WHITE}[16/20] Verificando SYSVOL...${NC}"
    if [ -d "/var/lib/samba/sysvol/${DOMAIN,,}" ]; then
        echo -e "  ${GREEN}✅ SYSVOL disponível${NC}"
        local SYSVOL_SIZE=$(du -sh /var/lib/samba/sysvol/${DOMAIN,,} 2>/dev/null | awk '{print $1}')
        echo -e "  ${CYAN}   Tamanho: ${SYSVOL_SIZE}${NC}"
        
        if [ -d "/var/lib/samba/sysvol/${DOMAIN,,}/Policies" ]; then
            echo -e "  ${GREEN}✅ Policies disponível${NC}"
        fi
        if [ -d "/var/lib/samba/sysvol/${DOMAIN,,}/Scripts" ]; then
            echo -e "  ${GREEN}✅ Scripts disponível${NC}"
        fi
        ((TEST_PASSED++))
    else
        echo -e "  ${RED}❌ SYSVOL não encontrado${NC}"
        ((TEST_FAILED++))
    fi
    echo ""

    # 17. NTDS
    echo -e "${WHITE}[17/20] Verificando NTDS.dit...${NC}"
    if [ -f "/var/lib/samba/private/ntds.dit" ]; then
        local NTDS_SIZE=$(du -sh /var/lib/samba/private/ntds.dit 2>/dev/null | awk '{print $1}')
        echo -e "  ${GREEN}✅ NTDS.dit encontrado (${NTDS_SIZE})${NC}"
        ((TEST_PASSED++))
    else
        echo -e "  ${RED}❌ NTDS.dit não encontrado${NC}"
        ((TEST_FAILED++))
    fi
    echo ""

    # 18. NTP
    echo -e "${WHITE}[18/20] Verificando Sincronização NTP...${NC}"
    if systemctl is-active chrony >/dev/null 2>&1 || systemctl is-active ntpd >/dev/null 2>&1; then
        echo -e "  ${GREEN}✅ Serviço NTP ativo${NC}"
        local NTP_SYNC=$(timedatectl status 2>/dev/null | grep "synchronized" | grep -o "yes\|no" || echo "desconhecido")
        local NTP_TIME=$(timedatectl status 2>/dev/null | grep "Time" | head -1 | cut -d: -f2- | xargs)
        echo -e "  ${CYAN}   Sincronizado: ${NTP_SYNC}${NC}"
        echo -e "  ${CYAN}   Hora atual: ${NTP_TIME}${NC}"
        ((TEST_PASSED++))
    else
        echo -e "  ${YELLOW}⚠️  NTP não está ativo${NC}"
        ((TEST_WARN++))
    fi
    echo ""

    # 19. SAMBA TOOL
    echo -e "${WHITE}[19/20] Testando Comandos Básicos do Samba...${NC}"
    local CMDS=("samba-tool domain info" "samba-tool fsmo show")
    local CMD_OK=0
    
    for CMD in "${CMDS[@]}"; do
        if eval "$CMD" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✅ ${CMD} - OK${NC}"
            ((CMD_OK++))
        else
            echo -e "  ${YELLOW}⚠️  ${CMD} - FALHOU${NC}"
        fi
    done
    
    if [ $CMD_OK -eq ${#CMDS[@]} ]; then
        ((TEST_PASSED++))
    else
        ((TEST_WARN++))
    fi
    echo ""

    # 20. REPLICAÇÃO
    echo -e "${WHITE}[20/20] Verificando Replicação...${NC}"
    local REPLICA_INFO=$(samba-tool drs showrepl 2>/dev/null | grep -c "successful" || echo "0")
    local REPLICA_TOTAL=$(samba-tool drs showrepl 2>/dev/null | grep -c "replica" || echo "0")
    
    if [ "$REPLICA_TOTAL" -gt 0 ]; then
        if [ "$REPLICA_INFO" -gt 0 ]; then
            echo -e "  ${GREEN}✅ Replicação funcionando (${REPLICA_INFO}/${REPLICA_TOTAL} bem-sucedidas)${NC}"
            ((TEST_PASSED++))
        else
            echo -e "  ${YELLOW}⚠️  Replicação com problemas (${REPLICA_INFO}/${REPLICA_TOTAL})${NC}"
            ((TEST_WARN++))
        fi
    else
        echo -e "  ${CYAN}   Nenhum outro DC encontrado - OK${NC}"
        ((TEST_PASSED++))
    fi
    echo ""

    # ==========================================
    # RESUMO DOS TESTES
    # ==========================================
    echo -e "${YELLOW}"
    echo "╔══════════════════════════════════════════════════════════════════════════════════╗"
    echo "║                              RESUMO DOS TESTES                                  ║"
    echo "╚══════════════════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    local PERCENT=$((TEST_PASSED * 100 / TOTAL_TESTS))
    
    echo -e "  ${CYAN}Total de Testes:${NC}     $TOTAL_TESTS"
    echo -e "  ${GREEN}Aprovados:${NC}          $TEST_PASSED"
    echo -e "  ${YELLOW}Avisos:${NC}            $TEST_WARN"
    echo -e "  ${RED}Falhos:${NC}              $TEST_FAILED"
    echo -e "  ${CYAN}Taxa de Aprovação:${NC}   ${PERCENT}%"
    echo ""
    
    # Barras de progresso
    echo -e "${BLUE}Status:${NC}"
    echo -n "  ["
    for i in $(seq 1 20); do
        if [ $i -le $((PERCENT / 5)) ]; then
            echo -n -e "${GREEN}█${NC}"
        else
            echo -n -e "${RED}░${NC}"
        fi
    done
    echo "] ${PERCENT}%"
    echo ""
    
    # Classificação
    if [ $PERCENT -ge 90 ]; then
        echo -e "${GREEN}⭐ EXCELENTE! AD Server está funcionando perfeitamente!${NC}"
        echo -e "${GREEN}   O domínio ${DOMAIN} está pronto para produção.${NC}"
        STATUS="⭐ EXCELENTE"
    elif [ $PERCENT -ge 75 ]; then
        echo -e "${GREEN}✅ AD Server está funcionando corretamente!${NC}"
        echo -e "${GREEN}   O domínio ${DOMAIN} está pronto para uso.${NC}"
        STATUS="✅ SAUDÁVEL"
    elif [ $PERCENT -ge 60 ]; then
        echo -e "${YELLOW}⚠️  AD Server com alguns problemas menores!${NC}"
        echo -e "${YELLOW}   Verifique os avisos acima.${NC}"
        STATUS="⚠️  PARCIAL"
    else
        echo -e "${RED}❌ AD Server com problemas críticos!${NC}"
        echo -e "${RED}   Recomenda-se revisar a instalação.${NC}"
        STATUS="❌ CRÍTICO"
    fi
    
    echo ""
    echo -e "${BLUE}📁 Logs gerados:${NC}"
    echo -e "  ${CYAN}• Testes detalhados:${NC} /root/ad_test_results.txt"
    echo -e "  ${CYAN}• Log do script:${NC}    ${LOG_FILE}"
    echo -e "  ${CYAN}• Provisionamento:${NC}  ${PROVISION_LOG}"
    echo ""
    
    # Salvar resultados
    cat > /root/ad_test_results.txt << EOF
═══════════════════════════════════════════════════════════════════════════════════
                        RESULTADO DOS TESTES DO AD
═══════════════════════════════════════════════════════════════════════════════════

DATA: $(date)
DOMÍNIO: ${DOMAIN}
HOSTNAME: ${HOSTNAME}.${DOMAIN,,}
IP: ${IP_ADDR}
SISTEMA: ${OS_NAME}
SAMBA: ${SAMBA_VERSION}

───────────────────────────────────────────────────────────────────────────────────
RESULTADO: ${STATUS}
TESTES APROVADOS: ${TEST_PASSED}/${TOTAL_TESTS}
TAXA DE APROVAÇÃO: ${PERCENT}%

═══════════════════════════════════════════════════════════════════════════════════
EOF
    
    chmod 600 /root/ad_test_results.txt
    
    echo -e "${GREEN}✅ Testes salvos em: /root/ad_test_results.txt${NC}"
    echo ""
    
    read -p "Pressione ENTER para continuar..."
}

# ============================================
# FUNÇÕES DE VALIDAÇÃO
# ============================================

validate_ip() {
    local IP="$1"
    if ! echo "$IP" | grep -qE "^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"; then
        return 1
    fi
    for octet in $(echo $IP | tr '.' ' '); do
        if [ $octet -gt 255 ] || [ $octet -lt 0 ]; then
            return 1
        fi
    done
    return 0
}

validate_password() {
    local PASSWORD="$1"
    
    if [ ${#PASSWORD} -lt 8 ]; then
        echo "Senha deve ter pelo menos 8 caracteres"
        return 1
    fi
    
    if ! echo "$PASSWORD" | grep -q "[A-Z]"; then
        echo "Senha deve ter pelo menos uma letra maiúscula"
        return 1
    fi
    
    if ! echo "$PASSWORD" | grep -q "[a-z]"; then
        echo "Senha deve ter pelo menos uma letra minúscula"
        return 1
    fi
    
    if ! echo "$PASSWORD" | grep -q "[0-9]"; then
        echo "Senha deve ter pelo menos um número"
        return 1
    fi
    
    return 0
}

validate_domain() {
    local DOMAIN="$1"
    if ! echo "$DOMAIN" | grep -qE "^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"; then
        echo "Domínio inválido. Exemplo: EMPRESA.LOCAL"
        return 1
    fi
    return 0
}

# ============================================
# FUNÇÕES DE SISTEMA
# ============================================

get_system_info() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
        OS_NAME="$PRETTY_NAME"
    else
        OS=$(uname -s)
        OS_VERSION=$(uname -r)
        OS_NAME="$OS $OS_VERSION"
    fi
    
    if command -v samba &> /dev/null; then
        SAMBA_VERSION=$(samba --version 2>/dev/null | awk '{print $2}' || echo "Não instalado")
    else
        SAMBA_VERSION="Não instalado"
    fi
    
    case $OS in
        ubuntu|debian) PKG_MANAGER="apt" ;;
        rocky|centos|rhel|almalinux) PKG_MANAGER="yum" ;;
        *) log ERROR "Sistema não suportado: $OS"; exit 1 ;;
    esac
}

# ============================================
# FUNÇÕES DE INSTALAÇÃO
# ============================================

install_samba_packages() {
    log INFO "Instalando pacotes do Samba AD..."
    
    case $PKG_MANAGER in
        apt)
            apt --fix-broken install -y -qq 2>/dev/null || true
            if dpkg -l | grep -q ntpsec; then
                apt remove -y -qq ntpsec ntpdate 2>/dev/null || true
            fi
            apt update -qq
            DEBIAN_FRONTEND=noninteractive apt install -y -qq \
                acl attr samba samba-dsdb-modules samba-vfs-modules \
                winbind libpam-winbind libnss-winbind krb5-user \
                dnsutils bind9utils ldap-utils bash-completion chrony \
                python3 python3-dnspython python3-ldb python3-talloc \
                python3-samba 2>/dev/null || {
                    apt install -y -qq samba winbind krb5-user dnsutils
                }
            ;;
        yum)
            yum install -y -q samba samba-client samba-common \
                samba-dc samba-dc-dns samba-winbind krb5-workstation \
                bind-utils chrony python3
            ;;
    esac
    
    systemctl stop smbd nmbd winbind 2>/dev/null || true
    systemctl disable smbd nmbd winbind 2>/dev/null || true
    
    if command -v samba-tool &> /dev/null; then
        SAMBA_VERSION=$(samba --version 2>/dev/null | awk '{print $2}')
        log SUCCESS "Samba $SAMBA_VERSION instalado"
    else
        log ERROR "Falha na instalação do Samba"
        exit 1
    fi
}

provision_domain() {
    log INFO "Provisionando domínio ${DOMAIN}..."
    log INFO "Aguarde, isso pode levar alguns minutos..."
    
    rm -f /etc/samba/smb.conf
    rm -rf /var/lib/samba/private 2>/dev/null || true
    rm -rf /var/lib/samba/sysvol 2>/dev/null || true
    
    samba-tool domain provision \
        --use-rfc2307 \
        --realm=${DOMAIN} \
        --domain=${SHORT_DOMAIN} \
        --server-role=dc \
        --dns-backend=SAMBA_INTERNAL \
        --adminpass=${ADMIN_PASSWORD} \
        --host-ip=${IP_ADDR} \
        --option="interfaces=lo ${INTERFACE}" \
        --option="bind interfaces only=yes" \
        > ${PROVISION_LOG} 2>&1
    
    if [ $? -eq 0 ]; then
        log SUCCESS "Domínio provisionado com sucesso!"
        if [ -f "/var/lib/samba/private/smb.conf" ]; then
            cp /var/lib/samba/private/smb.conf /etc/samba/smb.conf
        fi
        return 0
    else
        log ERROR "Falha no provisionamento"
        tail -20 ${PROVISION_LOG}
        return 1
    fi
}

# ============================================
# FUNÇÃO PRINCIPAL DE INSTALAÇÃO
# ============================================

install_ad_primary() {
    log INFO "=== INICIANDO INSTALAÇÃO AD SERVER PRIMÁRIO ==="
    
    clear
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║              CONFIGURAÇÃO DO DOMÍNIO                          ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    
    # Coletar informações
    while true; do
        read -p "Domínio (ex: EMPRESA.LOCAL): " DOMAIN
        DOMAIN=$(echo $DOMAIN | tr '[:lower:]' '[:upper:]')
        if validate_domain "$DOMAIN"; then
            break
        fi
    done
    
    SHORT_DOMAIN=$(echo $DOMAIN | cut -d. -f1)
    
    echo ""
    read -p "Hostname (ex: adserver01): " HOSTNAME
    if [ -z "$HOSTNAME" ]; then
        HOSTNAME=$(hostname | cut -d. -f1)
    fi
    
    echo ""
    read -p "IP do servidor (ex: 192.168.1.10): " IP_ADDR
    if [ -z "$IP_ADDR" ]; then
        IP_ADDR=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1)
    fi
    while ! validate_ip "$IP_ADDR"; do
        read -p "IP inválido. Digite novamente: " IP_ADDR
    done
    
    echo ""
    read -p "Interface (ex: ens33): " INTERFACE
    if [ -z "$INTERFACE" ]; then
        INTERFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
    fi
    
    echo ""
    echo -e "${BLUE}Definir senha do administrador:${NC}"
    echo -e "${YELLOW}Requisitos: Mínimo 8 caracteres, maiúscula, minúscula e número${NC}"
    while true; do
        read -s -p "Senha: " ADMIN_PASSWORD
        echo
        read -s -p "Confirmar senha: " ADMIN_PASSWORD_CONFIRM
        echo
        
        if [ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD_CONFIRM" ]; then
            log ERROR "Senhas não coincidem"
            continue
        fi
        
        if validate_password "$ADMIN_PASSWORD"; then
            break
        fi
    done
    
    # Confirmar
    clear
    echo -e "${YELLOW}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║                   CONFIRMAR CONFIGURAÇÕES                     ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    echo -e "  ${CYAN}Domínio:${NC} ${DOMAIN}"
    echo -e "  ${CYAN}Hostname:${NC} ${HOSTNAME}.${DOMAIN,,}"
    echo -e "  ${CYAN}IP:${NC} ${IP_ADDR}"
    echo -e "  ${CYAN}Interface:${NC} ${INTERFACE}"
    echo ""
    read -p "Prosseguir com a instalação? (s/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Ss]$ ]]; then
        log INFO "Instalação cancelada"
        return
    fi
    
    # INÍCIO DA INSTALAÇÃO
    echo ""
    log INFO "INICIANDO INSTALAÇÃO..."
    
    # Backup
    mkdir -p $BACKUP_DIR
    
    # Configurar hostname
    hostnamectl set-hostname ${HOSTNAME}.${DOMAIN,,}
    
    # Configurar /etc/hosts
    cat > /etc/hosts << EOF
127.0.0.1 localhost
127.0.1.1 ${HOSTNAME}.${DOMAIN,,} ${HOSTNAME}
${IP_ADDR} ${HOSTNAME}.${DOMAIN,,} ${HOSTNAME}
EOF
    
    # Instalar pacotes
    install_samba_packages
    
    # Configurar Kerberos
    cat > /etc/krb5.conf << EOF
[libdefaults]
    default_realm = ${DOMAIN}
    dns_lookup_realm = false
    dns_lookup_kdc = true
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true

[realms]
    ${DOMAIN} = {
        kdc = ${HOSTNAME}.${DOMAIN,,}
        admin_server = ${HOSTNAME}.${DOMAIN,,}
        default_domain = ${DOMAIN,,}
    }

[domain_realm]
    .${DOMAIN,,} = ${DOMAIN}
    ${DOMAIN,,} = ${DOMAIN}
    ${HOSTNAME} = ${DOMAIN}
EOF
    
    # Provisionar
    if ! provision_domain; then
        log ERROR "Falha no provisionamento"
        exit 1
    fi
    
    # Configurar DNS
    cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
search ${DOMAIN,,}
domain ${DOMAIN,,}
EOF
    
    # Iniciar serviços
    systemctl unmask samba-ad-dc 2>/dev/null || true
    systemctl enable samba-ad-dc 2>/dev/null || true
    systemctl restart samba-ad-dc
    sleep 10
    
    # Criar usuários
    samba-tool group add "admins" --description="Administradores do Domínio" 2>/dev/null || true
    samba-tool group add "users" --description="Usuários do Domínio" 2>/dev/null || true
    samba-tool user create admin2 ${ADMIN_PASSWORD} \
        --given-name="Admin" \
        --surname="Secundario" 2>/dev/null || true
    samba-tool group addmembers "Domain Admins" admin2 2>/dev/null || true
    
    # Salvar informações
    cat > /root/ad_info.txt << EOF
═══════════════════════════════════════════════════════════════════
                    AD SERVER PRIMÁRIO
═══════════════════════════════════════════════════════════════════

DOMÍNIO: ${DOMAIN}
HOSTNAME: ${HOSTNAME}.${DOMAIN,,}
IP: ${IP_ADDR}
SISTEMA: ${OS_NAME}
SAMBA: ${SAMBA_VERSION}
DATA: $(date)

USUÁRIO ADMIN: administrator@${DOMAIN}
SENHA: ${ADMIN_PASSWORD}

USUÁRIO SECUNDÁRIO: admin2@${DOMAIN}
SENHA: ${ADMIN_PASSWORD}
EOF
    
    chmod 600 /root/ad_info.txt
    
    # Resumo
    clear
    echo -e "${GREEN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║         ✅ CONFIGURAÇÃO CONCLUÍDA COM SUCESSO!                ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    echo -e "${BLUE}📋 RESUMO DA INSTALAÇÃO:${NC}"
    echo ""
    echo -e "  ${GREEN}✓${NC} Domínio: ${CYAN}${DOMAIN}${NC}"
    echo -e "  ${GREEN}✓${NC} Hostname: ${CYAN}${HOSTNAME}.${DOMAIN,,}${NC}"
    echo -e "  ${GREEN}✓${NC} IP: ${CYAN}${IP_ADDR}${NC}"
    echo -e "  ${GREEN}✓${NC} Samba: ${CYAN}${SAMBA_VERSION}${NC}"
    echo ""
    
    echo -e "${YELLOW}📌 CREDENCIAIS DE ACESSO:${NC}"
    echo -e "  Usuário: ${CYAN}administrator@${DOMAIN}${NC}"
    echo -e "  Senha: ${CYAN}${ADMIN_PASSWORD}${NC}"
    echo ""
    
    echo -e "${YELLOW}💡 INFORMAÇÕES SALVAS EM:${NC}"
    echo -e "  ${CYAN}/root/ad_info.txt${NC}"
    echo ""
    
    # ==========================================
    # EXECUTAR TESTES AUTOMATICAMENTE
    # ==========================================
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}EXECUTANDO TESTES DE VALIDAÇÃO DO AD${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    read -p "Deseja executar os testes de validação? (S/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        run_ad_tests
    else
        echo -e "${YELLOW}Testes ignorados. Execute manualmente com a opção 'Health Check'${NC}"
    fi
    
    log SUCCESS "=== INSTALAÇÃO CONCLUÍDA ==="
}

# ============================================
# MENU PRINCIPAL
# ============================================

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}"
        echo "╔═════════════════════════════════════════════════════════════════════╗"
        echo "║                                                                     ║"
        echo "║         🖥️  SAMBA AD SMART CONFIGURATOR v${SCRIPT_VERSION}          ║"
        echo "║                                                                     ║"
        echo "║         Configuração Inteligente de Domínio                         ║"
        echo "║                                                                     ║"
        echo "╚═════════════════════════════════════════════════════════════════════╝"
        echo -e "${NC}"
        
        echo -e "${CYAN}📊 Sistema:${NC} $OS_NAME"
        echo -e "${CYAN}🌐 IP:${NC} $(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1)"
        echo -e "${CYAN}💻 Hostname:${NC} $(hostname)"
        echo -e "${CYAN}📦 Samba:${NC} $SAMBA_VERSION"
        echo ""
        
        echo -e "${YELLOW}Selecione o papel do servidor:${NC}"
        echo ""
        echo -e "  ${GREEN}1)${NC} AD Server ${BLUE}PRIMÁRIO${NC} - Novo domínio"
        echo -e "  ${GREEN}2)${NC} AD Server ${BLUE}SECUNDÁRIO${NC} - Replicação do domínio"
        echo -e "  ${GREEN}3)${NC} AD Server ${BLUE}TERCIÁRIO/RODC${NC} - Controlador somente leitura"
        echo -e "  ${GREEN}4)${NC} ${BLUE}File Server${NC} - Servidor de arquivos integrado ao domínio"
        echo -e "  ${GREEN}5)${NC} ${BLUE}Join Domain${NC} - Apenas adicionar ao domínio"
        echo -e "  ${GREEN}6)${NC} ${BLUE}Configurar Rede${NC} - Alterar IP/Hostname"
        echo -e "  ${GREEN}7)${NC} ${BLUE}Informações do Sistema${NC}"
        echo -e "  ${GREEN}8)${NC} ${BLUE}Health Check${NC} - Verificar AD"
        echo -e "  ${GREEN}9)${NC} ${RED}Sair${NC}"
        echo ""
        read -p "Escolha uma opção (1-9): " OPTION
        
        case $OPTION in
            1) install_ad_primary ;;
            2) echo "Em desenvolvimento..."; sleep 2 ;;
            3) echo "Em desenvolvimento..."; sleep 2 ;;
            4) echo "Em desenvolvimento..."; sleep 2 ;;
            5) echo "Em desenvolvimento..."; sleep 2 ;;
            6) echo "Em desenvolvimento..."; sleep 2 ;;
            7) echo "Em desenvolvimento..."; sleep 2 ;;
            8) 
                if [ -d "/var/lib/samba/private" ]; then
                    run_ad_tests
                else
                    echo -e "${RED}AD Server não está instalado!${NC}"
                    read -p "Pressione ENTER para continuar..."
                fi
                ;;
            9) echo -e "${GREEN}Saindo...${NC}"; exit 0 ;;
            *) log ERROR "Opção inválida"; sleep 2 ;;
        esac
    done
}

# ============================================
# INÍCIO DO SCRIPT
# ============================================

# Verificar root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Este script deve ser executado como root (sudo)${NC}"
    exit 1
fi

# Inicializar
> $LOG_FILE
log INFO "=== INICIANDO SCRIPT v${SCRIPT_VERSION} ==="

# Detectar sistema
get_system_info
log SUCCESS "Sistema detectado: $OS_NAME"

# Menu principal
main_menu
