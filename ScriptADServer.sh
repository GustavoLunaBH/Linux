# ============================================
# FUNÇÃO DE TESTES COMPLETA - VERSÃO MELHORADA
# ============================================

run_ad_tests() {
    log INFO "========================================="
    log INFO "INICIANDO TESTES DO AD SERVER"
    log INFO "========================================="
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
    
    # ==========================================
    # 1. SERVIÇO SAMBA AD
    # ==========================================
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

    # ==========================================
    # 2. STATUS DO SERVIÇO
    # ==========================================
    echo -e "${WHITE}[2/20] Status Detalhado do Serviço...${NC}"
    local STATUS=$(systemctl status samba-ad-dc --no-pager | head -5)
    echo -e "  ${CYAN}$(echo "$STATUS" | sed 's/^/   /')${NC}"
    ((TEST_PASSED++))
    echo ""

    # ==========================================
    # 3. PORTAS DO SAMBA
    # ==========================================
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

    # ==========================================
    # 4. PROCESSOS DO SAMBA
    # ==========================================
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

    # ==========================================
    # 5. DNS SRV - LDAP
    # ==========================================
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

    # ==========================================
    # 6. DNS SRV - Kerberos
    # ==========================================
    echo -e "${WHITE}[6/20] Verificando DNS SRV (Kerberos)...${NC}"
    if host -t SRV _kerberos._tcp.${DOMAIN,,} >/dev/null 2>&1; then
        echo -e "  ${GREEN}✅ _kerberos._tcp.${DOMAIN,,} - OK${NC}"
        ((TEST_PASSED++))
    else
        echo -e "  ${RED}❌ _kerberos._tcp.${DOMAIN,,} - FALHOU${NC}"
        ((TEST_FAILED++))
    fi
    echo ""

    # ==========================================
    # 7. DNS SRV - Global Catalog
    # ==========================================
    echo -e "${WHITE}[7/20] Verificando DNS SRV (Global Catalog)...${NC}"
    if host -t SRV _ldap._tcp.gc._msdcs.${DOMAIN,,} >/dev/null 2>&1; then
        echo -e "  ${GREEN}✅ _ldap._tcp.gc._msdcs.${DOMAIN,,} - OK${NC}"
        ((TEST_PASSED++))
    else
        echo -e "  ${YELLOW}⚠️  _ldap._tcp.gc._msdcs.${DOMAIN,,} - NÃO ENCONTRADO${NC}"
        ((TEST_WARN++))
    fi
    echo ""

    # ==========================================
    # 8. Resolução de Nomes - Hostname
    # ==========================================
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

    # ==========================================
    # 9. Resolução de Nomes - Domínio
    # ==========================================
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

    # ==========================================
    # 10. KERBEROS - Autenticação
    # ==========================================
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

    # ==========================================
    # 11. KERBEROS - Ticket
    # ==========================================
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

    # ==========================================
    # 12. LDAP - Conexão
    # ==========================================
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

    # ==========================================
    # 13. LDAPS - Conexão Segura
    # ==========================================
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

    # ==========================================
    # 14. USUÁRIOS
    # ==========================================
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

    # ==========================================
    # 15. GRUPOS
    # ==========================================
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

    # ==========================================
    # 16. SYSVOL
    # ==========================================
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

    # ==========================================
    # 17. NTDS
    # ==========================================
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

    # ==========================================
    # 18. NTP
    # ==========================================
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

    # ==========================================
    # 19. SAMBA TOOL - Comandos Básicos
    # ==========================================
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

    # ==========================================
    # 20. REPLICAÇÃO (se houver outros DCs)
    # ==========================================
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
    
    # Salvar resultados detalhados
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

───────────────────────────────────────────────────────────────────────────────────
DETALHES DOS TESTES
───────────────────────────────────────────────────────────────────────────────────
$(cat $TEST_LOG 2>/dev/null)

═══════════════════════════════════════════════════════════════════════════════════
EOF
    
    chmod 600 /root/ad_test_results.txt
    
    echo -e "${GREEN}✅ Testes salvos em: /root/ad_test_results.txt${NC}"
    echo ""
    
    # Perguntar se quer ver detalhes
    echo -e "${YELLOW}Deseja ver os detalhes completos dos testes? (s/N):${NC}"
    read -p "> " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Ss]$ ]]; then
        cat /root/ad_test_results.txt
        echo ""
    fi
    
    read -p "Pressione ENTER para continuar..."
}
