#!/bin/bash

# Função para verificar o status de execução
check() {
    if [ $? -ne 0 ]; then
        echo "Erro na execução. Verifique o arquivo de log: install.log"
        exit 1
    fi
}

# Função para verificar comandos essenciais
verificar_comandos() {
    echo "Verificando comandos necessários..."
    for cmd in parted mkfs.ext4 pacstrap arch-chroot timedatectl; do
        command -v $cmd > /dev/null 2>&1 || { echo "Comando $cmd não encontrado. Instale antes de continuar."; exit 1; }
    done
    echo "Todos os comandos necessários estão disponíveis."
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
        echo "As senhas não coincidem. Tente novamente."
    done
}

# Início do script
iniciar_log
verificar_comandos

# Definir variáveis com suporte a argumentos
DISK="/dev/nvme0n1"
TIMEZONE="America/Belem"
LOCALE="pt-BR.UTF-8"
KEYMAP="br-abnt2"
HOSTNAME="archlinux"
USER="kleidione"

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --disk) DISK="$2"; shift ;;
        --timezone) TIMEZONE="$2"; shift ;;
        --user) USER="$2"; shift ;;
        *) echo "Opção desconhecida: $1"; exit 1 ;;
    esac
    shift
done

# Obter senhas do usuário
PASSWORD=$(ler_senha "usuário $USER")
ROOT_PASSWORD=$(ler_senha "root")

# Confirmar particionamento
confirmar_particionamento

# Particionamento e formatação do disco
echo "Particionando o disco e criando swapfile..."
parted $DISK mklabel gpt
check
parted $DISK mkpart primary ext4 1MiB 100%
check
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
