#!/bin/bash

# Função para verificar o status de execução
check() {
    if [ $? -ne 0 ]; then
        echo "Erro na execução. Saindo..."
        exit 1
    fi
}

# Funções de configuração

configurar_fuso_horario() {
    echo "Configurando o fuso horário..."
    timedatectl set-timezone $TIMEZONE
    check
}

configurar_locale() {
    echo "Configurando o idioma..."
    echo "$LOCALE UTF-8" > /etc/locale.gen
    locale-gen
    check
    echo "LANG=$LOCALE" > /etc/locale.conf
    check
}

configurar_rede() {
    echo "Configurando a rede..."
    systemctl enable dhcpcd
    systemctl enable NetworkManager
    check
}

# Definir as variáveis fixas
HOSTNAME="archlinux"
USER="kleidione"
DISK="/dev/nvme0n1"
TIMEZONE="America/Belem"
LOCALE="pt-BR.UTF-8"
KEYMAP="br-abnt2"

# Perguntar as preferências do usuário
echo "Digite a senha do usuário $USER:"
read -s PASSWORD

echo "Digite a senha do root:"
read -s ROOT_PASSWORD

# Particionamento e formatação do disco
echo "Particionando o disco e criando swapfile..."
parted $DISK mklabel gpt
parted $DISK mkpart primary ext4 1MiB 100%
mkfs.ext4 ${DISK}p1
check
mount ${DISK}p1 /mnt
check

# Criar swapfile
echo "Criando swapfile de 16GB..."
dd if=/dev/zero of=/mnt/swapfile bs=1M count=16384 status=progress
check
chmod 600 /mnt/swapfile
mkswap /mnt/swapfile
swapon /mnt/swapfile
check

# Adicionando o swapfile no fstab para persistência
echo "/swapfile none swap defaults 0 0" >> /mnt/etc/fstab
check

# Instalar o sistema base e pacotes
echo "Instalando o sistema base..."
pacstrap /mnt base linux linux-firmware nano sudo git wget curl
check

# Gerar o arquivo fstab
echo "Gerando fstab..."
genfstab -U /mnt >> /mnt/etc/fstab
check

# Chroot no sistema instalado
echo "Chroot no sistema..."
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

    # Atualizar pacotes do sistema
    pacman -Syu --noconfirm && check

    # Configurar rede
    systemctl enable NetworkManager

    # Definir senha do root
    echo "root:$ROOT_PASSWORD" | chpasswd

    # Adicionar o usuário
    useradd -m -G wheel -s /bin/zsh $USER
    echo "$USER:$PASSWORD" | chpasswd
    echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

    # Instalar pacotes essenciais
    pacman -S --noconfirm pipewire pipewire-pulse pipewire-alsa pipewire-jack xfce4-terminal thunar thunar-archive-plugin engrampa udisks2 vlc qbittorrent firefox telegram-desktop zsh dmenu picom code i3-gaps i3blocks lxappearance hsetroot lm_sensors polkit ttf-fira-code ttf-hack ttf-noto-fonts && check

    # Configurar sensores (lm_sensors)
    sensors-detect --auto && check

    # Criar .xinitrc básico
    echo "exec picom & exec i3" > /home/$USER/.xinitrc
    chmod +x /home/$USER/.xinitrc
    chown $USER:$USER /home/$USER/.xinitrc

    # Criar diretórios padrão do usuário
    mkdir -p /home/$USER/{Documents,Downloads,Music,Pictures,Videos,.config,.cache}
    chown -R $USER:$USER /home/$USER

    # Configuração do i3blocks
    echo "Configurando o i3blocks para exibir volume, uso de RAM, CPU, disco e temperatura..."
    cat <<EOL > /home/$USER/.config/i3blocks/config
    [volume]
    command=amixer get Master | grep -o "[0-9]*%" | head -n 1
    interval=1

    [ram]
    command=free -h | grep Mem | awk '{print $3 "/" $2}'
    interval=10

    [cpu]
    command=top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1"%"}'
    interval=1

    [temp]
    command=sensors | grep "Core 0" | awk '{print $3}'
    interval=10

    [disk]
    command=df -h / | awk 'NR==2 {print $3 "/" $2}'
    interval=30
    EOL
    chown -R $USER:$USER /home/$USER/.config

    # Instalar yay manualmente
    sudo -u $USER git clone https://aur.archlinux.org/yay.git /home/$USER/yay
    cd /home/$USER/yay
    sudo -u $USER makepkg -si --noconfirm
    rm -rf /home/$USER/yay
EOF

# Finalizando a instalação
echo "Instalação concluída com sucesso!"
echo "Agora você pode reiniciar o sistema e fazer login com o usuário $USER."
