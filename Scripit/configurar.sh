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
echo -e "\n${YELLOW}[1/5] IDENTIFICANDO VERSÃO DO LINUX...${NC}"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo -e "${GREEN}Distribuição: $NAME${NC}"
    echo -e "${GREEN}Versão: $VERSION_ID${NC}"
    echo -e "${GREEN}Nome: $PRETTY_NAME${NC}"
else
    echo -e "${RED}Sistema não suportado ou arquivo /etc/os-release não encontrado${NC}"
fi

# 2. ATUALIZAR O SISTEMA
echo -e "\n${YELLOW}[2/5] ATUALIZANDO REPOSITÓRIOS E PACOTES...${NC}"

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
echo -e "\n${YELLOW}[3/5] IDENTIFICANDO IP ATUAL...${NC}"

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
echo -e "\n${YELLOW}[4/5] CONFIGURANDO IP FIXO...${NC}"

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

# Detecta o tipo de sistema e configura IP fixo
if [ -f /etc/debian_version ]; then
    # Debian/Ubuntu - Netplan ou interfaces
    if [ -d /etc/netplan ]; then
        # Netplan
        NETPLAN_FILE="/etc/netplan/01-netcfg.yaml"
        cat > $NETPLAN_FILE << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE:
      dhcp4: no
      addresses:
        - $FIXED_IP$CIDR
      gateway4: $GATEWAY
      nameservers:
        addresses: [$DNS1, $DNS2]
EOF
        netplan apply
        echo -e "${GREEN}IP fixo configurado via Netplan${NC}"
    else
        # /etc/network/interfaces
        INTERFACES_FILE="/etc/network/interfaces"
        echo -e "\n# Configuração IP Fixo" >> $INTERFACES_FILE
        echo "auto $INTERFACE" >> $INTERFACES_FILE
        echo "iface $INTERFACE inet static" >> $INTERFACES_FILE
        echo "    address $FIXED_IP" >> $INTERFACES_FILE
        echo "    netmask $NETMASK" >> $INTERFACES_FILE
        echo "    gateway $GATEWAY" >> $INTERFACES_FILE
        echo "    dns-nameservers $DNS1 $DNS2" >> $INTERFACES_FILE
        systemctl restart networking
        echo -e "${GREEN}IP fixo configurado via /etc/network/interfaces${NC}"
    fi

elif [ -f /etc/redhat-release ]; then
    # RHEL/CentOS/Fedora
    NETWORK_FILE="/etc/sysconfig/network-scripts/ifcfg-$INTERFACE"
    cat > $NETWORK_FILE << EOF
DEVICE=$INTERFACE
BOOTPROTO=none
ONBOOT=yes
IPADDR=$FIXED_IP
NETMASK=$NETMASK
GATEWAY=$GATEWAY
DNS1=$DNS1
DNS2=$DNS2
EOF
    systemctl restart network
    echo -e "${GREEN}IP fixo configurado no RHEL/CentOS${NC}"

elif [ -f /etc/arch-release ]; then
    # Arch Linux
    echo -e "${YELLOW}Para Arch Linux, configurar com systemd-networkd:${NC}"
    NETWORK_FILE="/etc/systemd/network/20-$INTERFACE.network"
    cat > $NETWORK_FILE << EOF
[Match]
Name=$INTERFACE

[Network]
Address=$FIXED_IP$CIDR
Gateway=$GATEWAY
DNS=$DNS1
DNS=$DNS2
EOF
    systemctl restart systemd-networkd
    echo -e "${GREEN}IP fixo configurado no Arch Linux${NC}"
fi

echo -e "${GREEN}Configuração de IP fixo concluída!${NC}"

# 5. ATIVAR ROOT NO SSH
echo -e "\n${YELLOW}[5/5] ATIVANDO ACESSO ROOT NO SSH...${NC}"

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

# Faz backup do arquivo original
cp $SSH_CONFIG ${SSH_CONFIG}.backup
echo -e "${GREEN}Backup criado: ${SSH_CONFIG}.backup${NC}"

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
