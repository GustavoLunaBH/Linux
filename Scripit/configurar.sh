#!/bin/bash

# ==============================================
# SCRIPT DE CONFIGURAÇÃO PÓS-FORMATAÇÃO LINUX
# ==============================================

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Sem cor

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   CONFIGURAÇÃO PÓS-FORMATAÇÃO LINUX  ${NC}"
echo -e "${BLUE}========================================${NC}"

# ==============================================
# 1. IDENTIFICAR VERSÃO DO LINUX
# ==============================================
echo -e "\n${YELLOW}[1/7] IDENTIFICANDO VERSÃO DO LINUX...${NC}"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo -e "${GREEN}Distribuição: $NAME${NC}"
    echo -e "${GREEN}Versão: $VERSION_ID${NC}"
    echo -e "${GREEN}Nome: $PRETTY_NAME${NC}"
else
    echo -e "${RED}Sistema não suportado ou arquivo /etc/os-release não encontrado${NC}"
fi

# ==============================================
# 2. ATUALIZAR O SISTEMA
# ==============================================
echo -e "\n${YELLOW}[2/7] ATUALIZANDO REPOSITÓRIOS E PACOTES...${NC}"

# Detecta o gerenciador de pacotes
if command -v apt &> /dev/null; then
    echo -e "${GREEN}Gerenciador APT detectado (Debian/Ubuntu)${NC}"
    apt update -y
    apt upgrade -y
    apt dist-upgrade -y
    apt autoremove -y
elif command -v dnf &> /dev/null; then
    echo -e "${GREEN}Gerenciador DNF detectado (Fedora/RHEL)${NC}"
    dnf update -y
    dnf upgrade -y
elif command -v yum &> /dev/null; then
    echo -e "${GREEN}Gerenciador YUM detectado (CentOS/RHEL)${NC}"
    yum update -y
    yum upgrade -y
elif command -v zypper &> /dev/null; then
    echo -e "${GREEN}Gerenciador Zypper detectado (OpenSUSE)${NC}"
    zypper refresh
    zypper update -y
elif command -v pacman &> /dev/null; then
    echo -e "${GREEN}Gerenciador Pacman detectado (Arch Linux)${NC}"
    pacman -Syu --noconfirm
else
    echo -e "${RED}Nenhum gerenciador de pacotes conhecido encontrado!${NC}"
fi

# ==============================================
# 3. SINCRONIZAR DATA E HORA COM NTP BRASIL
# ==============================================
echo -e "\n${YELLOW}[3/7] SINCRONIZANDO DATA E HORA COM NTP.BR...${NC}"

# Servidores NTP do Brasil (ntp.br)
NTP_SERVERS=(
    "a.st1.ntp.br"
    "b.st1.ntp.br"
    "c.st1.ntp.br"
    "d.st1.ntp.br"
    "gps.ntp.br"
    "pool.ntp.br"
)

# Função para configurar NTP no sistema
configurar_ntp() {
    echo -e "${YELLOW}Configurando servidores NTP do Brasil...${NC}"
    
    # Detecta o sistema e configura
    if command -v timedatectl &> /dev/null; then
        # systemd (maioria das distribuições modernas)
        echo -e "${GREEN}Usando timedatectl (systemd)${NC}"
        
        # Instala ntp ou chrony se necessário
        if ! command -v chronyc &> /dev/null && ! command -v ntpq &> /dev/null; then
            echo -e "${YELLOW}Instalando chrony (recomendado)...${NC}"
            if command -v apt &> /dev/null; then
                apt install chrony -y
            elif command -v dnf &> /dev/null; then
                dnf install chrony -y
            elif command -v yum &> /dev/null; then
                yum install chrony -y
            elif command -v pacman &> /dev/null; then
                pacman -S chrony --noconfirm
            fi
        fi
        
        # Configura timezone para America/Sao_Paulo
        timedatectl set-timezone America/Sao_Paulo
        echo -e "${GREEN}Timezone definido: America/Sao_Paulo${NC}"
        
        # Configura servidores NTP
        if command -v chronyc &> /dev/null; then
            # Chrony - configuração moderna
            CHRONY_CONF="/etc/chrony/chrony.conf"
            if [ -f "$CHRONY_CONF" ]; then
                cp "$CHRONY_CONF" "${CHRONY_CONF}.backup.$(date +%Y%m%d_%H%M%S)"
                # Remove servidores antigos
                sed -i '/^pool/d' "$CHRONY_CONF"
                sed -i '/^server/d' "$CHRONY_CONF"
                # Adiciona servidores do Brasil
                for server in "${NTP_SERVERS[@]}"; do
                    echo "server $server iburst" >> "$CHRONY_CONF"
                done
                # Adiciona pool como fallback
                echo "pool pool.ntp.br iburst" >> "$CHRONY_CONF"
                
                systemctl restart chrony
                chronyc -a makestep
                echo -e "${GREEN}Chrony configurado com servidores NTP do Brasil${NC}"
            fi
        elif command -v ntpq &> /dev/null; then
            # NTP tradicional
            NTP_CONF="/etc/ntp.conf"
            if [ -f "$NTP_CONF" ]; then
                cp "$NTP_CONF" "${NTP_CONF}.backup.$(date +%Y%m%d_%H%M%S)"
                sed -i '/^server/d' "$NTP_CONF"
                sed -i '/^pool/d' "$NTP_CONF"
                for server in "${NTP_SERVERS[@]}"; do
                    echo "server $server" >> "$NTP_CONF"
                done
                echo "pool pool.ntp.br" >> "$NTP_CONF"
                
                systemctl restart ntp
                echo -e "${GREEN}NTP configurado com servidores do Brasil${NC}"
            fi
        fi
        
        # Força sincronização imediata
        timedatectl set-ntp true
        timedatectl status
        
        # Sincroniza agora
        if command -v chronyc &> /dev/null; then
            chronyc -a makestep
        elif command -v ntpdate &> /dev/null; then
            ntpdate -u a.st1.ntp.br
        fi
        
    elif [ -f /etc/debian_version ] || [ -f /etc/ubuntu_version ]; then
        # Debian/Ubuntu tradicional sem systemd
        echo -e "${GREEN}Configurando NTP para Debian/Ubuntu tradicional${NC}"
        
        # Instala ntpdate se não tiver
        if ! command -v ntpdate &> /dev/null; then
            apt install ntpdate -y
        fi
        
        # Sincroniza com servidores do Brasil
        ntpdate -u a.st1.ntp.br
        ntpdate -u b.st1.ntp.br
        
        # Configura /etc/default/ntpdate
        echo -e "${YELLOW}Configurando ntpdate para usar servidores do Brasil...${NC}"
        sed -i 's/^NTPSERVERS=.*/NTPSERVERS="a.st1.ntp.br b.st1.ntp.br c.st1.ntp.br"/' /etc/default/ntpdate
        
        # Configura cron para sincronizar diariamente
        echo "0 3 * * * /usr/sbin/ntpdate -u a.st1.ntp.br" >> /etc/crontab
        echo -e "${GREEN}Sincronização agendada diariamente às 3h${NC}"
        
    elif [ -f /etc/redhat-release ]; then
        # RHEL/CentOS/Fedora
        echo -e "${GREEN}Configurando NTP para RHEL/CentOS/Fedora${NC}"
        
        if command -v chrony &> /dev/null; then
            CHRONY_CONF="/etc/chrony.conf"
            if [ -f "$CHRONY_CONF" ]; then
                cp "$CHRONY_CONF" "${CHRONY_CONF}.backup.$(date +%Y%m%d_%H%M%S)"
                sed -i '/^server/d' "$CHRONY_CONF"
                for server in "${NTP_SERVERS[@]}"; do
                    echo "server $server iburst" >> "$CHRONY_CONF"
                done
                systemctl restart chronyd
                chronyc -a makestep
                echo -e "${GREEN}Chrony configurado com servidores NTP do Brasil${NC}"
            fi
        else
            # Instala chrony se não tiver
            yum install chrony -y
            systemctl enable chronyd
            systemctl start chronyd
        fi
    fi
    
    echo -e "${GREEN}Sincronização de data/hora concluída!${NC}"
}

# Executa a configuração NTP
configurar_ntp

# Mostra data/hora atual
echo -e "\n${GREEN}Data e hora atual: $(date)${NC}"
echo -e "${GREEN}Timezone: $(timedatectl 2>/dev/null | grep "Time zone" || echo "N/A")${NC}"

# ==============================================
# 4. IDENTIFICAR IP ATUAL (apenas para referência)
# ==============================================
echo -e "\n${YELLOW}[4/7] IDENTIFICANDO IP ATUAL...${NC}"

# IP da interface principal (excluindo loopback)
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
# 5. ATIVAR ROOT NO SSH (antes do IP fixo)
# ==============================================
echo -e "\n${YELLOW}[5/7] ATIVANDO ACESSO ROOT NO SSH...${NC}"

SSH_CONFIG="/etc/ssh/sshd_config"

# Verifica se o arquivo existe
if [ ! -f "$SSH_CONFIG" ]; then
    echo -e "${RED}Arquivo $SSH_CONFIG não encontrado! Instale o SSH primeiro.${NC}"
    echo -e "${YELLOW}Instalando SSH...${NC}"
    
    if command -v apt &> /dev/null; then
        apt install openssh-server -y
    elif command -v dnf &> /dev/null; then
        dnf install openssh-server -y
    elif command -v yum &> /dev/null; then
        yum install openssh-server -y
    elif command -v pacman &> /dev/null; then
        pacman -S openssh --noconfirm
    fi
fi

if [ -f "$SSH_CONFIG" ]; then
    # Faz backup do arquivo original
    cp $SSH_CONFIG ${SSH_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)
    echo -e "${GREEN}Backup criado: ${SSH_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)${NC}"
    
    # Ativa root login
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' $SSH_CONFIG
    sed -i 's/^PermitRootLogin no/PermitRootLogin yes/' $SSH_CONFIG
    sed -i 's/^PermitRootLogin prohibit-password/PermitRootLogin yes/' $SSH_CONFIG
    
    # Se não encontrou a linha, adiciona no final
    if ! grep -q "^PermitRootLogin" $SSH_CONFIG; then
        echo "PermitRootLogin yes" >> $SSH_CONFIG
    fi
    
    # Reinicia o serviço SSH
    if command -v systemctl &> /dev/null; then
        systemctl restart ssh
        systemctl restart sshd
        systemctl enable ssh
        systemctl enable sshd
    else
        service ssh restart
        service sshd restart
    fi
    
    echo -e "${GREEN}Acesso root habilitado no SSH!${NC}"
    echo -e "${YELLOW}⚠️  LEMBRE-SE: Defina a senha do root com: sudo passwd root${NC}"
else
    echo -e "${RED}Falha ao configurar SSH${NC}"
fi

# ==============================================
# 6. LISTAR ARQUIVOS MODIFICADOS (antes do IP fixo)
# ==============================================
echo -e "\n${YELLOW}[6/7] RESUMO DOS ARQUIVOS MODIFICADOS...${NC}"

echo -e "${BLUE}Arquivos modificados/backups criados:${NC}"
if [ -f /etc/ssh/sshd_config ]; then
    echo -e "  • SSH Config: /etc/ssh/sshd_config"
    echo -e "  • Backups: $(ls -la /etc/ssh/sshd_config.backup.* 2>/dev/null | awk '{print $9}')"
fi

# ==============================================
# 7. CONFIGURAR IP FIXO (POR ÚLTIMO!)
# ==============================================
echo -e "\n${YELLOW}[7/7] CONFIGURANDO IP FIXO...${NC}"

# Detecta a interface de rede principal
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n 1)

if [ -z "$INTERFACE" ]; then
    INTERFACE=$(ip -4 addr show | grep -v 'lo' | grep -oP '(?<=: )\w+' | head -n 1)
fi

echo -e "${GREEN}Interface detectada: $INTERFACE${NC}"
echo -e "${YELLOW}IP atual (DHCP): $CURRENT_IP${NC}"

# Pergunta ao usuário os dados da rede
read -p "Digite o IP FIXO desejado (ex: 192.168.1.100): " FIXED_IP
read -p "Digite a MÁSCARA DE REDE (ex: 255.255.255.0 ou /24): " NETMASK
read -p "Digite o GATEWAY (ex: 192.168.1.1): " GATEWAY
read -p "Digite o DNS primário (ex: 8.8.8.8): " DNS1
read -p "Digite o DNS secundário (ex: 8.8.4.4): " DNS2

# Converte máscara se for notação CIDR
if [[ "$NETMASK" =~ ^/[0-9]+$ ]]; then
    CIDR=$NETMASK
else
    # Converte máscara decimal para CIDR
    IFS=. read -r i1 i2 i3 i4 <<< "$NETMASK"
    CIDR=$(echo "obase=2;$i1;$i2;$i3;$i4" | bc | tr -d '\n' | grep -o '1' | wc -l)
    CIDR="/$CIDR"
fi

# ==============================================
# FUNÇÃO PARA CONFIGURAR NETPLAN
# ==============================================
configurar_netplan() {
    local netplan_dir="/etc/netplan"
    local netplan_file=""
    
    # Verifica se o diretório Netplan existe
    if [ ! -d "$netplan_dir" ]; then
        echo -e "${RED}Diretório $netplan_dir não encontrado!${NC}"
        return 1
    fi
    
    # Procura por arquivos .yaml no diretório
    echo -e "${YELLOW}Procurando arquivos Netplan...${NC}"
    
    # Lista de possíveis arquivos Netplan em ordem de prioridade
    local possible_files=(
        "50-cloud-init.yaml"
        "01-netcfg.yaml"
        "00-installer-config.yaml"
        "01-network-manager-all.yaml"
        "99-config.yaml"
        "50-vagrant.yaml"
    )
    
    # Primeiro, verifica se algum dos arquivos comuns existe
    for file in "${possible_files[@]}"; do
        if [ -f "$netplan_dir/$file" ]; then
            netplan_file="$netplan_dir/$file"
            echo -e "${GREEN}Arquivo Netplan encontrado: $file${NC}"
            break
        fi
    done
    
    # Se nenhum arquivo comum foi encontrado, procura por qualquer .yaml
    if [ -z "$netplan_file" ]; then
        echo -e "${YELLOW}Nenhum arquivo padrão encontrado. Procurando por qualquer .yaml...${NC}"
        for file in "$netplan_dir"/*.yaml; do
            if [ -f "$file" ]; then
                netplan_file="$file"
                echo -e "${GREEN}Arquivo Netplan encontrado: $(basename "$file")${NC}"
                break
            fi
        done
    fi
    
    # Se ainda não encontrou, cria um novo arquivo
    if [ -z "$netplan_file" ]; then
        echo -e "${YELLOW}Nenhum arquivo Netplan encontrado. Criando novo arquivo...${NC}"
        netplan_file="$netplan_dir/01-netcfg.yaml"
        echo -e "${GREEN}Novo arquivo será criado: 01-netcfg.yaml${NC}"
    fi
    
    # Faz backup do arquivo existente
    if [ -f "$netplan_file" ]; then
        local backup_file="${netplan_file}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$netplan_file" "$backup_file"
        echo -e "${GREEN}Backup criado: $(basename "$backup_file")${NC}"
    fi
    
    # Cria o novo arquivo Netplan
    cat > "$netplan_file" << EOF
# Configuração gerada automaticamente em $(date)
# Arquivo original: $(basename "$netplan_file")
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE:
      dhcp4: false
      dhcp6: false
      addresses:
        - $FIXED_IP$CIDR
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses: [$DNS1, $DNS2]
EOF
    
    echo -e "${GREEN}Arquivo Netplan atualizado: $(basename "$netplan_file")${NC}"
    
    # Aplica a configuração
    echo -e "${YELLOW}Aplicando configuração Netplan...${NC}"
    netplan apply
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Configuração Netplan aplicada com sucesso!${NC}"
    else
        echo -e "${RED}Erro ao aplicar configuração Netplan. Tentando com --debug...${NC}"
        netplan apply --debug
    fi
    
    return 0
}

# ==============================================
# FUNÇÃO PARA CONFIGURAR INTERFACES TRADICIONAL
# ==============================================
configurar_interfaces() {
    local interfaces_file="/etc/network/interfaces"
    
    if [ ! -f "$interfaces_file" ]; then
        echo -e "${RED}Arquivo $interfaces_file não encontrado!${NC}"
        return 1
    fi
    
    # Faz backup
    local backup_file="${interfaces_file}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$interfaces_file" "$backup_file"
    echo -e "${GREEN}Backup criado: $(basename "$backup_file")${NC}"
    
    # Verifica se já existe configuração para a interface
    if grep -q "^iface $INTERFACE" "$interfaces_file"; then
        echo -e "${YELLOW}Configuração existente para $INTERFACE encontrada. Substituindo...${NC}"
        # Remove configuração existente
        sed -i "/^auto $INTERFACE/d" "$interfaces_file"
        sed -i "/^iface $INTERFACE/,/^$/d" "$interfaces_file"
    fi
    
    # Adiciona nova configuração
    echo -e "\n# Configuração IP Fixo - Adicionada em $(date)" >> "$interfaces_file"
    echo "auto $INTERFACE" >> "$interfaces_file"
    echo "iface $INTERFACE inet static" >> "$interfaces_file"
    echo "    address $FIXED_IP" >> "$interfaces_file"
    echo "    netmask $NETMASK" >> "$interfaces_file"
    echo "    gateway $GATEWAY" >> "$interfaces_file"
    echo "    dns-nameservers $DNS1 $DNS2" >> "$interfaces_file"
    
    echo -e "${GREEN}Arquivo /etc/network/interfaces atualizado${NC}"
    
    # Reinicia o serviço de rede
    if command -v systemctl &> /dev/null; then
        systemctl restart networking
        echo -e "${GREEN}Serviço networking reiniciado${NC}"
    else
        service networking restart
        echo -e "${GREEN}Serviço networking reiniciado${NC}"
    fi
    
    return 0
}

# ==============================================
# FUNÇÃO PARA CONFIGURAR RHEL/CENTOS/FEDORA
# ==============================================
configurar_rhel() {
    local network_dir="/etc/sysconfig/network-scripts"
    local network_file="$network_dir/ifcfg-$INTERFACE"
    
    if [ ! -d "$network_dir" ]; then
        echo -e "${RED}Diretório $network_dir não encontrado!${NC}"
        return 1
    fi
    
    # Faz backup
    if [ -f "$network_file" ]; then
        local backup_file="${network_file}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$network_file" "$backup_file"
        echo -e "${GREEN}Backup criado: $(basename "$backup_file")${NC}"
    fi
    
    # Cria novo arquivo de configuração
    cat > "$network_file" << EOF
# Configuração gerada automaticamente em $(date)
DEVICE=$INTERFACE
BOOTPROTO=none
ONBOOT=yes
IPADDR=$FIXED_IP
NETMASK=$NETMASK
GATEWAY=$GATEWAY
DNS1=$DNS1
DNS2=$DNS2
EOF
    
    echo -e "${GREEN}Arquivo ifcfg-$INTERFACE atualizado${NC}"
    
    # Reinicia o serviço de rede
    if command -v systemctl &> /dev/null; then
        systemctl restart network
        echo -e "${GREEN}Serviço network reiniciado${NC}"
    else
        service network restart
        echo -e "${GREEN}Serviço network reiniciado${NC}"
    fi
    
    return 0
}

# ==============================================
# FUNÇÃO PARA CONFIGURAR ARCH LINUX
# ==============================================
configurar_arch() {
    local network_dir="/etc/systemd/network"
    local network_file="$network_dir/20-$INTERFACE.network"
    
    if [ ! -d "$network_dir" ]; then
        echo -e "${RED}Diretório $network_dir não encontrado!${NC}"
        return 1
    fi
    
    # Faz backup
    if [ -f "$network_file" ]; then
        local backup_file="${network_file}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$network_file" "$backup_file"
        echo -e "${GREEN}Backup criado: $(basename "$backup_file")${NC}"
    fi
    
    # Cria novo arquivo
    cat > "$network_file" << EOF
# Configuração gerada automaticamente em $(date)
[Match]
Name=$INTERFACE

[Network]
Address=$FIXED_IP$CIDR
Gateway=$GATEWAY
DNS=$DNS1
DNS=$DNS2
EOF
    
    echo -e "${GREEN}Arquivo 20-$INTERFACE.network atualizado${NC}"
    
    # Reinicia o serviço
    systemctl restart systemd-networkd
    echo -e "${GREEN}Serviço systemd-networkd reiniciado${NC}"
    
    return 0
}

# ==============================================
# DETECTA SISTEMA E CONFIGURA IP FIXO
# ==============================================
echo -e "\n${YELLOW}Detectando sistema para configuração de IP fixo...${NC}"

if [ -d /etc/netplan ]; then
    # Ubuntu 18.04+ / Debian com Netplan
    echo -e "${GREEN}Sistema com Netplan detectado${NC}"
    configurar_netplan
    
elif [ -f /etc/debian_version ] || [ -f /etc/ubuntu_version ]; then
    # Debian/Ubuntu tradicional
    echo -e "${GREEN}Sistema Debian/Ubuntu tradicional detectado${NC}"
    configurar_interfaces
    
elif [ -f /etc/redhat-release ] || [ -f /etc/fedora-release ]; then
    # RHEL/CentOS/Fedora
    echo -e "${GREEN}Sistema RHEL/CentOS/Fedora detectado${NC}"
    configurar_rhel
    
elif [ -f /etc/arch-release ]; then
    # Arch Linux
    echo -e "${GREEN}Sistema Arch Linux detectado${NC}"
    configurar_arch
    
else
    echo -e "${RED}Sistema não reconhecido para configuração automática de IP${NC}"
    echo -e "${YELLOW}Por favor, configure o IP manualmente${NC}"
fi

# ==============================================
# FINALIZAÇÃO
# ==============================================
echo -e "\n${BLUE}========================================${NC}"
echo -e "${GREEN}✅ CONFIGURAÇÃO CONCLUÍDA COM SUCESSO!${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "${YELLOW}Resumo:${NC}"
echo -e "  • Sistema: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
echo -e "  • Data/Hora: $(date)"
echo -e "  • Timezone: $(timedatectl 2>/dev/null | grep "Time zone" | awk '{print $3}')"
echo -e "  • Servidores NTP: ntp.br"
echo -e "  • IP Antigo (DHCP): $CURRENT_IP"
echo -e "  • IP Novo Fixo: $FIXED_IP"
echo -e "  • Gateway: $GATEWAY"
echo -e "  • Interface: $INTERFACE"
echo -e "  • Root SSH: Habilitado (PermitRootLogin yes)"

echo -e "\n${RED}========================================================${NC}"
echo -e "${RED}⚠️  ATENÇÃO: A CONEXÃO SSH SERÁ PERDIDA AGORA! ⚠️${NC}"
echo -e "${RED}========================================================${NC}"
echo -e "${YELLOW}O IP foi alterado de $CURRENT_IP para $FIXED_IP${NC}"
echo -e "${YELLOW}Reconecte-se usando:${NC}"
echo -e "${BLUE}  ssh root@$FIXED_IP${NC}"
echo -e "${BLUE}  ssh linux@$FIXED_IP${NC}"
echo -e "\n${YELLOW}Lembre-se de definir a senha do root:${NC}"
echo -e "${BLUE}  sudo passwd root${NC}"

echo -e "\n${BLUE}Recomendação: Reinicie o sistema para aplicar todas as mudanças.${NC}"
echo -e "${BLUE}  sudo reboot${NC}\n"
