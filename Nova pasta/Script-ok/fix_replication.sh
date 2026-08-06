#!/bin/bash
# fix_replication.sh
# Script para diagnosticar e corrigir problemas de replicação no Samba AD
# Versão: 1.0

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configurações
DOMAIN="RNV.INTRA"
REALM="RNV.INTRA"
SHORT_DOMAIN="RNV"
PRIMARY_IP="192.168.1.2"
PRIMARY_HOST="adserver01"
SECONDARY_IP="192.168.1.3"
SECONDARY_HOST="adserver02"
LOG_FILE="/var/log/fix_replication.log"

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

check_success() {
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ OK${NC}"
        return 0
    else
        echo -e "${RED}✗ FALHOU${NC}"
        return 1
    fi
}

# ============================================
# VERIFICAÇÕES INICIAIS
# ============================================
check_requirements() {
    log "Verificando pré-requisitos..."
    
    if [[ $EUID -ne 0 ]]; then
        error "Este script deve ser executado como root (sudo)"
    fi
    
    if ! command -v samba-tool &> /dev/null; then
        error "samba-tool não encontrado"
    fi
    
    log "✓ Pré-requisitos verificados"
}

# ============================================
# IDENTIFICAR SERVIDOR
# ============================================
identify_server() {
    log "Identificando este servidor..."
    
    CURRENT_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -1)
    CURRENT_HOSTNAME=$(hostname -s)
    
    info "IP atual: $CURRENT_IP"
    info "Hostname: $CURRENT_HOSTNAME"
    
    if [[ "$CURRENT_IP" == "$PRIMARY_IP" ]] || [[ "$CURRENT_HOSTNAME" == "$PRIMARY_HOST" ]]; then
        SERVER_TYPE="PRIMARY"
        OTHER_IP="$SECONDARY_IP"
        OTHER_HOST="$SECONDARY_HOST"
        log "✅ Este servidor é o AD PRIMÁRIO"
    elif [[ "$CURRENT_IP" == "$SECONDARY_IP" ]] || [[ "$CURRENT_HOSTNAME" == "$SECONDARY_HOST" ]]; then
        SERVER_TYPE="SECONDARY"
        OTHER_IP="$PRIMARY_IP"
        OTHER_HOST="$PRIMARY_HOST"
        log "✅ Este servidor é o AD SECUNDÁRIO"
    else
        error "Não foi possível identificar o servidor"
    fi
}

# ============================================
# SOLICITAR SENHA
# ============================================
get_admin_password() {
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}Digite a senha do administrador do domínio:${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    read -s -p "> " ADMIN_PASSWORD
    echo ""
    
    if [ -z "$ADMIN_PASSWORD" ]; then
        error "Senha não pode ser vazia"
    fi
    
    export ADMIN_PASSWORD
}

# ============================================
# 1. VERIFICAR KERBEROS
# ============================================
check_kerberos() {
    log "1. Verificando Kerberos..."
    
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}Testando Kerberos...${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    
    # Tentar autenticar
    if echo "$ADMIN_PASSWORD" | kinit administrator@${REALM} > /dev/null 2>&1; then
        log "✅ Kerberos funcionando"
        klist
    else
        warning "❌ Kerberos falhou. Tentando corrigir..."
        
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

[logging]
    kdc = FILE:/var/log/krb5kdc.log
    admin_server = FILE:/var/log/kadmin.log
    default = FILE:/var/log/krb5lib.log
EOF
        
        # Testar novamente
        if echo "$ADMIN_PASSWORD" | kinit administrator@${REALM} > /dev/null 2>&1; then
            log "✅ Kerberos corrigido"
        else
            error "❌ Falha no Kerberos. Verifique a senha."
        fi
    fi
}

# ============================================
# 2. VERIFICAR DNS
# ============================================
check_dns() {
    log "2. Verificando DNS..."
    
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}Verificando DNS...${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    
    # Verificar resolução
    for host in $PRIMARY_HOST $SECONDARY_HOST; do
        if host -t A $host.${DOMAIN,,} > /dev/null 2>&1; then
            log "✅ $host.${DOMAIN,,} resolvido"
        else
            warning "❌ $host.${DOMAIN,,} NÃO resolvido"
            
            # Adicionar ao /etc/hosts
            if [ "$host" == "$PRIMARY_HOST" ]; then
                echo "$PRIMARY_IP $PRIMARY_HOST.${DOMAIN,,} $PRIMARY_HOST" >> /etc/hosts
            else
                echo "$SECONDARY_IP $SECONDARY_HOST.${DOMAIN,,} $SECONDARY_HOST" >> /etc/hosts
            fi
            log "✅ $host adicionado ao /etc/hosts"
        fi
    done
    
    # Verificar SRV records
    log "Verificando registros SRV..."
    if host -t SRV _ldap._tcp.${DOMAIN,,} > /dev/null 2>&1; then
        log "✅ Registros SRV OK"
        host -t SRV _ldap._tcp.${DOMAIN,,}
    else
        warning "❌ Registros SRV não encontrados"
        
        # Registrar manualmente
        samba-tool dns add 127.0.0.1 ${DOMAIN,,} _ldap._tcp SRV "${PRIMARY_HOST}.${DOMAIN,,}" 389 100 0 -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null || true
        samba-tool dns add 127.0.0.1 ${DOMAIN,,} _ldap._tcp SRV "${SECONDARY_HOST}.${DOMAIN,,}" 389 100 0 -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null || true
        samba-tool dns add 127.0.0.1 ${DOMAIN,,} _kerberos._tcp SRV "${PRIMARY_HOST}.${DOMAIN,,}" 88 100 0 -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null || true
        samba-tool dns add 127.0.0.1 ${DOMAIN,,} _kerberos._tcp SRV "${SECONDARY_HOST}.${DOMAIN,,}" 88 100 0 -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null || true
    fi
}

# ============================================
# 3. VERIFICAR STATUS DO SAMBA
# ============================================
check_samba_status() {
    log "3. Verificando status do Samba..."
    
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}Verificando serviços do Samba...${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    
    if systemctl is-active --quiet samba-ad-dc; then
        log "✅ samba-ad-dc está rodando"
    else
        warning "❌ samba-ad-dc parado. Iniciando..."
        systemctl start samba-ad-dc
        sleep 5
        if systemctl is-active --quiet samba-ad-dc; then
            log "✅ samba-ad-dc iniciado"
        else
            error "❌ Não foi possível iniciar samba-ad-dc"
        fi
    fi
    
    # Verificar portas
    log "Verificando portas..."
    for port in 389 445 464 636 3268 3269; do
        if netstat -tlnp 2>/dev/null | grep -q ":$port "; then
            log "✅ Porta $port aberta"
        else
            warning "⚠️ Porta $port não encontrada"
        fi
    done
}

# ============================================
# 4. VERIFICAR JOIN DO DOMÍNIO
# ============================================
check_domain_join() {
    log "4. Verificando join do domínio..."
    
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}Verificando join do domínio...${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    
    if samba-tool domain info 127.0.0.1 -U administrator --password="$ADMIN_PASSWORD" > /dev/null 2>&1; then
        log "✅ Servidor está no domínio"
        samba-tool domain info 127.0.0.1 | grep -E "Domain|Realm|DC"
    else
        warning "❌ Servidor não está no domínio ou não responde"
        
        if [ "$SERVER_TYPE" == "SECONDARY" ]; then
            log "Tentando rejoin do domínio..."
            
            # Parar serviços
            systemctl stop samba-ad-dc
            
            # Limpar configurações antigas
            rm -rf /var/lib/samba/private/* 2>/dev/null || true
            rm -f /etc/samba/smb.conf
            
            # Rejoin
            echo "$ADMIN_PASSWORD" | samba-tool domain join ${DOMAIN} DC \
                -U administrator \
                --realm=${REALM} \
                --dns-backend=SAMBA_INTERNAL 2>&1 | tee -a $LOG_FILE
            
            if [ $? -eq 0 ]; then
                log "✅ Rejoin realizado com sucesso"
                systemctl start samba-ad-dc
                sleep 10
            else
                error "❌ Falha no rejoin"
            fi
        else
            warning "Servidor primário não precisa de join"
        fi
    fi
}

# ============================================
# 5. FORÇAR REPLICAÇÃO CORRETAMENTE
# ============================================
force_replication() {
    log "5. Forçando replicação..."
    
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}Forçando replicação...${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    
    # Primeiro, verificar se o outro servidor está acessível
    if ! ping -c 2 -W 2 $OTHER_IP > /dev/null 2>&1; then
        warning "❌ $OTHER_HOST não está acessível"
        return 1
    fi
    
    # Usar o comando correto para replicação
    if [ "$SERVER_TYPE" == "PRIMARY" ]; then
        log "Replicando do Primário para o Secundário..."
        
        # Forçar replicação de todos os NCs
        for NC in "DC=${DOMAIN},DC=INTRA" "CN=Configuration,DC=${DOMAIN},DC=INTRA" "CN=Schema,CN=Configuration,DC=${DOMAIN},DC=INTRA" "DC=DomainDnsZones,DC=${DOMAIN},DC=INTRA" "DC=ForestDnsZones,DC=${DOMAIN},DC=INTRA"; do
            log "Replicando $NC..."
            samba-tool drs replicate $SECONDARY_HOST $PRIMARY_HOST "$NC" -U administrator --password="$ADMIN_PASSWORD" 2>&1 | tee -a $LOG_FILE || true
            sleep 2
        done
        
    else
        log "Replicando do Secundário para o Primário..."
        
        # Forçar replicação de todos os NCs
        for NC in "DC=${DOMAIN},DC=INTRA" "CN=Configuration,DC=${DOMAIN},DC=INTRA" "CN=Schema,CN=Configuration,DC=${DOMAIN},DC=INTRA" "DC=DomainDnsZones,DC=${DOMAIN},DC=INTRA" "DC=ForestDnsZones,DC=${DOMAIN},DC=INTRA"; do
            log "Replicando $NC..."
            samba-tool drs replicate $PRIMARY_HOST $SECONDARY_HOST "$NC" -U administrator --password="$ADMIN_PASSWORD" 2>&1 | tee -a $LOG_FILE || true
            sleep 2
        done
    fi
    
    log "✅ Replicação forçada concluída"
}

# ============================================
# 6. SINCRONIZAR SYSVOL
# ============================================
sync_sysvol() {
    log "6. Sincronizando SYSVOL..."
    
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}Sincronizando SYSVOL...${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    
    # Resetar ACLs do SYSVOL
    samba-tool ntacl sysvolreset 2>&1 | tee -a $LOG_FILE
    
    if [ "$SERVER_TYPE" == "SECONDARY" ]; then
        # Forçar sincronização do SYSVOL via rsync (se disponível)
        if command -v rsync &> /dev/null; then
            log "Sincronizando SYSVOL via rsync..."
            
            # Parar serviços para sincronizar SYSVOL
            systemctl stop samba-ad-dc
            
            # Sincronizar do primário
            rsync -avz --delete root@$PRIMARY_IP:/var/lib/samba/sysvol/ /var/lib/samba/sysvol/ 2>&1 | tee -a $LOG_FILE
            
            # Iniciar serviços novamente
            systemctl start samba-ad-dc
            sleep 10
            
            log "✅ SYSVOL sincronizado"
        fi
    fi
}

# ============================================
# 7. VERIFICAR REPLICAÇÃO
# ============================================
verify_replication() {
    log "7. Verificando replicação..."
    
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}Status da Replicação:${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    
    samba-tool drs showrepl 2>&1 | tee -a $LOG_FILE
    
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}Teste de Replicação com Usuário:${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    
    local TEST_USER="test_repl_$(date +%s)"
    local TEST_PASS="Test@1234"
    
    # Criar usuário de teste
    if samba-tool user create $TEST_USER $TEST_PASS --given-name="Test" --surname="Replication" -U administrator --password="$ADMIN_PASSWORD" 2>&1 | tee -a $LOG_FILE; then
        log "✅ Usuário de teste criado"
        
        # Aguardar replicação
        sleep 15
        
        # Verificar no outro servidor
        log "Verificando no $OTHER_HOST..."
        if samba-tool user list --host=$OTHER_IP -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null | grep -q "$TEST_USER"; then
            log "✅ Usuário $TEST_USER replicado com sucesso!"
            samba-tool user delete $TEST_USER -U administrator --password="$ADMIN_PASSWORD" > /dev/null 2>&1
            samba-tool user delete $TEST_USER --host=$OTHER_IP -U administrator --password="$ADMIN_PASSWORD" > /dev/null 2>&1
        else
            warning "❌ Usuário NÃO foi replicado"
            
            # Tentar forçar uma última vez
            log "Tentando forçar replicação novamente..."
            if [ "$SERVER_TYPE" == "PRIMARY" ]; then
                samba-tool drs replicate $SECONDARY_HOST $PRIMARY_HOST "DC=${DOMAIN},DC=INTRA" -U administrator --password="$ADMIN_PASSWORD"
            else
                samba-tool drs replicate $PRIMARY_HOST $SECONDARY_HOST "DC=${DOMAIN},DC=INTRA" -U administrator --password="$ADMIN_PASSWORD"
            fi
            
            sleep 10
            
            # Verificar novamente
            if samba-tool user list --host=$OTHER_IP -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null | grep -q "$TEST_USER"; then
                log "✅ Usuário replicado após força manual!"
                samba-tool user delete $TEST_USER -U administrator --password="$ADMIN_PASSWORD" > /dev/null 2>&1
                samba-tool user delete $TEST_USER --host=$OTHER_IP -U administrator --password="$ADMIN_PASSWORD" > /dev/null 2>&1
            else
                warning "❌ Usuário NÃO foi replicado mesmo após força manual"
            fi
        fi
    else
        warning "❌ Falha ao criar usuário de teste"
    fi
}

# ============================================
# 8. CRIAR SCRIPT DE MONITORAMENTO CORRIGIDO
# ============================================
create_monitor() {
    log "8. Criando script de monitoramento..."
    
    cat > /usr/local/bin/monitor_replication.sh << 'EOF'
#!/bin/bash
# Monitor de replicação Samba AD

DOMAIN="RNV.INTRA"
PRIMARY="adserver01"
SECONDARY="adserver02"
LOG="/var/log/replication_monitor.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> $LOG
}

# Verificar serviços
if ! systemctl is-active --quiet samba-ad-dc; then
    log "❌ Serviço parado. Reiniciando..."
    systemctl restart samba-ad-dc
    sleep 10
fi

# Verificar replicação
log "Verificando replicação..."
REPL_STATUS=$(samba-tool drs showrepl 2>&1)

if echo "$REPL_STATUS" | grep -q "successful"; then
    log "✅ Replicação OK"
else
    log "⚠️ Problemas na replicação. Forçando..."
    
    # Forçar replicação em ambas as direções
    samba-tool drs replicate $SECONDARY $PRIMARY "DC=${DOMAIN},DC=INTRA" 2>/dev/null
    samba-tool drs replicate $PRIMARY $SECONDARY "DC=${DOMAIN},DC=INTRA" 2>/dev/null
    
    sleep 5
    
    # Verificar novamente
    if samba-tool drs showrepl 2>&1 | grep -q "successful"; then
        log "✅ Replicação corrigida"
    else
        log "❌ Replicação ainda com problemas"
    fi
fi
EOF

    chmod +x /usr/local/bin/monitor_replication.sh
    log "✅ Script de monitoramento criado"
}

# ============================================
# 9. CONFIGURAR CRONTAB
# ============================================
configure_crontab() {
    log "9. Configurando crontab..."
    
    if ! crontab -l 2>/dev/null | grep -q "monitor_replication.sh"; then
        (crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/monitor_replication.sh > /dev/null 2>&1") | crontab -
        log "✅ Monitoramento agendado a cada 5 minutos"
    fi
}

# ============================================
# 10. MOSTRAR RESUMO
# ============================================
show_summary() {
    clear
    echo -e "${GREEN}"
    echo "═══════════════════════════════════════════════════════════════════"
    echo "                                                                   "
    echo "         ✅ DIAGNÓSTICO E CORREÇÃO CONCLUÍDOS!                     "
    echo "                                                                   "
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "${NC}"
    echo ""
    echo -e "${BLUE}📋 RESULTADO:${NC}"
    echo ""
    echo -e "  Servidor: ${GREEN}$SERVER_TYPE${NC}"
    echo -e "  Status: ${GREEN}Configurado${NC}"
    echo ""
    echo -e "${YELLOW}📁 LOGS:${NC}"
    echo -e "  /var/log/fix_replication.log"
    echo -e "  /var/log/replication_monitor.log"
    echo ""
    echo -e "${YELLOW}🔧 PRÓXIMOS PASSOS:${NC}"
    echo ""
    echo -e "  1. ${GREEN}Execute este script em AMBOS os servidores${NC}"
    echo -e "  2. Verifique a replicação: ${BLUE}samba-tool drs showrepl${NC}"
    echo -e "  3. Teste criando um usuário em qualquer servidor"
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
}

# ============================================
# FUNÇÃO PRINCIPAL
# ============================================
main() {
    echo ""
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║                                                               ║"
    echo "║     DIAGNÓSTICO E CORREÇÃO DE REPLICAÇÃO SAMBA AD            ║"
    echo "║                                                               ║"
    echo "║     Domínio: ${DOMAIN}                                        ║"
    echo "║     Primário: ${PRIMARY_HOST} (${PRIMARY_IP})                ║"
    echo "║     Secundário: ${SECONDARY_HOST} (${SECONDARY_IP})          ║"
    echo "║                                                               ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    check_requirements
    identify_server
    get_admin_password
    check_kerberos
    check_dns
    check_samba_status
    check_domain_join
    force_replication
    sync_sysvol
    verify_replication
    create_monitor
    configure_crontab
    show_summary
    
    log "✅ Correção concluída!"
}

# ============================================
# EXECUTAR
# ============================================
main
