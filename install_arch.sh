#!/bin/bash

# Função para verificar o status de execução
check() {
    if [ $? -ne 0 ]; then
        echo -e "\e[31mErro na execução. Verifique o arquivo de log: install.log\e[0m"
        exit 1
    fi
}

# Função para verificar comandos essenciais
verificar_comandos() {
    echo "Verificando comandos essenciais..."
    for cmd in parted mkfs.ext4 pacstrap arch-chroot timedatectl; do
        command -v $cmd > /dev/null 2>&1 || { echo -e "\e[31mComando $cmd não encontrado. Instale-o antes de continuar.\e[0m"; exit 1; }
    done
    echo -e "\e[32mTodos os comandos essenciais foram encontrados e estão disponíveis.\e[0m"
}

# Função para configurar logs
iniciar_log() {
    exec > >(tee install.log) 2>&1
}

# Confirmar antes de formatar o disco
confirmar_particionamento() {
    read -p "O disco $DISK será formatado. Deseja continuar? (s/n) " resposta
    [[ $resposta != "s" ]] && { echo "Particionamento abortado."; exit 1; }
}

# Função de particionamento do disco
particionar_disco() {
    echo "Particionando o disco $DISK..."
    parted $DISK mklabel gpt
    check
    parted $DISK mkpart primary ext4 1MiB 100%
    check
    mkfs.ext4 ${DISK}p1
    check
    mount ${DISK}p1 /mnt
    check
}

# Função para configurar o swapfile
configurar_swap() {
    echo "Criando swapfile de 16GB..."
    dd if=/dev/zero of=/mnt/swapfile bs=1M count=16384 status=progress
    check
    chmod 600 /mnt/swapfile
    mkswap /mnt/swapfile
    swapon /mnt/swapfile
    check
}

# Receber senhas com confirmação
ler_senha() {
    local senha
    local confirmacao
    while true; do
        echo "Digite a senha para $1:"
        read -s senha
        echo "Confirme a senha:"
        read -s confirmacao
        [[ "$senha" == "$confirmacao" ]] && { echo "$senha"; return; }
        echo -e "\e[31mAs senhas não coincidem. Tente novamente.\e[0m"
    done
}

# Função para criar a configuração do i3blocks
configurar_i3blocks() {
    echo "Configurando o i3blocks..."
    mkdir -p /home/$USER/.config/i3blocks
    cat <<EOL > /home/$USER/.config/i3blocks/config
[volume]
command=amixer get Master | grep -o "[0-9]*%" | head -n 1
interval=1

[ram]
command=free -h | grep Mem | awk '{print \$3 "/" \$2}'
interval=10

[cpu]
command=top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - \$1"%"}'
interval=1

[temp]
command=sensors | grep "Core 0" | awk '{print \$3}'
interval=10

[disk]
command=df -h / | awk 'NR==2 {print \$3 "/" \$2}'
interval=30

[time]
command=date "+%H:%M"
interval=60
EOL
    chown -R $USER:$USER /home/$USER/.config
}

# Adicionar o swapfile no fstab (dentro do chroot)
adicionar_swap_fstab() {
    echo "/swapfile none swap defaults 0 0" >> /etc/fstab
}

# Início do script
iniciar_log
verificar_comandos

DISK="/dev/nvme0n1"
TIMEZONE="America/Belem"
LOCALE="pt-BR.UTF-8"
KEYMAP="br-abnt2"
HOSTNAME="archlinux"
USER="kleidione"

# Validação de argumentos
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --disk) DISK="$2"; shift ;;
        --timezone) TIMEZONE="$2"; shift ;;
        --user) USER="$2"; shift ;;
        *) echo -e "\e[31mOpção desconhecida: $1\e[0m"; exit 1 ;;
    esac
    shift
done

[[ -z "$DISK" ]] && { echo "Erro: O disco não foi especificado."; exit 1; }
[[ -z "$USER" ]] && { echo "Erro: O nome de usuário não foi especificado."; exit 1; }

# Receber senhas do usuário
PASSWORD=$(ler_senha "usuário $USER")
ROOT_PASSWORD=$(ler_senha "root")

# Confirmar particionamento
confirmar_particionamento
particionar_disco
configurar_swap

# Instalar o sistema base e pacotes
echo "Instalando o sistema base..."
pacstrap /mnt base linux linux-firmware nano sudo git wget curl
check

# Gerar o arquivo fstab
echo "Gerando o arquivo fstab..."
genfstab -U /mnt >> /mnt/etc/fstab
check

# Chroot no sistema instalado
echo "Entrando no chroot para continuar a configuração..."
arch-chroot /mnt /bin/bash <<EOF
    # Configurações básicas
    echo "$HOSTNAME" > /etc/hostname
    echo "127.0.0.1   localhost" >> /etc/hosts
    echo "::1         localhost" >> /etc/hosts
    echo "127.0.1.1   $HOSTNAME.localdomain $HOSTNAME" >> /etc/hosts

    # Configurar fuso horário
    ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
    hwclock --systohc

    # Configurar locale
    echo "$LOCALE UTF-8" > /etc/locale.gen
    locale-gen
    echo "LANG=$LOCALE" > /etc/locale.conf

    # Configurar teclado
    echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

    # Adicionar swapfile no fstab
    echo "/swapfile none swap defaults 0 0" >> /etc/fstab

    # Configurar rede
    systemctl enable NetworkManager

    # Definir senha do root
    echo "root:$ROOT_PASSWORD" | chpasswd

    # Adicionar o usuário
    useradd -m -G wheel -s /bin/zsh $USER
    echo "$USER:$PASSWORD" | chpasswd
    echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

    # Instalar pacotes essenciais
    pacman -S --noconfirm i3-gaps i3blocks dmenu zsh picom xfce4-terminal thunar udisks2 firefox && check

    # Configuração do i3blocks
    mkdir -p /home/$USER/.config
EOF

configurar_i3blocks

echo -e "\e[32mInstalação concluída com sucesso! Agora você pode reiniciar e usar o sistema configurado.\e[0m"
