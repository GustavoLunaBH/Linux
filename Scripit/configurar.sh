#!/bin/bash

# ==============================================
# SCRIPT DE CONFIGURAÇÃO PÓS-FORMATAÇÃO LINUX
# ==============================================

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # Sem cor

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   CONFIGURAÇÃO PÓS-FORMATAÇÃO LINUX  ${NC}"
echo -e "${BLUE}========================================${NC}"

# ==============================================
# 0. DEFINIR SENHA DO ROOT (ANTES DE TUDO!)
# ==============================================
echo -e "\n${YELLOW}[0/9] DEFININDO SENHA DO ROOT...${NC}"
echo -e "${RED}⚠️  ATENÇÃO: Defina a senha do root agora para não perder o acesso!${NC}"

# Verifica se o script está sendo executado como root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Este script precisa ser executado como root!${NC}"
    echo -e "${YELLOW}Execute: sudo ./configurar.sh${NC}"
    exit 1
fi

# Verifica se o root já tem senha
ROOT_HAS_PASSWORD=$(grep "^root:" /etc/shadow | cut -d: -f2)

if [ -z "$ROOT_HAS_PASSWORD" ] || [ "$ROOT_HAS_PASSWORD" = "*" ] || [ "$ROOT_HAS_PASSWORD" = "!" ]; then
    echo -e "${YELLOW}⚠️  Root NÃO tem senha definida!${NC}"
    echo -e "${YELLOW}Por favor, defina a senha do root agora:${NC}"
    
    # Loop até a senha ser definida com sucesso
    while true; do
        passwd root
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ Senha do root definida com sucesso!${NC}"
            break
        else
            echo -e "${RED}❌ Falha ao definir senha. Tente novamente.${NC}"
        fi
    done
else
    echo -e "${GREEN}✅ Root já possui senha definida.${NC}"
fi

# ==============================================
# 1. IDENTIFICAR VERSÃO DO LINUX
# ==============================================
echo -e "\n${YELLOW}[1/9] IDENTIFICANDO VERSÃO DO LINUX...${NC}"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo -e "${GREEN}Distribuição: $NAME${NC}"
    echo -e "${GREEN}Versão: $VERSION_ID${NC}"
    echo -e "${GREEN}Nome: $PRETTY_NAME${NC}"
else
    echo -e "${RED}Sistema não suportado${NC}"
fi

# ==============================================
# 2. TRADUZIR SISTEMA PARA PORTUGUÊS
# ==============================================
echo -e "\n${YELLOW}[2/9] TRADUZINDO SISTEMA PARA PORTUGUÊS DO BRASIL...${NC}"

# Função para configurar idioma
configurar_idioma() {
    echo -e "${CYAN}Configurando locale para pt_BR.UTF-8...${NC}"
    
    # Detecta o gerenciador de pacotes
    if command -v apt &> /dev/null; then
        # Debian/Ubuntu
        echo -e "${GREEN}Configurando idioma no Debian/Ubuntu...${NC}"
        
        # Instala pacotes de idioma
        apt install -y language-pack-pt language-pack-pt-base language-pack-gnome-pt
        
        # Configura locale
        locale-gen pt_BR.UTF-8
        update-locale LANG=pt_BR.UTF-8 LC_ALL=pt_BR.UTF-8 LANGUAGE=pt_BR:pt
        
        # Define o locale
        echo "LANG=pt_BR.UTF-8" > /etc/default/locale
        echo "LC_ALL=pt_BR.UTF-8" >> /etc/default/locale
        echo "LANGUAGE=pt_BR:pt" >> /etc/default/locale
        
        # Configura o console
        echo "LANG=pt_BR.UTF-8" > /etc/environment
        
    elif command -v dnf &> /dev/null || command -v yum &> /dev/null; then
        # RHEL/CentOS/Fedora
        echo -e "${GREEN}Configurando idioma no RHEL/Fedora...${NC}"
        
        # Instala pacotes de idioma
        if command -v dnf &> /dev/null; then
            dnf install -y glibc-langpack-pt
        else
            yum install -y glibc-langpack-pt
        fi
        
        # Configura locale
        localectl set-locale LANG=pt_BR.UTF-8
        localectl set-keymap br-abnt2
        
    elif command -v pacman &> /dev/null; then
        # Arch Linux
        echo -e "${GREEN}Configurando idioma no Arch Linux...${NC}"
        
        # Descomenta pt_BR.UTF-8 no locale.gen
        sed -i 's/^#pt_BR.UTF-8/pt_BR.UTF-8/' /etc/locale.gen
        locale-gen
        
        # Configura
        echo "LANG=pt_BR.UTF-8" > /etc/locale.conf
        echo "LC_ALL=pt_BR.UTF-8" >> /etc/locale.conf
    fi
    
    # Configura timezone (já feito na parte NTP)
    timedatectl set-timezone America/Sao_Paulo
    
    # Configura o teclado para ABNT2
    echo -e "${CYAN}Configurando teclado para ABNT2 (Brasil)...${NC}"
    if command -v localectl &> /dev/null; then
        localectl set-keymap br-abnt2
        localectl set-x11-keymap br abnt2
    fi
    
    # Cria arquivo de configuração do console
    if [ -f /etc/default/keyboard ]; then
        cat > /etc/default/keyboard << EOF
XKBMODEL=pc105
XKBLAYOUT=br
XKBVARIANT=abnt2
XKBOPTIONS=
BACKSPACE=guess
EOF
    fi
    
    echo -e "${GREEN}✅ Sistema configurado para português do Brasil!${NC}"
}

# Executa a configuração de idioma
configurar_idioma

# ==============================================
# 3. ATUALIZAR O SISTEMA
# ==============================================
echo -e "\n${YELLOW}[3/9] ATUALIZANDO REPOSITÓRIOS E PACOTES...${NC}"

if command -v apt &> /dev/null; then
    echo -e "${GREEN}Gerenciador APT detectado (Debian/Ubuntu)${NC}"
    apt update -y
    apt upgrade -y
    apt dist-upgrade -y
    apt autoremove -y
    # Instala bc para conversão de máscara
    apt install -y bc
elif command -v dnf &> /dev/null; then
    echo -e "${GREEN}Gerenciador DNF detectado (Fedora/RHEL)${NC}"
    dnf update -y
    dnf upgrade -y
    dnf install -y bc
elif command -v yum &> /dev/null; then
    echo -e "${GREEN}Gerenciador YUM detectado (CentOS/RHEL)${NC}"
    yum update -y
    yum upgrade -y
    yum install -y bc
else
    echo -e "${RED}Nenhum gerenciador de pacotes conhecido encontrado!${NC}"
fi

# ==============================================
# 4. SINCRONIZAR DATA E HORA COM NTP BRASIL
# ==============================================
echo -e "\n${YELLOW}[4/9] SINCRONIZANDO DATA E HORA COM NTP.BR...${NC}"

if command -v timedatectl &> /dev/null; then
    echo -e "${GREEN}Usando timedatectl (systemd)${NC}"
    
    # Instala chrony se não tiver
    if ! command -v chronyc &> /dev/null; then
        echo -e "${YELLOW}Instalando chrony...${NC}"
        apt install chrony -y 2>/dev/null || yum install chrony -y 2>/dev/null
    fi
    
    # Configura timezone
    timedatectl set-timezone America/Sao_Paulo
    echo -e "${GREEN}Timezone definido: America/Sao_Paulo${NC}"
    
    # Configura servidores NTP do Brasil
    if command -v chronyc &> /dev/null; then
        CHRONY_CONF="/etc/chrony/chrony.conf"
        if [ -f "$CHRONY_CONF" ]; then
            cp "$CHRONY_CONF" "${CHRONY_CONF}.backup.$(date +%Y%m%d_%H%M%S)"
            sed -i '/^pool/d' "$CHRONY_CONF"
            sed -i '/^server/d' "$CHRONY_CONF"
            echo "server a.st1.ntp.br iburst" >> "$CHRONY_CONF"
            echo "server b.st1.ntp.br iburst" >> "$CHRONY_CONF"
            echo "server c.st1.ntp.br iburst" >> "$CHRONY_CONF"
            echo "pool pool.ntp.br iburst" >> "$CHRONY_CONF"
            
            systemctl restart chrony
            chronyc -a makestep
            echo -e "${GREEN}Chrony configurado com servidores NTP do Brasil${NC}"
        fi
    fi
    
    timedatectl set-ntp true
    echo -e "${GREEN}Data e hora atual: $(date)${NC}"
fi

# ==============================================
# 5. IDENTIFICAR IP ATUAL
# ==============================================
echo -e "\n${YELLOW}[5/9] IDENTIFICANDO IP ATUAL...${NC}"

CURRENT_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
if [ -z "$CURRENT_IP" ]; then
    CURRENT_IP=$(hostname -I | awk '{print $1}')
fi

if [ -n "$CURRENT_IP" ]; then
    echo -e "${GREEN}IP atual (DHCP): $CURRENT_IP${NC}"
else
    echo -e "${RED}Não foi possível identificar o IP atual${NC}"
fi

# ==============================================
# 6. ATIVAR ROOT NO SSH
# ==============================================
echo -e "\n${YELLOW}[6/9] ATIVANDO ACESSO ROOT NO SSH...${NC}"

SSH_CONFIG="/etc/ssh/sshd_config"

# Instala SSH se não existir
if [ ! -f "$SSH_CONFIG" ]; then
    echo -e "${YELLOW}Instalando SSH...${NC}"
    apt install openssh-server -y 2>/dev/null || yum install openssh-server -y 2>/dev/null
fi

if [ -f "$SSH_CONFIG" ]; then
    cp $SSH_CONFIG ${SSH_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)
    echo -e "${GREEN}Backup criado${NC}"
    
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' $SSH_CONFIG
    sed -i 's/^PermitRootLogin no/PermitRootLogin yes/' $SSH_CONFIG
    sed -i 's/^PermitRootLogin prohibit-password/PermitRootLogin yes/' $SSH_CONFIG
    
    if ! grep -q "^PermitRootLogin" $SSH_CONFIG; then
        echo "PermitRootLogin yes" >> $SSH_CONFIG
    fi
    
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null
    
    echo -e "${GREEN}Acesso root habilitado no SSH!${NC}"
fi

# ==============================================
# 7. FUNÇÃO PARA CONVERTER MÁSCARA PARA CIDR
# ==============================================
converter_mascara_para_cidr() {
    local MASCARA=$1
    
    # Se já veio com /, retorna como está
    if [[ "$MASCARA" =~ ^/[0-9]+$ ]]; then
        echo "$MASCARA"
        return 0
    fi
    
    # Se é apenas um número (ex: 24), adiciona a barra
    if [[ "$MASCARA" =~ ^[0-9]+$ ]] && [ "$MASCARA" -ge 0 ] && [ "$MASCARA" -le 32 ]; then
        echo "/$MASCARA"
        return 0
    fi
    
    # Se é uma máscara decimal (ex: 255.255.255.0)
    if [[ "$MASCARA" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        # Converte usando bc se disponível
        if command -v bc &> /dev/null; then
            IFS=. read -r i1 i2 i3 i4 <<< "$MASCARA"
            CIDR=$(echo "obase=2;$i1;$i2;$i3;$i4" | bc | tr -d '\n' | grep -o '1' | wc -l)
            echo "/$CIDR"
            return 0
        else
            # Fallback: tenta converter manualmente para máscaras comuns
            case "$MASCARA" in
                "255.0.0.0") echo "/8" ;;
                "255.255.0.0") echo "/16" ;;
                "255.255.255.0") echo "/24" ;;
                "255.255.255.128") echo "/25" ;;
                "255.255.255.192") echo "/26" ;;
                "255.255.255.224") echo "/27" ;;
                "255.255.255.240") echo "/28" ;;
                "255.255.255.248") echo "/29" ;;
                "255.255.255.252") echo "/30" ;;
                *) echo "/24" ;;  # Fallback padrão
            esac
            return 0
        fi
    fi
    
    # Fallback: assume /24
    echo "/24"
    return 0
}

# ==============================================
# 8. CONFIGURAR IP FIXO (POR ÚLTIMO!)
# ==============================================
echo -e "\n${YELLOW}[7/9] CONFIGURANDO IP FIXO...${NC}"

INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n 1)
if [ -z "$INTERFACE" ]; then
    INTERFACE=$(ip -4 addr show | grep -v 'lo' | grep -oP '(?<=: )\w+' | head -n 1)
fi

echo -e "${GREEN}Interface detectada: $INTERFACE${NC}"
echo -e "${YELLOW}IP atual (DHCP): $CURRENT_IP${NC}"

# Pergunta ao usuário os dados da rede (em português)
echo -e "${CYAN}Digite as configurações de rede:${NC}"
read -p "Digite o IP FIXO desejado (ex: 192.168.1.100): " FIXED_IP
read -p "Digite a MÁSCARA DE REDE (ex: 255.255.255.0 ou /24 ou apenas 24): " NETMASK
read -p "Digite o GATEWAY (ex: 192.168.1.1): " GATEWAY
read -p "Digite o DNS primário (ex: 8.8.8.8): " DNS1
read -p "Digite o DNS secundário (ex: 8.8.4.4): " DNS2

# Converte a máscara para formato CIDR
CIDR=$(converter_mascara_para_cidr "$NETMASK")
echo -e "${GREEN}Máscara convertida para: $CIDR${NC}"

# ==============================================
# CONFIGURA NETPLAN (Ubuntu 18.04+)
# ==============================================
if [ -d /etc/netplan ]; then
    echo -e "${GREEN}Configurando Netplan...${NC}"
    
    # Encontra o arquivo Netplan existente
    NETPLAN_FILE=""
    for file in 50-cloud-init.yaml 01-netcfg.yaml 00-installer-config.yaml 01-network-manager-all.yaml; do
        if [ -f "/etc/netplan/$file" ]; then
            NETPLAN_FILE="/etc/netplan/$file"
            break
        fi
    done
    
    # Se não encontrou, cria um novo
    if [ -z "$NETPLAN_FILE" ]; then
        NETPLAN_FILE="/etc/netplan/01-netcfg.yaml"
    fi
    
    # Backup
    BACKUP_FILE="${NETPLAN_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$NETPLAN_FILE" "$BACKUP_FILE" 2>/dev/null
    echo -e "${GREEN}Backup criado: $(basename "$BACKUP_FILE")${NC}"
    
    # Cria configuração
    cat > "$NETPLAN_FILE" << EOF
# Configuração gerada em $(date)
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE:
      dhcp4: false
      addresses:
        - $FIXED_IP$CIDR
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses: [$DNS1, $DNS2]
EOF
    
    echo -e "${GREEN}Arquivo Netplan atualizado: $(basename "$NETPLAN_FILE")${NC}"
    
    # Aplica a configuração
    echo -e "${YELLOW}Aplicando configuração Netplan...${NC}"
    netplan apply
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Configuração Netplan aplicada com sucesso!${NC}"
    else
        echo -e "${RED}Erro ao aplicar configuração Netplan.${NC}"
        echo -e "${YELLOW}Verificando sintaxe...${NC}"
        netplan generate
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}Sintaxe OK. Tentando aplicar novamente...${NC}"
            netplan apply --debug
        else
            echo -e "${RED}Erro de sintaxe no arquivo.${NC}"
            echo -e "${YELLOW}Conteúdo do arquivo:${NC}"
            cat "$NETPLAN_FILE"
        fi
    fi

# ==============================================
# CONFIGURA INTERFACES TRADICIONAL
# ==============================================
elif [ -f /etc/network/interfaces ]; then
    echo -e "${GREEN}Configurando /etc/network/interfaces...${NC}"
    
    BACKUP_FILE="/etc/network/interfaces.backup.$(date +%Y%m%d_%H%M%S)"
    cp /etc/network/interfaces "$BACKUP_FILE"
    echo -e "${GREEN}Backup criado: $(basename "$BACKUP_FILE")${NC}"
    
    # Remove configuração existente
    sed -i "/^iface $INTERFACE/,/^$/d" /etc/network/interfaces
    sed -i "/^auto $INTERFACE/d" /etc/network/interfaces
    
    # Adiciona nova configuração
    echo -e "\n# IP Fixo - $(date)" >> /etc/network/interfaces
    echo "auto $INTERFACE" >> /etc/network/interfaces
    echo "iface $INTERFACE inet static" >> /etc/network/interfaces
    echo "    address $FIXED_IP" >> /etc/network/interfaces
    echo "    netmask $NETMASK" >> /etc/network/interfaces
    echo "    gateway $GATEWAY" >> /etc/network/interfaces
    echo "    dns-nameservers $DNS1 $DNS2" >> /etc/network/interfaces
    
    systemctl restart networking 2>/dev/null || service networking restart
    echo -e "${GREEN}IP fixo configurado${NC}"
fi

# ==============================================
# 9. VERIFICAR SENHA DO ROOT (CONFIRMAÇÃO FINAL)
# ==============================================
echo -e "\n${YELLOW}[8/9] VERIFICANDO SENHA DO ROOT...${NC}"

# Verifica se o root tem senha definida
ROOT_HAS_PASSWORD=$(grep "^root:" /etc/shadow | cut -d: -f2)

if [ -z "$ROOT_HAS_PASSWORD" ] || [ "$ROOT_HAS_PASSWORD" = "*" ] || [ "$ROOT_HAS_PASSWORD" = "!" ]; then
    echo -e "${RED}❌ ATENÇÃO: Root NÃO tem senha definida!${NC}"
    echo -e "${YELLOW}Defina agora para não perder o acesso:${NC}"
    passwd root
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Senha do root definida com sucesso!${NC}"
    else
        echo -e "${RED}❌ Falha crítica! Você pode perder o acesso ao servidor.${NC}"
        echo -e "${YELLOW}Execute manualmente depois: sudo passwd root${NC}"
    fi
else
    echo -e "${GREEN}✅ Root possui senha definida.${NC}"
fi

# ==============================================
# 10. LISTAR ARQUIVOS MODIFICADOS
# ==============================================
echo -e "\n${YELLOW}[9/9] RESUMO DOS ARQUIVOS MODIFICADOS...${NC}"

echo -e "${BLUE}Arquivos modificados/backups criados:${NC}"
if [ -d /etc/netplan ]; then
    echo -e "  • Netplan: $(ls -la /etc/netplan/*.yaml 2>/dev/null | awk '{print $9}')"
    echo -e "  • Backups: $(ls -la /etc/netplan/*.backup.* 2>/dev/null | awk '{print $9}')"
elif [ -f /etc/network/interfaces ]; then
    echo -e "  • Interfaces: /etc/network/interfaces"
    echo -e "  • Backups: $(ls -la /etc/network/interfaces.backup.* 2>/dev/null | awk '{print $9}')"
fi

if [ -f /etc/ssh/sshd_config ]; then
    echo -e "  • SSH Config: /etc/ssh/sshd_config"
    echo -e "  • Backups: $(ls -la /etc/ssh/sshd_config.backup.* 2>/dev/null | awk '{print $9}')"
fi

# ==============================================
# FINALIZAÇÃO
# ==============================================
echo -e "\n${BLUE}========================================${NC}"
echo -e "${GREEN}✅ CONFIGURAÇÃO CONCLUÍDA COM SUCESSO!${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "${YELLOW}Resumo:${NC}"
echo -e "  • Sistema: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo "N/A")"
echo -e "  • Idioma: Português do Brasil (pt_BR.UTF-8)"
echo -e "  • Teclado: ABNT2 (Brasil)"
echo -e "  • Data/Hora: $(date)"
echo -e "  • Timezone: America/Sao_Paulo"
echo -e "  • IP Antigo (DHCP): $CURRENT_IP"
echo -e "  • IP Novo Fixo: $FIXED_IP"
echo -e "  • Gateway: $GATEWAY"
echo -e "  • Interface: $INTERFACE"
echo -e "  • Root SSH: Habilitado"
echo -e "  • Senha Root: $([ -n "$ROOT_HAS_PASSWORD" ] && [ "$ROOT_HAS_PASSWORD" != "*" ] && [ "$ROOT_HAS_PASSWORD" != "!" ] && echo "✅ Definida" || echo "❌ NÃO DEFINIDA!")"

echo -e "\n${RED}========================================================${NC}"
echo -e "${RED}⚠️  ATENÇÃO: A CONEXÃO SSH SERÁ PERDIDA AGORA! ⚠️${NC}"
echo -e "${RED}========================================================${NC}"
echo -e "${YELLOW}Reconecte-se usando:${NC}"
echo -e "${BLUE}  ssh root@$FIXED_IP${NC}"
echo -e "${BLUE}  ssh linux@$FIXED_IP${NC}"

echo -e "\n${YELLOW}✅ A senha do root já foi definida durante a execução do script.${NC}"
echo -e "${YELLOW}   Use-a para fazer login como root.${NC}"

echo -e "\n${BLUE}Recomendação: Reinicie o sistema para aplicar todas as mudanças.${NC}"
echo -e "${BLUE}  sudo reboot${NC}\n"
