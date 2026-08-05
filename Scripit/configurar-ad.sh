#!/bin/bash

# ==============================================
# SCRIPT DE CONFIGURAÇÃO DO ACTIVE DIRECTORY
# COM SAMBA NO LINUX
# ==============================================

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   CONFIGURAÇÃO DO ACTIVE DIRECTORY    ${NC}"
echo -e "${BLUE}   COM SAMBA NO LINUX                  ${NC}"
echo -e "${BLUE}========================================${NC}"

# Verifica se é root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Este script precisa ser executado como root!${NC}"
    echo -e "${YELLOW}Execute: sudo ./configurar-ad.sh${NC}"
    exit 1
fi

# ==============================================
# 1. IDENTIFICAR SISTEMA
# ==============================================
echo -e "\n${YELLOW}[1/7] IDENTIFICANDO SISTEMA...${NC}"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo -e "${GREEN}Distribuição: $NAME${NC}"
    echo -e "${GREEN}Versão: $VERSION_ID${NC}"
else
    echo -e "${RED}Sistema não suportado${NC}"
    exit 1
fi

# Detecta gerenciador de pacotes
if command -v apt &> /dev/null; then
    PKG_MANAGER="apt"
    PKG_INSTALL="apt install -y"
    PKG_UPDATE="apt update -y"
    echo -e "${GREEN}Gerenciador: APT (Debian/Ubuntu)${NC}"
elif command -v dnf &> /dev/null; then
    PKG_MANAGER="dnf"
    PKG_INSTALL="dnf install -y"
    PKG_UPDATE="dnf update -y"
    echo -e "${GREEN}Gerenciador: DNF (Fedora/RHEL)${NC}"
elif command -v yum &> /dev/null; then
    PKG_MANAGER="yum"
    PKG_INSTALL="yum install -y"
    PKG_UPDATE="yum update -y"
    echo -e "${GREEN}Gerenciador: YUM (CentOS/RHEL)${NC}"
else
    echo -e "${RED}Nenhum gerenciador de pacotes conhecido!${NC}"
    exit 1
fi

# ==============================================
# 2. COLETAR INFORMAÇÕES DO DOMÍNIO
# ==============================================
echo -e "\n${YELLOW}[2/7] INFORMAÇÕES DO DOMÍNIO...${NC}"

read -p "Nome do DOMÍNIO DNS (ex: meudominio.local): " DNS_DOMAIN
read -p "Nome NETBIOS do domínio (ex: MEUDOMINIO): " NETBIOS_DOMAIN
read -p "Nome do HOST (ex: dc01): " HOSTNAME
read -p "IP FIXO do servidor (ex: 192.168.1.10): " SERVER_IP
read -p "Gateway (ex: 192.168.1.1): " GATEWAY
read -p "DNS Forwarder (ex: 8.8.8.8): " DNS_FORWARDER

# Converte domínio para maiúsculas (Realm)
REALM=$(echo "$DNS_DOMAIN" | tr '[:lower:]' '[:upper:]')
NETBIOS=$(echo "$NETBIOS_DOMAIN" | tr '[:lower:]' '[:upper:]')

echo -e "\n${CYAN}Resumo da configuração:${NC}"
echo -e "  • Domínio DNS: $DNS_DOMAIN"
echo -e "  • Realm Kerberos: $REALM"
echo -e "  • Domínio NetBIOS: $NETBIOS"
echo -e "  • Hostname: $HOSTNAME"
echo -e "  • IP do Servidor: $SERVER_IP"
echo -e "  • Gateway: $GATEWAY"
echo -e "  • DNS Forwarder: $DNS_FORWARDER"

read -p "Confirmar? (s/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Ss]$ ]]; then
    echo -e "${RED}Configuração cancelada.${NC}"
    exit 0
fi

# ==============================================
# 3. CONFIGURAR HOSTNAME E HOSTS
# ==============================================
echo -e "\n${YELLOW}[3/7] CONFIGURANDO HOSTNAME E /ETC/HOSTS...${NC}"

# Define hostname
hostnamectl set-hostname "$HOSTNAME.$DNS_DOMAIN"
echo -e "${GREEN}Hostname definido: $HOSTNAME.$DNS_DOMAIN${NC}"

# Configura /etc/hosts
cat > /etc/hosts << EOF
127.0.0.1       localhost.localdomain localhost
$SERVER_IP      $HOSTNAME.$DNS_DOMAIN $HOSTNAME
EOF
echo -e "${GREEN}/etc/hosts configurado${NC}"

# ==============================================
# 4. INSTALAR PACOTES
# ==============================================
echo -e "\n${YELLOW}[4/7] INSTALANDO PACOTES...${NC}"

if [ "$PKG_MANAGER" = "apt" ]; then
    $PKG_UPDATE
    $PKG_INSTALL samba krb5-user winbind libnss-winbind libpam-winbind \
        samba-dsdb-modules acl attr samba-vfs-modules smbclient \
        dnsutils chrony net-tools bc
else
    $PKG_UPDATE
    $PKG_INSTALL samba krb5-workstation winbind libnss-winbind \
        pam_krb5 acl attr samba-client dnsutils chrony net-tools bc
fi

echo -e "${GREEN}Pacotes instalados com sucesso!${NC}"

# ==============================================
# 5. CONFIGURAR DNS (resolv.conf)
# ==============================================
echo -e "\n${YELLOW}[5/7] CONFIGURANDO DNS...${NC}"

# Para sistemas com systemd-resolved
if systemctl is-active --quiet systemd-resolved; then
    systemctl stop systemd-resolved
    systemctl disable systemd-resolved
fi

# Remove link simbólico se existir
if [ -L /etc/resolv.conf ]; then
    rm -f /etc/resolv.conf
fi

# Cria novo resolv.conf
cat > /etc/resolv.conf << EOF
search $DNS_DOMAIN
nameserver $SERVER_IP
nameserver $DNS_FORWARDER
EOF

# Trava o arquivo para evitar alterações
chattr +i /etc/resolv.conf 2>/dev/null || echo -e "${YELLOW}Não foi possível travar o resolv.conf${NC}"

echo -e "${GREEN}/etc/resolv.conf configurado${NC}"

# ==============================================
# 6. PROVISIONAR O DOMÍNIO
# ==============================================
echo -e "\n${YELLOW}[6/7] PROVISIONANDO O DOMÍNIO...${NC}"

# Para serviços existentes
systemctl stop smbd nmbd winbind 2>/dev/null
systemctl disable smbd nmbd winbind 2>/dev/null

# Backup da configuração existente
if [ -f /etc/samba/smb.conf ]; then
    cp /etc/samba/smb.conf /etc/samba/smb.conf.bak.$(date +%Y%m%d_%H%M%S)
    echo -e "${GREEN}Backup do smb.conf criado${NC}"
fi

# Remove arquivo de configuração antigo
rm -f /etc/samba/smb.conf

# Provisiona o domínio [citation:1][citation:6]
echo -e "${CYAN}Iniciando provisionamento...${NC}"
echo -e "${YELLOW}Responda às perguntas abaixo:${NC}"
echo -e "  • Realm: $REALM"
echo -e "  • Domain: $NETBIOS"
echo -e "  • Server Role: dc"
echo -e "  • DNS backend: SAMBA_INTERNAL"
echo -e "  • DNS forwarder: $DNS_FORWARDER"
echo ""

samba-tool domain provision --use-rfc2307 --interactive

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Falha no provisionamento!${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Domínio provisionado com sucesso!${NC}"

# ==============================================
# 7. CONFIGURAR SERVIÇOS
# ==============================================
echo -e "\n${YELLOW}[7/7] CONFIGURANDO SERVIÇOS...${NC}"

# 7.1 Configurar Kerberos
echo -e "${CYAN}Configurando Kerberos...${NC}"
if [ -f /etc/krb5.conf ]; then
    mv /etc/krb5.conf /etc/krb5.conf.bak.$(date +%Y%m%d_%H%M%S)
fi
ln -sf /var/lib/samba/private/krb5.conf /etc/krb5.conf
echo -e "${GREEN}Kerberos configurado${NC}"

# 7.2 Configurar Chrony/NTP [citation:1][citation:6]
echo -e "${CYAN}Configurando NTP...${NC}"

# Configura o socket de assinatura NTP para Samba
if [ -d /var/lib/samba/ntp_signd ]; then
    chown root:ntp /var/lib/samba/ntp_signd 2>/dev/null || chown root:chrony /var/lib/samba/ntp_signd 2>/dev/null
    chmod 0750 /var/lib/samba/ntp_signd
fi

# Configura Chrony
if [ -f /etc/chrony/chrony.conf ]; then
    echo -e "\n# Configuração para Samba AD - Adicionada em $(date)" >> /etc/chrony/chrony.conf
    echo "allow $SERVER_IP/24" >> /etc/chrony/chrony.conf
    echo "ntpsigndsocket /var/lib/samba/ntp_signd" >> /etc/chrony/chrony.conf
    
    systemctl restart chrony
    echo -e "${GREEN}Chrony configurado${NC}"
fi

# 7.3 Iniciar serviços do Samba AD
echo -e "${CYAN}Iniciando serviços do Samba AD...${NC}"

systemctl unmask samba-ad-dc 2>/dev/null
systemctl enable samba-ad-dc
systemctl start samba-ad-dc

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Samba AD-DC iniciado com sucesso!${NC}"
else
    echo -e "${RED}❌ Falha ao iniciar Samba AD-DC${NC}"
    systemctl status samba-ad-dc
fi

# ==============================================
# 8. VERIFICAÇÕES
# ==============================================
echo -e "\n${YELLOW}VERIFICANDO CONFIGURAÇÃO...${NC}"

# Verifica DNS SRV records
echo -e "${CYAN}Verificando registros DNS...${NC}"
host -t SRV _kerberos._udp."$DNS_DOMAIN"
host -t SRV _ldap._tcp."$DNS_DOMAIN"

# Verifica administrador
echo -e "${CYAN}Verificando usuário Administrator...${NC}"
samba-tool user show Administrator 2>/dev/null
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Usuário Administrator encontrado${NC}"
else
    echo -e "${RED}❌ Erro ao verificar Administrator${NC}"
fi

# ==============================================
# 9. CRIAR USUÁRIO ADMIN UNICODE (opcional)
# ==============================================
echo -e "\n${YELLOW}Criar usuário admin com suporte a RFC2307? (s/N)${NC}"
read -p "> " CREATE_ADMIN

if [[ "$CREATE_ADMIN" =~ ^[Ss]$ ]]; then
    read -p "Nome do novo admin: " NEW_ADMIN
    read -s -p "Senha: " NEW_ADMIN_PASS
    echo ""
    
    samba-tool user create "$NEW_ADMIN" "$NEW_ADMIN_PASS"
    samba-tool group addmembers "Domain Admins" "$NEW_ADMIN"
    samba-tool group addmembers "Enterprise Admins" "$NEW_ADMIN"
    
    echo -e "${GREEN}✅ Usuário $NEW_ADMIN criado com privilégios de administrador${NC}"
fi

# ==============================================
# 10. CRIAR GRUPOS E OU PADRÃO [citation:6]
# ==============================================
echo -e "\n${YELLOW}Criar estrutura básica de grupos e OUs? (s/N)${NC}"
read -p "> " CREATE_STRUCTURE

if [[ "$CREATE_STRUCTURE" =~ ^[Ss]$ ]]; then
    echo -e "${CYAN}Criando grupos padrão...${NC}"
    samba-tool group addunixattrs "Domain Admins" 1001 2>/dev/null
    samba-tool group addunixattrs "Enterprise Admins" 1002 2>/dev/null
    samba-tool group create "TI" 2>/dev/null
    samba-tool group create "RH" 2>/dev/null
    samba-tool group create "Financeiro" 2>/dev/null
    
    echo -e "${CYAN}Criando OUs...${NC}"
    samba-tool ou create "OU=Servidores,$(samba-tool domain info 127.0.0.1 | grep "DN" | cut -d: -f2 | xargs)" 2>/dev/null
    samba-tool ou create "OU=Estacoes,$(samba-tool domain info 127.0.0.1 | grep "DN" | cut -d: -f2 | xargs)" 2>/dev/null
    samba-tool ou create "OU=Usuarios,$(samba-tool domain info 127.0.0.1 | grep "DN" | cut -d: -f2 | xargs)" 2>/dev/null
    
    echo -e "${GREEN}✅ Estrutura básica criada${NC}"
fi

# ==============================================
# 11. FINALIZAÇÃO
# ==============================================
echo -e "\n${BLUE}========================================${NC}"
echo -e "${GREEN}✅ CONFIGURAÇÃO DO AD CONCLUÍDA!${NC}"
echo -e "${BLUE}========================================${NC}"

echo -e "${YELLOW}Resumo:${NC}"
echo -e "  • Domínio: $DNS_DOMAIN"
echo -e "  • Realm: $REALM"
echo -e "  • IP do Servidor: $SERVER_IP"
echo -e "  • Hostname: $HOSTNAME.$DNS_DOMAIN"

echo -e "\n${CYAN}Comandos úteis:${NC}"
echo -e "  • Verificar status: systemctl status samba-ad-dc"
echo -e "  • Listar usuários: wbinfo -u"
echo -e "  • Listar grupos: wbinfo -g"
echo -e "  • Testar autenticação: kinit Administrator"

echo -e "\n${RED}⚠️  ATENÇÃO:${NC}"
echo -e "  • O servidor DEVE ter IP fixo: $SERVER_IP"
echo -e "  • Os clientes devem usar este servidor como DNS"
echo -e "  • A senha do Administrator foi definida durante o provisionamento"
echo -e "  • Para gerenciar via RSAT, use o IP $SERVER_IP"

echo -e "\n${BLUE}Recomendação: Reinicie o servidor para garantir que tudo funcione.${NC}"
echo -e "${BLUE}  sudo reboot${NC}\n"
