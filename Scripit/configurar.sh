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

# 1. IDENTIFICAR VERSÃO DO LINUX
echo -e "\n${YELLOW}[1/6] IDENTIFICANDO VERSÃO DO LINUX...${NC}"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo -e "${GREEN}Distribuição: $NAME${NC}"
    echo -e "${GREEN}Versão: $VERSION_ID${NC}"
    echo -e "${GREEN}Nome: $PRETTY_NAME${NC}"
else
    echo -e "${RED}Sistema não suportado ou arquivo /etc/os-release não encontrado${NC}"
fi

# 2. ATUALIZAR O SISTEMA
echo -e "\n${YELLOW}[2/6] ATUALIZANDO REPOSITÓRIOS E PACOTES...${NC}"

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

# 3. IDENTIFICAR IP ATUAL
echo -e "\n${YELLOW}[3/6] IDENTIFICANDO IP ATUAL...${NC}"

# IP da interface principal (excluindo loopback)
CURRENT_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)

if [ -z "$CURRENT_IP" ]; then
    CURRENT_IP=$(hostname -I | awk '{print $1}')
fi

if [ -n "$CURRENT_IP" ]; then
    echo -e "${GREEN}IP atual: $CURRENT_IP${NC}"
else
    echo -e "${RED}Não foi possível identificar o IP atual${NC}"
    exit 1
fi

# 4. CONFIGURAR IP FIXO
echo -e "\n${YELLOW}[4/6] CONFIGURANDO IP FIXO...${NC}"

# Detecta a interface de rede principal
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n 1)

if [ -z "$INTERFACE" ]; then
    INTERFACE=$(ip -4 addr show | grep -v 'lo' | grep -oP '(?<=: )\w+' | head -n 1)
fi

echo -e "${GREEN}Interface detectada: $INTERFACE${NC}"

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

echo -e "${GREEN}Configuração de IP fixo concluída!${NC}"

# 5. ATIVAR ROOT NO SSH
echo -e "\n${YELLOW}[5/6] ATIVANDO ACESSO ROOT NO SSH...${NC}"

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
else
    echo -e "${RED}Falha ao configurar SSH${NC}"
fi

# 6. LISTAR ARQUIVOS MODIFICADOS
echo -e "\n${YELLOW}[6/6] RESUMO DOS ARQUIVOS MODIFICADOS...${NC}"

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
echo -e "  • Sistema: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
echo -e "  • IP Antigo: $CURRENT_IP"
echo -e "  • IP Novo Fixo: $FIXED_IP"
echo -e "  • Gateway: $GATEWAY"
echo -e "  • Interface: $INTERFACE"
echo -e "  • Root SSH: Habilitado (PermitRootLogin yes)"
echo -e "\n${YELLOW}⚠️  ATENÇÃO:${NC}"
echo -e "  • A senha do root deve ser definida com: sudo passwd root"
echo -e "  • O IP pode mudar após reiniciar a rede"
echo -e "  • Para testar: ssh root@$FIXED_IP"
echo -e "\n${BLUE}Recomendação: Reinicie o sistema para aplicar todas as mudanças.${NC}"
echo -e "sudo reboot\n"
