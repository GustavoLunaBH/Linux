#!/bin/bash
# configure_native_replication.sh
# Script para configurar e ativar replicação nativa do Samba AD
# Versão: 1.0

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configurações
DOMAIN="RNV.LOCAL"
REALM="RNV.LOCAL"
SHORT_DOMAIN="RNV"
PRIMARY_IP="192.168.1.2"
PRIMARY_HOST="adserver01"
SECONDARY_IP="192.168.1.3"
SECONDARY_HOST="adserver02"
LOG_FILE="/var/log/replication_setup.log"

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
    
    # Verificar se é root
    if [[ $EUID -ne 0 ]]; then
        error "Este script deve ser executado como root (sudo)"
    fi
    
    # Verificar se o Samba está instalado
    if ! command -v samba-tool &> /dev/null; then
        error "samba-tool não encontrado. Instale o Samba AD primeiro."
    fi
    
    # Verificar se o serviço está rodando
    if ! systemctl is-active --quiet samba-ad-dc; then
        warning "Serviço samba-ad-dc não está rodando. Iniciando..."
        systemctl start samba-ad-dc
        sleep 5
    fi
    
    log "✓ Pré-requisitos verificados"
}

# ============================================
# IDENTIFICAR O SERVIDOR ATUAL
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
        log "✅ Este servidor é o AD PRIMÁRIO ($PRIMARY_HOST)"
    elif [[ "$CURRENT_IP" == "$SECONDARY_IP" ]] || [[ "$CURRENT_HOSTNAME" == "$SECONDARY_HOST" ]]; then
        SERVER_TYPE="SECONDARY"
        OTHER_IP="$PRIMARY_IP"
        OTHER_HOST="$PRIMARY_HOST"
        log "✅ Este servidor é o AD SECUNDÁRIO ($SECONDARY_HOST)"
    else
        warning "Não foi possível identificar o servidor automaticamente."
        warning "IP atual: $CURRENT_IP, Hostname: $CURRENT_HOSTNAME"
        
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
    
    log "Tipo de servidor: $SERVER_TYPE"
    log "Outro servidor: $OTHER_HOST ($OTHER_IP)"
}

# ============================================
# SOLICITAR SENHA DO ADMINISTRADOR
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
    
    # Testar autenticação
    log "Testando autenticação..."
    if echo "$ADMIN_PASSWORD" | kinit administrator@${REALM} > /dev/null 2>&1; then
        log "✅ Autenticação OK"
    else
        error "Falha na autenticação. Verifique a senha."
    fi
    
    export ADMIN_PASSWORD
}

# ============================================
# CONFIGURAR RESOLV.CONF
# ============================================
configure_resolv() {
    log "Configurando /etc/resolv.conf..."
    
    # Backup do arquivo atual
    if [ -f /etc/resolv.conf ]; then
        cp /etc/resolv.conf /etc/resolv.conf.bak.$(date +%Y%m%d_%H%M%S)
    fi
    
    # Remover atributo imutável se existir
    chattr -i /etc/resolv.conf 2>/dev/null || true
    
    if [ "$SERVER_TYPE" == "PRIMARY" ]; then
        cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
nameserver ${SECONDARY_IP}
search ${DOMAIN,,}
domain ${DOMAIN,,}
EOF
    else
        cat > /etc/resolv.conf << EOF
nameserver ${PRIMARY_IP}
nameserver 127.0.0.1
search ${DOMAIN,,}
domain ${DOMAIN,,}
EOF
    fi
    
    check_success
    log "✅ /etc/resolv.conf configurado"
}

# ============================================
# VERIFICAR DNS
# ============================================
check_dns() {
    log "Verificando DNS..."
    
    # Verificar resolução de ambos os servidores
    for host in $PRIMARY_HOST $SECONDARY_HOST; do
        if host -t A $host.${DOMAIN,,} > /dev/null 2>&1; then
            log "✅ $host.${DOMAIN,,} resolvido"
        else
            warning "❌ $host.${DOMAIN,,} não resolvido"
            
            # Adicionar ao /etc/hosts se não resolver
            if [ "$host" == "$PRIMARY_HOST" ]; then
                echo "$PRIMARY_IP $PRIMARY_HOST.${DOMAIN,,} $PRIMARY_HOST" >> /etc/hosts
            else
                echo "$SECONDARY_IP $SECONDARY_HOST.${DOMAIN,,} $SECONDARY_HOST" >> /etc/hosts
            fi
        fi
    done
    
    # Verificar registros SRV
    log "Verificando registros SRV..."
    if host -t SRV _ldap._tcp.${DOMAIN,,} > /dev/null 2>&1; then
        log "✅ Registros SRV encontrados"
        host -t SRV _ldap._tcp.${DOMAIN,,}
    else
        warning "⚠️ Registros SRV não encontrados. Registrando..."
        
        # Registrar DNS manualmente
        samba-tool dns add 127.0.0.1 ${DOMAIN,,} _ldap._tcp SRV "${OTHER_HOST}.${DOMAIN,,}" 389 100 0 -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null || true
        samba-tool dns add 127.0.0.1 ${DOMAIN,,} _kerberos._tcp SRV "${OTHER_HOST}.${DOMAIN,,}" 88 100 0 -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null || true
    fi
}

# ============================================
# CONFIGURAR REPLICAÇÃO
# ============================================
configure_replication() {
    log "Configurando replicação nativa..."
    
    if [ "$SERVER_TYPE" == "PRIMARY" ]; then
        log "Configurando replicação do Primário para o Secundário..."
        
        # Verificar se o outro servidor é um DC
        if samba-tool domain info $OTHER_IP -U administrator --password="$ADMIN_PASSWORD" > /dev/null 2>&1; then
            log "✅ $OTHER_HOST está respondendo como DC"
        else
            warning "⚠️ $OTHER_HOST não está respondendo como DC. Verifique se o servidor secundário está configurado."
        fi
        
        # Forçar replicação para o secundário
        log "Forçando replicação inicial para $OTHER_HOST..."
        samba-tool drs replicate $OTHER_HOST $PRIMARY_HOST ${DOMAIN,,} -U administrator --password="$ADMIN_PASSWORD" 2>&1 | tee -a $LOG_FILE
        check_success
        
        # Forçar replicação de volta
        log "Forçando replicação de volta para $PRIMARY_HOST..."
        samba-tool drs replicate $PRIMARY_HOST $OTHER_HOST ${DOMAIN,,} -U administrator --password="$ADMIN_PASSWORD" 2>&1 | tee -a $LOG_FILE
        check_success
        
    else
        log "Configurando replicação do Secundário para o Primário..."
        
        # Verificar se o primário está acessível
        if samba-tool domain info $OTHER_IP -U administrator --password="$ADMIN_PASSWORD" > /dev/null 2>&1; then
            log "✅ $OTHER_HOST está respondendo como DC"
        else
            warning "⚠️ $OTHER_HOST não está respondendo. Verifique se o servidor primário está online."
        fi
        
        # Forçar replicação do primário
        log "Forçando replicação do $OTHER_HOST para este servidor..."
        samba-tool drs replicate $SECONDARY_HOST $OTHER_HOST ${DOMAIN,,} -U administrator --password="$ADMIN_PASSWORD" 2>&1 | tee -a $LOG_FILE
        check_success
        
        # Forçar replicação de volta
        log "Forçando replicação deste servidor para $OTHER_HOST..."
        samba-tool drs replicate $OTHER_HOST $SECONDARY_HOST ${DOMAIN,,} -U administrator --password="$ADMIN_PASSWORD" 2>&1 | tee -a $LOG_FILE
        check_success
    fi
}

# ============================================
# VERIFICAR ESTADO DA REPLICAÇÃO
# ============================================
check_replication_status() {
    log "Verificando status da replicação..."
    
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}Status da Replicação em $(hostname):${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    
    samba-tool drs showrepl 2>&1 | tee -a $LOG_FILE
    
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}Registros DNS:${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    
    host -t SRV _ldap._tcp.${DOMAIN,,} 2>&1 | tee -a $LOG_FILE
    host -t A $PRIMARY_HOST.${DOMAIN,,} 2>&1 | tee -a $LOG_FILE
    host -t A $SECONDARY_HOST.${DOMAIN,,} 2>&1 | tee -a $LOG_FILE
}

# ============================================
# TESTAR REPLICAÇÃO COM USUÁRIO DE TESTE
# ============================================
test_replication() {
    log "Testando replicação com usuário de teste..."
    
    local TEST_USER="test_repl_$(date +%s)"
    local TEST_PASS="Test@1234"
    
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}Criando usuário de teste: $TEST_USER${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    
    # Criar usuário de teste
    if samba-tool user create $TEST_USER $TEST_PASS --given-name="Test" --surname="Replication" -U administrator --password="$ADMIN_PASSWORD" 2>&1 | tee -a $LOG_FILE; then
        log "✅ Usuário de teste criado com sucesso"
    else
        warning "❌ Falha ao criar usuário de teste"
        return 1
    fi
    
    # Aguardar replicação
    log "Aguardando replicação (10 segundos)..."
    sleep 10
    
    # Verificar no outro servidor
    log "Verificando se o usuário foi replicado para $OTHER_HOST..."
    
    if samba-tool user list --host=$OTHER_IP -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null | grep -q "$TEST_USER"; then
        log "✅ Usuário $TEST_USER replicado com sucesso para $OTHER_HOST"
        
        # Remover usuário de teste
        log "Removendo usuário de teste..."
        samba-tool user delete $TEST_USER -U administrator --password="$ADMIN_PASSWORD" > /dev/null 2>&1
        samba-tool user delete $TEST_USER --host=$OTHER_IP -U administrator --password="$ADMIN_PASSWORD" > /dev/null 2>&1
        
        log "✅ Teste de replicação concluído com sucesso!"
        return 0
    else
        warning "❌ Usuário $TEST_USER NÃO foi replicado para $OTHER_HOST"
        
        # Tentar forçar replicação
        log "Tentando forçar replicação..."
        if [ "$SERVER_TYPE" == "PRIMARY" ]; then
            samba-tool drs replicate $OTHER_HOST $PRIMARY_HOST ${DOMAIN,,} -U administrator --password="$ADMIN_PASSWORD"
        else
            samba-tool drs replicate $SECONDARY_HOST $PRIMARY_HOST ${DOMAIN,,} -U administrator --password="$ADMIN_PASSWORD"
        fi
        
        sleep 5
        
        # Verificar novamente
        if samba-tool user list --host=$OTHER_IP -U administrator --password="$ADMIN_PASSWORD" 2>/dev/null | grep -q "$TEST_USER"; then
            log "✅ Usuário replicado após força manual!"
            
            # Remover usuário de teste
            samba-tool user delete $TEST_USER -U administrator --password="$ADMIN_PASSWORD" > /dev/null 2>&1
            samba-tool user delete $TEST_USER --host=$OTHER_IP -U administrator --password="$ADMIN_PASSWORD" > /dev/null 2>&1
            
            return 0
        else
            warning "❌ Mesmo com replicação forçada, usuário não foi replicado"
            return 1
        fi
    fi
}

# ============================================
# CRIAR SCRIPT DE MONITORAMENTO
# ============================================
create_monitor_script() {
    log "Criando script de monitoramento..."
    
    cat > /usr/local/bin/monitor_replication.sh << 'EOF'
#!/bin/bash
# Script para monitorar replicação do Samba AD

DOMAIN="RNV.LOCAL"
PRIMARY="adserver01"
SECONDARY="adserver02"
LOG="/var/log/replication_monitor.log"
ALERT_EMAIL="admin@rnv.local"  # Opcional

# Função para verificar replicação
check_replication() {
    local status=$(samba-tool drs showrepl 2>&1)
    
    if echo "$status" | grep -q "Successful"; then
        echo "$(date) - ✅ Replicação OK" >> $LOG
        return 0
    else
        echo "$(date) - ❌ Problemas na replicação" >> $LOG
        echo "$status" >> $LOG
        
        # Tentar forçar replicação
        echo "$(date) - Tentando forçar replicação..." >> $LOG
        samba-tool drs replicate $SECONDARY $PRIMARY $DOMAIN 2>&1 >> $LOG
        samba-tool drs replicate $PRIMARY $SECONDARY $DOMAIN 2>&1 >> $LOG
        
        return 1
    fi
}

# Função para verificar se ambos DCs estão online
check_dcs() {
    for dc in $PRIMARY $SECONDARY; do
        if ! ping -c 2 -W 2 $dc.$DOMAIN > /dev/null 2>&1; then
            echo "$(date) - ❌ $dc.$DOMAIN offline" >> $LOG
        fi
    done
}

# Executar verificações
check_replication
check_dcs

# Verificar status do serviço
if ! systemctl is-active --quiet samba-ad-dc; then
    echo "$(date) - ❌ Serviço samba-ad-dc parado" >> $LOG
    systemctl restart samba-ad-dc
fi
EOF

    chmod +x /usr/local/bin/monitor_replication.sh
    log "✅ Script de monitoramento criado em /usr/local/bin/monitor_replication.sh"
}

# ============================================
# CONFIGURAR CRONTAB
# ============================================
configure_crontab() {
    log "Configurando crontab para monitoramento automático..."
    
    # Adicionar ao crontab se não existir
    if ! crontab -l 2>/dev/null | grep -q "monitor_replication.sh"; then
        (crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/monitor_replication.sh") | crontab -
        log "✅ Monitoramento agendado a cada 5 minutos"
    else
        log "ℹ️ Monitoramento já está agendado no crontab"
    fi
    
    # Adicionar replicação forçada a cada hora (opcional)
    if ! crontab -l 2>/dev/null | grep -q "drs replicate"; then
        (crontab -l 2>/dev/null; echo "0 * * * * samba-tool drs replicate $SECONDARY_HOST $PRIMARY_HOST $DOMAIN 2>/dev/null") | crontab -
        log "✅ Replicação forçada agendada a cada hora"
    fi
}

# ============================================
# SALVAR INFORMAÇÕES
# ============================================
save_info() {
    log "Salvando informações de configuração..."
    
    cat > /root/replication_info.txt << EOF
═══════════════════════════════════════════════════════════════════
            CONFIGURAÇÃO DE REPLICAÇÃO NATIVA
═══════════════════════════════════════════════════════════════════

DATA: $(date)
SERVIDOR: $(hostname) ($CURRENT_IP)
TIPO: $SERVER_TYPE

DOMÍNIO: $DOMAIN
REALM: $REALM
AD PRIMÁRIO: $PRIMARY_HOST ($PRIMARY_IP)
AD SECUNDÁRIO: $SECONDARY_HOST ($SECONDARY_IP)

───────────────────────────────────────────────────────────────────
STATUS DA REPLICAÇÃO
───────────────────────────────────────────────────────────────────
$(samba-tool drs showrepl 2>&1)

───────────────────────────────────────────────────────────────────
REGISTROS DNS
───────────────────────────────────────────────────────────────────
$(host -t SRV _ldap._tcp.$DOMAIN 2>&1)

───────────────────────────────────────────────────────────────────
COMANDOS ÚTEIS
───────────────────────────────────────────────────────────────────
# Verificar replicação
samba-tool drs showrepl

# Forçar replicação do primário para secundário
samba-tool drs replicate $SECONDARY_HOST $PRIMARY_HOST $DOMAIN -U administrator

# Forçar replicação do secundário para primário
samba-tool drs replicate $PRIMARY_HOST $SECONDARY_HOST $DOMAIN -U administrator

# Verificar DNS
host -t SRV _ldap._tcp.$DOMAIN

# Verificar usuários
samba-tool user list

───────────────────────────────────────────────────────────────────
MONITORAMENTO
───────────────────────────────────────────────────────────────────
Script: /usr/local/bin/monitor_replication.sh
Log: /var/log/replication_monitor.log
Crontab: A cada 5 minutos

═══════════════════════════════════════════════════════════════════
EOF

    log "✅ Informações salvas em /root/replication_info.txt"
}

# ============================================
# MOSTRAR RESUMO FINAL
# ============================================
show_summary() {
    clear
    echo -e "${GREEN}"
    echo "═══════════════════════════════════════════════════════════════════"
    echo "                                                                   "
    echo "         ✅ REPLICAÇÃO NATIVA CONFIGURADA COM SUCESSO!             "
    echo "                                                                   "
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "${NC}"
    echo ""
    echo -e "${BLUE}📋 RESUMO DA CONFIGURAÇÃO:${NC}"
    echo ""
    echo -e "  ${GREEN}✓${NC} Servidor identificado: $SERVER_TYPE"
    echo -e "  ${GREEN}✓${NC} /etc/resolv.conf configurado"
    echo -e "  ${GREEN}✓${NC} DNS verificado"
    echo -e "  ${GREEN}✓${NC} Replicação forçada executada"
    echo -e "  ${GREEN}✓${NC} Status da replicação verificado"
    echo -e "  ${GREEN}✓${NC} Teste de replicação realizado"
    echo -e "  ${GREEN}✓${NC} Script de monitoramento criado"
    echo -e "  ${GREEN}✓${NC} Crontab configurado"
    echo ""
    echo -e "${YELLOW}📌 IMPORTANTE:${NC}"
    echo ""
    echo -e "  ${YELLOW}▶${NC} Execute este script ${RED}EM AMBOS${NC} os servidores"
    echo -e "  ${YELLOW}▶${NC} A replicação agora é ${GREEN}AUTOMÁTICA${NC} e ${GREEN}BIDIRECIONAL${NC}"
    echo -e "  ${YELLOW}▶${NC} Monitoramento a cada ${BLUE}5 minutos${NC} via crontab"
    echo ""
    echo -e "${YELLOW}📁 ARQUIVOS CRIADOS:${NC}"
    echo ""
    echo -e "  /root/replication_info.txt - Informações completas"
    echo -e "  /var/log/replication_setup.log - Log da configuração"
    echo -e "  /var/log/replication_monitor.log - Log do monitoramento"
    echo -e "  /usr/local/bin/monitor_replication.sh - Script de monitoramento"
    echo ""
    echo -e "${YELLOW}🔧 COMANDOS ÚTEIS:${NC}"
    echo ""
    echo -e "  Verificar replicação:"
    echo -e "  ${BLUE}samba-tool drs showrepl${NC}"
    echo ""
    echo -e "  Forçar replicação manual:"
    echo -e "  ${BLUE}samba-tool drs replicate $SECONDARY_HOST $PRIMARY_HOST $DOMAIN${NC}"
    echo ""
    echo -e "  Verificar logs:"
    echo -e "  ${BLUE}tail -f /var/log/replication_monitor.log${NC}"
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                    FIM DA CONFIGURAÇÃO                           ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ============================================
# FUNÇÃO PRINCIPAL
# ============================================
main() {
    echo ""
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║                                                               ║"
    echo "║     CONFIGURAÇÃO DE REPLICAÇÃO NATIVA DO SAMBA AD            ║"
    echo "║                                                               ║"
    echo "║     Domínio: ${DOMAIN}                                        ║"
    echo "║     Primário: ${PRIMARY_HOST} (${PRIMARY_IP})                ║"
    echo "║     Secundário: ${SECONDARY_HOST} (${SECONDARY_IP})          ║"
    echo "║                                                               ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    # Executar configuração
    check_requirements
    identify_server
    get_admin_password
    configure_resolv
    check_dns
    configure_replication
    check_replication_status
    test_replication
    create_monitor_script
    configure_crontab
    save_info
    show_summary
    
    log "✅ Configuração concluída com sucesso!"
}

# ============================================
# EXECUTAR
# ============================================
main
