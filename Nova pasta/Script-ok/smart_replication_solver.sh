#!/bin/bash
# smart_replication_solver.sh
# Script inteligente que diagnostica e resolve problemas de replicação
# Versão: 3.0 - Unificado e Inteligente

set -e

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================
# CONFIGURAÇÕES
# ============================================
DOMAIN="RNV.INTRA"
REALM="RNV.INTRA"
SHORT_DOMAIN="RNV"
PRIMARY_IP="192.168.1.2"
PRIMARY_HOST="adserver01"
SECONDARY_IP="192.168.1.3"
SECONDARY_HOST="adserver02"
LOG_FILE="/var/log/smart_replication_solver.log"
WORK_DIR="/tmp/replication_fix_$$"

# ============================================
# FUNÇÕES
# ============================================
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a $LOG_FILE
}

error() {
    echo -e "${RED}[ERRO]${NC} $1" | tee -a $LOG_FILE
    exit 1
}

warning() {
    echo -e "${YELLOW}[AVISO]${NC} $1" | tee -a $LOG_FILE
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a $LOG_FILE
}

success() {
    echo -e "${GREEN}[SUCESSO]${NC} $1" | tee -a $LOG_FILE
}

header() {
    echo -e "${MAGENTA}"
    echo "╔═══════════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                           ║"
    echo "║     🧠 SOLVER INTELIGENTE - REPLICAÇÃO SAMBA AD                         ║"
    echo "║                                                                           ║"
    echo "║     Domínio: ${DOMAIN}                                                    ║"
    echo "║     Primário: ${PRIMARY_HOST} (${PRIMARY_IP})                            ║"
    echo "║     Secundário: ${SECONDARY_HOST} (${SECONDARY_IP})                      ║"
    echo "║                                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ============================================
# PRÉ-VERIFICAÇÃO
# ============================================
pre_checks() {
    log "═══════════════════════════════════════════════════════════════════════════"
    log "1. PRÉ-VERIFICAÇÃO"
    log "═══════════════════════════════════════════════════════════════════════════"
    
    # Verificar se é root
    if [[ $EUID -ne 0 ]]; then
        error "Este script deve ser executado como root (sudo)"
    fi
    
    # Identificar servidor atual
    CURRENT_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -1)
    CURRENT_HOSTNAME=$(hostname -s)
    
    info "IP atual: $CURRENT_IP"
    info "Hostname: $CURRENT_HOSTNAME"
    
    # Determinar tipo de servidor
    if [[ "$CURRENT_IP" == "$PRIMARY_IP" ]] || [[ "$CURRENT_HOSTNAME" == "$PRIMARY_HOST" ]]; then
        SERVER_TYPE="PRIMARY"
        OTHER_IP="$SECONDARY_IP"
        OTHER_HOST="$SECONDARY_HOST"
        success "Este servidor é o AD PRIMÁRIO ($PRIMARY_HOST)"
    elif [[ "$CURRENT_IP" == "$SECONDARY_IP" ]] || [[ "$CURRENT_HOSTNAME" == "$SECONDARY_HOST" ]]; then
        SERVER_TYPE="SECONDARY"
        OTHER_IP="$PRIMARY_IP"
        OTHER_HOST="$PRIMARY_HOST"
        success "Este servidor é o AD SECUNDÁRIO ($SECONDARY_HOST)"
    else
        warning "Não foi possível identificar o servidor automaticamente."
        echo ""
        echo -e "${YELLOW}Qual é este servidor?${NC}"
        echo "1) AD Primário (adserver01 - 192.168.1.2)"
        echo "2) AD Secundário (adserver02 - 192.168.1.3)"
        read -p "Escolha (1/2): " SERVER_CHOICE
        
        if [ "$SERVER_CHOICE" == "1" ]; then
            SERVER_TYPE="PRIMARY"
            OTHER_IP="$SECONDARY_IP"
            OTHER_HOST="$SECONDARY_HOST"
        elif [ "$SERVER_CHOICE" == "2" ]; then
            SERVER_TYPE="SECONDARY"
            OTHER_IP="$PRIMARY_IP"
            OTHER_HOST="$PRIMARY_HOST"
        else
            error "Opção inválida"
        fi
    fi
    
    # Criar diretório de trabalho
    mkdir -p $WORK_DIR
    info "Diretório de trabalho: $WORK_DIR"
}

# ============================================
# SOLICITAR SENHA
# ============================================
get_password() {
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}Digite a senha do administrador do domínio:${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    read -s -p "> " ADMIN_PASSWORD
    echo ""
    
    if [ -z "$ADMIN_PASSWORD" ]; then
        error "Senha não pode ser vazia"
    fi
    
    export ADMIN_PASSWORD
}

# ============================================
# DIAGNÓSTICO - Verificar status da replicação
# ============================================
diagnose_replication() {
    log "═══════════════════════════════════════════════════════════════════════════"
    log "2. DIAGNÓSTICO DA REPLICAÇÃO"
    log "═══════════════════════════════════════════════════════════════════════════"
    
    DIAGNOSTIC_RESULT=""
    
    # Teste 1: Verificar Kerberos
    log "Testando Kerberos..."
    if echo "$ADMIN_PASSWORD" | kinit administrator@${REALM} > /dev/null 2>&1; then
        success "✅ Kerberos funcionando"
        KERBEROS_OK=1
    else
        warning "❌ Kerberos falhou"
        KERBEROS_OK=0
        DIAGNOSTIC_RESULT="${DIAGNOSTIC_RESULT}KERBEROS_FAIL;"
    fi
    
    # Teste 2: Verificar DNS
    log "Testando DNS..."
    if host -t SRV _ldap._tcp.${DOMAIN,,} > /dev/null 2>&1; then
        success "✅ DNS SRV OK"
        DNS_OK=1
    else
        warning "❌ DNS SRV falhou"
        DNS_OK=0
        DIAGNOSTIC_RESULT="${DIAGNOSTIC_RESULT}DNS_FAIL;"
    fi
    
    # Teste 3: Verificar se o outro servidor está acessível
    log "Testando conectividade com $OTHER_HOST..."
    if ping -c 2 -W 2 $OTHER_IP > /dev/null 2>&1; then
        success "✅ $OTHER_HOST acessível"
        CONNECT_OK=1
    else
        warning "❌ $OTHER_HOST inacessível"
        CONNECT_OK=0
        DIAGNOSTIC_RESULT="${DIAGNOSTIC_RESULT}CONNECT_FAIL;"
    fi
    
    # Teste 4: Verificar status da replicação
    log "Verificando status da replicação..."
    REPL_STATUS=$(samba-tool drs showrepl 2>&1)
    
    if echo "$REPL_STATUS" | grep -q "successful"; then
        success "✅ Replicação está funcionando"
        REPL_OK=1
    else
        warning "❌ Replicação com problemas"
        REPL_OK=0
        DIAGNOSTIC_RESULT="${DIAGNOSTIC_RESULT}REPL_FAIL;"
    fi
    
    # Teste 5: Verificar se o servidor está no domínio
    log "Verificando se está no domínio..."
    if samba-tool domain info 127.0.0.1 > /dev/null 2>&1; then
        success "✅ Servidor está no domínio"
        DOMAIN_OK=1
    else
        warning "❌ Servidor não está no domínio"
        DOMAIN_OK=0
        DIAGNOSTIC_RESULT="${DIAGNOSTIC_RESULT}DOMAIN_FAIL;"
    fi
    
    # Teste 6: Verificar se é secundário e está com join correto
    if [ "$SERVER_TYPE" == "SECONDARY" ]; then
        if [ -d /var/lib/samba/private ] && [ -f /var/lib/samba/private/smb.conf ]; then
            success "✅ Configuração do secundário parece OK"
        else
            warning "⚠️ Configuração do secundário incompleta"
            DIAGNOSTIC_RESULT="${DIAGNOSTIC_RESULT}SECONDARY_CONFIG_FAIL;"
        fi
    fi
    
    echo ""
    log "═══════════════════════════════════════════════════════════════════════════"
    log "RESULTADO DO DIAGNÓSTICO:"
    log "═══════════════════════════════════════════════════════════════════════════"
    echo ""
    echo -e "  Kerberos:       $([ $KERBEROS_OK -eq 1 ] && echo "${GREEN}✓ OK${NC}" || echo "${RED}✗ FALHOU${NC}")"
    echo -e "  DNS:            $([ $DNS_OK -eq 1 ] && echo "${GREEN}✓ OK${NC}" || echo "${RED}✗ FALHOU${NC}")"
    echo -e "  Conectividade:  $([ $CONNECT_OK -eq 1 ] && echo "${GREEN}✓ OK${NC}" || echo "${RED}✗ FALHOU${NC}")"
    echo -e "  Replicação:     $([ $REPL_OK -eq 1 ] && echo "${GREEN}✓ OK${NC}" || echo "${RED}✗ FALHOU${NC}")"
    echo -e "  Domínio:        $([ $DOMAIN_OK -eq 1 ] && echo "${GREEN}✓ OK${NC}" || echo "${RED}✗ FALHOU${NC}")"
    echo ""
}

# ============================================
# DECISÃO INTELIGENTE
# ============================================
decide_action() {
    log "═══════════════════════════════════════════════════════════════════════════"
    log "3. ANÁLISE E DECISÃO"
    log "═══════════════════════════════════════════════════════════════════════════"
    
    echo ""
    echo -e "${CYAN}Analisando diagnóstico...${NC}"
    echo ""
    
    # Verificar se está tudo OK
    if [ $KERBEROS_OK -eq 1 ] && [ $DNS_OK -eq 1 ] && [ $REPL_OK -eq 1 ] && [ $DOMAIN_OK -eq 1 ] && [ $CONNECT_OK -eq 1 ]; then
        success "✅ TUDO ESTÁ FUNCIONANDO PERFEITAMENTE!"
        echo ""
        echo -e "${GREEN}Nenhuma ação necessária. A replicação já está funcionando.${NC}"
        echo ""
        echo -e "${YELLOW}Deseja mesmo assim executar uma correção preventiva? (s/N):${NC} "
        read -p "> " FORCE_FIX
        
        if [[ ! $FORCE_FIX =~ ^[Ss]$ ]]; then
            ACTION="NONE"
            return
        fi
    fi
    
    # Regras de decisão
    if [ "$SERVER_TYPE" == "PRIMARY" ]; then
        # Se for primário, verificar se o secundário está OK
        if [ $CONNECT_OK -eq 1 ] && [ $DNS_OK -eq 1 ]; then
            if [ $REPL_OK -eq 1 ]; then
                success "Primário está OK. Apenas verificando secundário..."
                ACTION="PRIMARY_VERIFY"
            else
                warning "Primário com problemas de replicação. Corrigindo..."
                ACTION="PRIMARY_FIX"
            fi
        else
            warning "Primário com problemas de DNS ou conectividade. Corrigindo..."
            ACTION="PRIMARY_FIX"
        fi
    else
        # É secundário
        if [ $DOMAIN_OK -eq 0 ] || [ ! -d /var/lib/samba/private ]; then
            warning "Secundário não está no domínio ou configuração incompleta."
            ACTION="SECONDARY_REJOIN"
        elif [ $REPL_OK -eq 0 ]; then
            warning "Secundário no domínio mas com problemas de replicação."
            ACTION="SECONDARY_FIX"
        elif [ $KERBEROS_OK -eq 0 ] || [ $DNS_OK -eq 0 ]; then
            warning "Secundário com problemas de Kerberos ou DNS."
            ACTION="SECONDARY_FIX"
        else
            success "Secundário parece OK. Apenas verificando..."
            ACTION="SECONDARY_VERIFY"
        fi
    fi
    
    echo ""
    echo -e "${CYAN}Decisão: ${ACTION}${NC}"
    echo ""
}

# ============================================
# EXECUTAR AÇÕES
# ============================================
execute_action() {
    log "═══════════════════════════════════════════════════════════════════════════"
    log "4. EXECUTANDO AÇÃO: $ACTION"
    log "═══════════════════════════════════════════════════════════════════════════"
    
    case $ACTION in
        NONE)
            success "Nenhuma ação necessária. Tudo está funcionando!"
            return 0
            ;;
            
        PRIMARY_VERIFY)
            log "Verificando secundário do primário..."
            
            # Verificar se o secundário está respondendo
            if samba-tool domain info $SECONDARY_IP -U administrator --password="$ADMIN_PASSWORD" > /dev/null 2>&1; then
                success "Secundário está respondendo"
                
                # Forçar replicação
                log "Forçando replicação para secundário..."
                samba-tool drs replicate $SECONDARY_HOST $PRIMARY_HOST "DC=${DOMAIN},DC=INTRA" \
                    -U administrator --password="$ADMIN_PASSWORD" 2>&1 | tee -a $LOG_FILE
                
                sleep 10
                success "Verificação concluída"
            else
                warning "Secundário não está respondendo. Tente executar este script no secundário."
            fi
            ;;
            
        PRIMARY_FIX)
            log "Corrigindo primário..."
            
            # Corrigir DNS
            chattr -i /etc/resolv.conf 2>/dev/null || true
            cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
nameserver ${SECONDARY_IP}
search ${DOMAIN,,}
domain ${DOMAIN,,}
EOF
            success "DNS corrigido"
            
            # Verificar e registrar DNS
            samba-tool dns add 127.0.0.1 ${DOMAIN,,} _ldap._tcp SRV "${PRIMARY_HOST}.${DOMAIN,,}" 389 100 0 \
                -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null || true
            samba-tool dns add 127.0.0.1 ${DOMAIN,,} _ldap._tcp SRV "${SECONDARY_HOST}.${DOMAIN,,}" 389 100 0 \
                -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null || true
            
            # Reiniciar serviço
            systemctl restart samba-ad-dc
            sleep 15
            
            success "Primário corrigido"
            ;;
            
        SECONDARY_REJOIN)
            log "FAZENDO REJOIN COMPLETO DO SECUNDÁRIO..."
            
            # Este é o caso mais crítico - fazer rejoin completo
            echo ""
            echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${RED}ATENÇÃO: Será feito um REJOIN completo do servidor secundário!${NC}"
            echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════${NC}"
            echo ""
            echo -e "${BLUE}Isso irá:${NC}"
            echo "  - Parar os serviços"
            echo "  - Remover configurações antigas"
            echo "  - Fazer um novo join no domínio"
            echo "  - Configurar replicação"
            echo "  - Sincronizar SYSVOL"
            echo ""
            read -p "Confirmar? (s/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Ss]$ ]]; then
                error "Operação cancelada pelo usuário"
            fi
            
            # Parar serviços
            systemctl stop samba-ad-dc 2>/dev/null || true
            
            # Remover configurações antigas
            rm -f /etc/samba/smb.conf
            rm -f /etc/krb5.conf
            rm -rf /var/lib/samba/private 2>/dev/null || true
            rm -rf /var/lib/samba/sysvol 2>/dev/null || true
            
            # Configurar resolv.conf para usar primário
            chattr -i /etc/resolv.conf 2>/dev/null || true
            cat > /etc/resolv.conf << EOF
nameserver ${PRIMARY_IP}
search ${DOMAIN,,}
domain ${DOMAIN,,}
EOF
            
            # Fazer join
            log "Fazendo join no domínio..."
            echo "$ADMIN_PASSWORD" | samba-tool domain join ${DOMAIN} DC \
                -U administrator \
                --realm=${REALM} \
                --dns-backend=SAMBA_INTERNAL \
                2>&1 | tee /tmp/join.log
            
            if grep -q "Joined domain" /tmp/join.log; then
                success "JOIN REALIZADO COM SUCESSO!"
                
                # Configurar smb.conf
                if [ -f "/var/lib/samba/private/smb.conf" ]; then
                    cp /var/lib/samba/private/smb.conf /etc/samba/smb.conf
                fi
                
                # Iniciar serviços
                systemctl enable samba-ad-dc 2>/dev/null || true
                systemctl start samba-ad-dc
                sleep 30
                
                # Ajustar resolv.conf
                cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
nameserver ${PRIMARY_IP}
search ${DOMAIN,,}
domain ${DOMAIN,,}
EOF
                
                success "Secundário reconectado ao domínio com sucesso!"
            else
                error "❌ Falha no rejoin. Verifique o log /tmp/join.log"
            fi
            ;;
            
        SECONDARY_FIX)
            log "Corrigindo secundário..."
            
            # Verificar e corrigir DNS
            chattr -i /etc/resolv.conf 2>/dev/null || true
            cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
nameserver ${PRIMARY_IP}
search ${DOMAIN,,}
domain ${DOMAIN,,}
EOF
            
            # Verificar Kerberos
            if ! echo "$ADMIN_PASSWORD" | kinit administrator@${REALM} > /dev/null 2>&1; then
                # Recriar krb5.conf
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
        kdc = ${PRIMARY_HOST}.${DOMAIN,,}
        admin_server = ${PRIMARY_HOST}.${DOMAIN,,}
        default_domain = ${DOMAIN,,}
    }

[domain_realm]
    .${DOMAIN,,} = ${REALM}
    ${DOMAIN,,} = ${REALM}
EOF
            fi
            
            # Forçar replicação de todos os NCs
            log "Forçando replicação..."
            NC_LIST=(
                "DC=${DOMAIN},DC=INTRA"
                "CN=Configuration,DC=${DOMAIN},DC=INTRA"
                "CN=Schema,CN=Configuration,DC=${DOMAIN},DC=INTRA"
                "DC=DomainDnsZones,DC=${DOMAIN},DC=INTRA"
                "DC=ForestDnsZones,DC=${DOMAIN},DC=INTRA"
            )
            
            for NC in "${NC_LIST[@]}"; do
                log "Replicando $NC..."
                samba-tool drs replicate $SECONDARY_HOST $PRIMARY_HOST "$NC" \
                    -U administrator --password="$ADMIN_PASSWORD" 2>&1 | tee -a $LOG_FILE || true
                sleep 2
            done
            
            # Sincronizar SYSVOL
            log "Sincronizando SYSVOL..."
            samba-tool ntacl sysvolreset 2>&1 | tee -a $LOG_FILE || true
            
            success "Secundário corrigido"
            ;;
            
        SECONDARY_VERIFY)
            log "Verificando secundário..."
            
            # Testar replicação com usuário
            TEST_USER="test_verify_$(date +%s)"
            TEST_PASS="Test@1234"
            
            if samba-tool user create $TEST_USER $TEST_PASS --given-name="Test" --surname="Verify" \
                -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null; then
                
                log "Usuário de teste criado. Aguardando replicação..."
                sleep 15
                
                if samba-tool user list --host=$PRIMARY_IP -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null | grep -q "$TEST_USER"; then
                    success "✅ Usuário replicado para o primário com sucesso!"
                    samba-tool user delete $TEST_USER -U administrator --password="$ADMIN_PASSWORD" > /dev/null 2>&1
                else
                    warning "❌ Usuário não foi replicado. Tentando forçar..."
                    samba-tool drs replicate $PRIMARY_HOST $SECONDARY_HOST "DC=${DOMAIN},DC=INTRA" \
                        -U administrator --password="$ADMIN_PASSWORD" 2>&1 | tee -a $LOG_FILE
                    sleep 10
                    
                    if samba-tool user list --host=$PRIMARY_IP -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null | grep -q "$TEST_USER"; then
                        success "✅ Usuário replicado após força manual!"
                    fi
                    samba-tool user delete $TEST_USER -U administrator --password="$ADMIN_PASSWORD" > /dev/null 2>&1
                fi
            fi
            
            success "Verificação concluída"
            ;;
            
        *)
            warning "Ação desconhecida: $ACTION"
            ;;
    esac
}

# ============================================
# VERIFICAR RESULTADO FINAL
# ============================================
verify_final() {
    log "═══════════════════════════════════════════════════════════════════════════"
    log "5. VERIFICAÇÃO FINAL"
    log "═══════════════════════════════════════════════════════════════════════════"
    
    echo ""
    log "Verificando status final da replicação..."
    echo ""
    
    # Verificar status
    samba-tool drs showrepl 2>&1 | tee -a $LOG_FILE
    
    echo ""
    log "Verificando DNS..."
    host -t SRV _ldap._tcp.${DOMAIN,,} 2>&1 | tee -a $LOG_FILE
    
    echo ""
    log "Verificando servidores..."
    samba-tool domain info 127.0.0.1 2>&1 | tee -a $LOG_FILE
    
    echo ""
    
    # Teste final de replicação
    TEST_USER="test_final_$(date +%s)"
    TEST_PASS="Test@1234"
    
    log "Teste final de replicação..."
    if samba-tool user create $TEST_USER $TEST_PASS --given-name="Test" --surname="Final" \
        -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null; then
        
        log "Usuário criado. Aguardando replicação (20 segundos)..."
        sleep 20
        
        # Verificar no outro servidor
        if samba-tool user list --host=$OTHER_IP -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null | grep -q "$TEST_USER"; then
            success "✅ TESTE FINAL PASSOU! Usuário replicado com sucesso!"
            REPLICATION_WORKING=1
        else
            warning "⚠️ Usuário não replicado para $OTHER_HOST"
            REPLICATION_WORKING=0
        fi
        
        # Limpar
        samba-tool user delete $TEST_USER -U administrator --password="$ADMIN_PASSWORD" > /dev/null 2>&1
        samba-tool user delete $TEST_USER --host=$OTHER_IP -U administrator --password="$ADMIN_PASSWORD" > /dev/null 2>&1
    else
        warning "⚠️ Não foi possível criar usuário de teste"
        REPLICATION_WORKING=0
    fi
}

# ============================================
# CRIAR MONITORAMENTO
# ============================================
create_monitoring() {
    log "═══════════════════════════════════════════════════════════════════════════"
    log "6. CRIANDO MONITORAMENTO"
    log "═══════════════════════════════════════════════════════════════════════════"
    
    # Script de monitoramento
    cat > /usr/local/bin/monitor_replication.sh << 'EOF'
#!/bin/bash
# Monitor de replicação

DOMAIN="RNV.INTRA"
PRIMARY="adserver01"
SECONDARY="adserver02"
LOG="/var/log/replication_monitor.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> $LOG
}

# Verificar serviço
if ! systemctl is-active --quiet samba-ad-dc; then
    log "❌ Serviço parado. Reiniciando..."
    systemctl restart samba-ad-dc
    sleep 10
fi

# Verificar replicação
if samba-tool drs showrepl 2>&1 | grep -q "successful"; then
    log "✅ Replicação OK"
else
    log "⚠️ Problemas na replicação. Corrigindo..."
    samba-tool drs replicate $SECONDARY $PRIMARY "DC=${DOMAIN},DC=INTRA" 2>/dev/null
    samba-tool drs replicate $PRIMARY $SECONDARY "DC=${DOMAIN},DC=INTRA" 2>/dev/null
    sleep 5
    if samba-tool drs showrepl 2>&1 | grep -q "successful"; then
        log "✅ Replicação corrigida"
    else
        log "❌ Replicação ainda com problemas"
    fi
fi
EOF

    chmod +x /usr/local/bin/monitor_replication.sh
    
    # Configurar crontab
    if ! crontab -l 2>/dev/null | grep -q "monitor_replication.sh"; then
        (crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/monitor_replication.sh > /dev/null 2>&1") | crontab -
        success "Monitoramento configurado (a cada 5 minutos)"
    fi
}

# ============================================
# RESUMO FINAL
# ============================================
show_final_summary() {
    clear
    echo -e "${GREEN}"
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo "                                                                           "
    echo "         ✅ SOLVER INTELIGENTE - CONCLUÍDO!                               "
    echo "                                                                           "
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo -e "${NC}"
    echo ""
    echo -e "${BLUE}📋 RESUMO DA EXECUÇÃO:${NC}"
    echo ""
    echo -e "  Servidor: ${CYAN}$SERVER_TYPE ($CURRENT_IP)${NC}"
    echo -e "  Ação executada: ${CYAN}$ACTION${NC}"
    echo ""
    
    if [ "$REPLICATION_WORKING" = 1 ]; then
        echo -e "  ${GREEN}✅ REPLICAÇÃO FUNCIONANDO PERFEITAMENTE!${NC}"
    else
        echo -e "  ${YELLOW}⚠️ REPLICAÇÃO PODE PRECISAR DE VERIFICAÇÃO MANUAL${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}📁 ARQUIVOS E LOGS:${NC}"
    echo ""
    echo -e "  Log da execução: ${BLUE}$LOG_FILE${NC}"
    echo -e "  Diretório de trabalho: ${BLUE}$WORK_DIR${NC}"
    echo -e "  Monitoramento: ${BLUE}/usr/local/bin/monitor_replication.sh${NC}"
    echo -e "  Log do monitoramento: ${BLUE}/var/log/replication_monitor.log${NC}"
    echo ""
    echo -e "${YELLOW}🔧 COMANDOS PARA VERIFICAR:${NC}"
    echo ""
    echo -e "  Verificar replicação:"
    echo -e "  ${BLUE}samba-tool drs showrepl${NC}"
    echo ""
    echo -e "  Verificar logs em tempo real:"
    echo -e "  ${BLUE}tail -f /var/log/replication_monitor.log${NC}"
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════════════════${NC}"
}

# ============================================
# FUNÇÃO PRINCIPAL
# ============================================
main() {
    header
    pre_checks
    get_password
    diagnose_replication
    decide_action
    
    if [ "$ACTION" != "NONE" ]; then
        execute_action
        sleep 5
        verify_final
        create_monitoring
    else
        success "Tudo está funcionando! Nenhuma ação necessária."
        REPLICATION_WORKING=1
    fi
    
    show_final_summary
    
    log "═══════════════════════════════════════════════════════════════════════════"
    log "✅ SOLVER INTELIGENTE CONCLUÍDO COM SUCESSO!"
    log "═══════════════════════════════════════════════════════════════════════════"
}

# ============================================
# EXECUTAR
# ============================================
main
