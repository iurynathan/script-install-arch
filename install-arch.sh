#!/usr/bin/env bash
# -------------------------------------------------------------------
# Script interativo de instalação Arch Linux + Btrfs + Timeshift
# oferece opções de swapfile, criptografia LUKS e detecção de GPU.
# Sem ambiente de trabalho
# -------------------------------------------------------------------
set -euo pipefail

# Função para logar mensagens
info() { echo -e "\e[1;34m[INFO]\e[0m $*"; }
warn() { echo -e "\e[1;33m[WARN]\e[0m $*"; }
error() { echo -e "\e[1;31m[ERROR]\e[0m $*"; exit 1; }

# 1. Listar dispositivos de bloco disponíveis
info "Dispositivos de bloco disponíveis:"
lsblk -d --output NAME,SIZE,MODEL
\# 2. Perguntar dispositivo alvo
info "Disco alvo (ex: /dev/nvme0n1, /dev/sda):"
read -rp "Digite o dispositivo (ex: /dev/nvme0n1): " DEVICE

# Confirmar se o dispositivo existe
if [[ ! -b "$DEVICE" ]]; then
  error "Dispositivo $DEVICE não encontrado. Abortando."
fi

info "Hostname definido como: $HOSTNAME"

# 1. Nome de usuário
read -rp "Digite o nome de usuário desejado (ex: nathan): " USER_NAME

# 2. Sugestões de hostname
info "Sugestões de hostname:"
echo " 1) $USER_NAME-hypr"
echo " 2) $USER_NAME-arch"
echo " 3) workstation"
echo " 4) Outro (digite manualmente)"

read -rp "Escolha uma opção (1-4): " HOST_OPT
case "$HOST_OPT" in
  1) HOSTNAME="$USER_NAME-hypr";;
  2) HOSTNAME="$USER_NAME-arch";;
  3) HOSTNAME="workstation";;
  4) read -rp "Digite o hostname desejado (sem espaços, minúsculas): " HOSTNAME;;
  *) error "Opção inválida para hostname.";;
esac

# 4. Senhas
# Senha root
read -rsp "Digite a senha para o usuário root: " ROOT_PASS
echo
# Senha usuário normal
read -rsp "Digite a senha para o usuário $USER_NAME: " USER_PASS
echo

# 5. Escolha criar swapfile?
read -rp "Deseja criar um swapfile? (s/N): " USE_SWAP
USE_SWAP=${USE_SWAP,,}  # lowercase
if [[ "$USE_SWAP" == "s" ]]; then
  read -rp "Tamanho do swapfile em GiB (ex: 8): " SWAP_SIZE
  info "Swapfile será de ${SWAP_SIZE}GiB"
else
  info "Não será criado swapfile."
fi

# 6. Criptografia LUKS?
read -rp "Deseja criptografar a partição raiz com LUKS? (s/N): " USE_CRYPT
USE_CRYPT=${USE_CRYPT,,}
if [[ "$USE_CRYPT" == "s" ]]; then
  read -rsp "Digite a passphrase para LUKS: " LUKS_PASS
  echo
  LUKS_NAME="cryptroot"
  info "LUKS habilitado. O volume será mapeado como /dev/mapper/$LUKS_NAME"
else
  info "Sem criptografia LUKS na raiz."
fi

# 7. Detecção/seleção de GPU
info "Detectando GPU..."
GPU_VENDOR="unknown"
if lspci | grep -E "NVIDIA" &>/dev/null; then
  GPU_VENDOR="nvidia"
elif lspci | grep -E "AMD/ATI" &>/dev/null; then
  GPU_VENDOR="amd"
elif lspci | grep -E "Intel Corporation" | grep -E "Graphics" &>/dev/null; then
  GPU_VENDOR="intel"
fi
if [[ "$GPU_VENDOR" != "unknown" ]]; then
  info "GPU detectada: $GPU_VENDOR"
  read -rp "Deseja instalar drivers para $GPU_VENDOR? (s/n): " INSTALL_GPU
  INSTALL_GPU=${INSTALL_GPU,,}
else
  warn "Não foi possível detectar GPU automaticamente."
  echo "Opções de GPU: nvidia, amd, intel, none"
  read -rp "Digite seu tipo de GPU: " GPU_VENDOR
  GPU_VENDOR=${GPU_VENDOR,,}
  if [[ ! "$GPU_VENDOR" =~ ^(nvidia|amd|intel|none)$ ]]; then
    error "Opção de GPU inválida.";
  fi
  [[ "$GPU_VENDOR" == "none" ]] && INSTALL_GPU="n"
  [[ "$GPU_VENDOR" != "none" ]] && read -rp "Deseja instalar drivers para $GPU_VENDOR? (s/n): " INSTALL_GPU && INSTALL_GPU=${INSTALL_GPU,,}
fi

# 8. Particionamento
info "-- Particionando o disco $DEVICE --"

# Atenção: apaga tudo
echo
warn "O dispositivo $DEVICE será apagado e particionado!"
read -rp "Confirma (digite 'SIM' para prosseguir)? " CONFIRM
if [[ "$CONFIRM" != "SIM" ]]; then
  error "Instalação abortada pelo usuário."
fi

# Usamos sgdisk para particionar
sgdisk --zap-all "$DEVICE"
# Partição EFI (512M)
sgdisk -n1:0:+512M -t1:EF00 "$DEVICE"
# Partição raiz (restante)
sgdisk -n2:0:0 -t2:8300 "$DEVICE"

EFI_PART="${DEVICE}p1"
ROOT_PART="${DEVICE}p2"

# 9. Formatar partições
info "Formatando partições..."
mkfs.fat -F32 "$EFI_PART"
if [[ "$USE_CRYPT" == "s" ]]; then
  # configurar LUKS
  echo "$LUKS_PASS" | cryptsetup luksFormat "$ROOT_PART" -d -
  echo "$LUKS_PASS" | cryptsetup open "$ROOT_PART" "$LUKS_NAME" -d -
  ROOT_DEVICE="/dev/mapper/$LUKS_NAME"
else
  ROOT_DEVICE="$ROOT_PART"
fi
mkfs.btrfs -f "$ROOT_DEVICE"

# 10. Criar e montar subvolumes Btrfs
info "Criando subvolumes Btrfs..."
mount "$ROOT_DEVICE" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
umount /mnt

info "Montando subvolumes..."
mount -o noatime,compress=zstd,ssd,space_cache=v2,subvol=@ "$ROOT_DEVICE" /mnt
mkdir -p /mnt/{boot,home,.snapshots}
mount "$EFI_PART" /mnt/boot
mount -o noatime,compress=zstd,ssd,space_cache=v2,subvol=@home "$ROOT_DEVICE" /mnt/home
mount -o noatime,compress=zstd,ssd,space_cache=v2,subvol=@snapshots "$ROOT_DEVICE" /mnt/.snapshots

# 11. Instalar base do sistema
info "Instalando sistema base"...
pacstrap /mnt base linux linux-firmware btrfs-progs nano vim sudo networkmanager

# 12. Gerar fstab e chroot
genfstab -U /mnt >> /mnt/etc/fstab
arch-chroot /mnt /bin/bash <<EOF_CHROOT
# 12.1 Timezone
ln -sf /usr/share/zoneinfo/America/Maceio /etc/localtime
hwclock --systohc

# 12.2 Locale
sed -i 's/^#pt_BR.UTF-8 UTF-8/pt_BR.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=pt_BR.UTF-8" > /etc/locale.conf

# 12.3 Hostname e hosts
echo "$HOSTNAME" > /etc/hostname
cat <<EOL > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOL

# 12.4 mkinitcpio com Btrfs
sed -i 's/^HOOKS=/HOOKS=(base udev autodetect modconf block btrfs filesystems keyboard fsck) #/' /etc/mkinitcpio.conf
mkinitcpio -P

# 12.5 Senha root
echo "root:$ROOT_PASS" | chpasswd

# 12.6 Criar usuário e configurar sudo
echo "Criando usuário $USER_NAME"
useradd -m -G wheel -s /bin/bash $USER_NAME
echo "$USER_NAME:$USER_PASS" | chpasswd
sed -i 's/^ %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers

# 12.7 Instalar e habilitar NetworkManager
pacman -S --noconfirm networkmanager
systemctl enable NetworkManager

# 12.8 Instalar drivers GPU, se solicitado
case "$GPU_VENDOR" in
  nvidia)
    if [[ "$INSTALL_GPU" == "s" ]]; then
      pacman -S --noconfirm nvidia nvidia-utils nvidia-settings
    fi
    ;;  
  amd)
    if [[ "$INSTALL_GPU" == "s" ]]; then
      pacman -S --noconfirm mesa xf86-video-amdgpu
    fi
    ;;  
  intel)
    if [[ "$INSTALL_GPU" == "s" ]]; then
      pacman -S --noconfirm mesa xf86-video-intel
    fi
    ;;  
  none)
    ;;  
  *)
    ;;  
esac

# 12.9 Instalar e configurar Timeshift para Btrfs
pacman -S --noconfirm timeshift
echo "Configuração inicial do Timeshift pode ser feita após primeiro boot: selecione Btrfs e subvolume @snapshots"

# 12.10 Configurar systemd-boot
echo "Instalando systemd-boot..."
bootctl install
cat <<EOL > /boot/loader/loader.conf
default  arch
timeout  3
editor   no
EOL
ROOT_UUID=\$(blkid -s UUID -o value $ROOT_DEVICE)
cat <<EOL > /boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=UUID=\$ROOT_UUID rootflags=subvol=@ rw
EOL
EOF_CHROOT

# 13. Opcional: Criar swapfile se selecionado
if [[ "$USE_SWAP" == "s" ]]; then
  info "Configurando swapfile de ${SWAP_SIZE}GiB..."
  fallocate -l ${SWAP_SIZE}G /mnt/swapfile
  chmod 600 /mnt/swapfile
  chroot /mnt mkswap /swapfile
  chroot /mnt swapon /swapfile
  echo "/swapfile none swap defaults 0 0" >> /mnt/etc/fstab
fi

# 14. Finalizando
info "Desmontando volumes e finalizando instalação..."
umount -R /mnt
info "Instalação base concluída. Reinicie (remova o pendrive) e prossiga para configurar Hyprland."
