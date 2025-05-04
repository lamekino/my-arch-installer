#!/bin/bash

################################################################################
# Set shell vars
################################################################################
IFS=$'\t\n'
PS3="> "
PS4="\033[36m\h#\033[0m "

set -euo pipefail

################################################################################
# Restart script in tmux and set signal handling
################################################################################
TMUX_NAME="archlinux-installer"

if ! (tmux list-sessions | grep -q "^$TMUX_NAME"); then
    exec tmux new-session -s "$TMUX_NAME" "$0 && zsh || zsh"
else
    trap "exec zsh" SIGINT SIGHUP SIGTERM
fi

################################################################################
# Installer variables, empty optional variables are set by the user if empty
################################################################################

#
# Installer config
#

# string return value for functions
RV=

# chroot mount point
MNT="/mnt"

# uefi system directory. can either be /boot/efi or /efi.
ESP="/boot/efi"

# installer config files to copy to the system
CFG="$(dirname "$(realpath "$0")")/cfg"

# build directory for AUR packages
PKG_ROOT="/build"

# password cache files
PWCACHE="/dev/shm"
PWCACHE_DISK="$PWCACHE/disk"
PWCACHE_USER="$PWCACHE/user"

# installer tweak booleans
INSTALLER_USE_VI_NVIM_SYMLINK=1
INSTALLER_ENABLE_DISPLAY_MANAGER=1

INSTALLER_PACKAGES=(
    # necessary system packages
    base base-devel linux linux-firmware intel-ucode archlinux-keyring less zsh

    # filesystem
    lvm2 btrfs-progs dosfstools

    # net utils
    networkmanager openssh wget curl

    # documentation
    man-db man-pages

    # sound firmware/utils
    sof-firmware alsa-utils alsa-lib alsa-ucm-conf

    # file utils
    tree stow p7zip zip unzip binwalk the_silver_searcher dfc findutils
    diffutils

    # process utils
    htop strace valgrind gdb rlwrap

    # pacman utils
    reflector pacman-contrib arch-audit devtools

    # dev
    git tmux fzf bat zoxide toilet github-cli cloc jq python

    # nvim
    neovim tree-sitter fd ripgrep
)

# systemd services/timers/etc to enable in chroot
INSTALLER_ENABLE_UNITS=(
    NetworkManager.service
    reflector.timer
)

# thread count for pacman and other multi-threaded programs
INSTALLER_THREADS="$(( $(nproc) + 1 ))"

#
# AUR config
#
AUR_URL="https://aur.archlinux.org/"
AUR_HELPER_PKG="yay-bin" # required :( TODO: make optional

#
# OS config
#
OS_DISK= # optional
OS_HOSTNAME= # optional
OS_LOCALE="en_US.UTF-8"
OS_TIMEZONE="America/New_York"

#
# user config
#
USER_NAME= # optional
USER_SHELL="/usr/bin/zsh"
USER_GROUPS="wheel,log,adm,input,systemd-journal"

#
# partition config
#
# *_LABEL   : partition label
# *_NAME    : mapped partition name
# *_DISK    : path to disk (via /dev/disk/by-partlabel)
# *_SIZE    : size of partition in SI units
# *_OPTIONS : options to pass to to mount (-o)
#

# $ESP
ESP_LABEL="UEFI"
ESP_DISK="/dev/disk/by-partlabel/$ESP_LABEL"
ESP_SIZE=1GiB
# https://bbs.archlinux.org/viewtopic.php?pid=2113977#p2113977
ESP_OPTIONS="uid=0,gid=0,fmask=0077,dmask=0077"

# /boot
BOOT_LABEL="BOOT"
BOOT_DISK="/dev/disk/by-partlabel/$BOOT_LABEL"
BOOT_SIZE=1GiB

# /dev/mapper/$CRYPT_NAME
CRYPT_NAME="encrypted"
CRYPT_LABEL="LUKS"
CRYPT_DISK="/dev/disk/by-partlabel/$CRYPT_LABEL"

# LVM config
LVM_GROUP="archlinux"
LVM_PHYVOL="/dev/mapper/$CRYPT_NAME"

# /dev/$LVM_GROUP/$SWAP_NAME
SWAP_NAME="swap"
SWAP_SIZE=8GiB
SWAP_DISK="/dev/mapper/$LVM_GROUP-$SWAP_NAME"

# /dev/$LVM_GROUP/$ROOT_NAME
ROOT_NAME="btrfs"
ROOT_DISK="/dev/mapper/$LVM_GROUP-$ROOT_NAME"
ROOT_OPTIONS="compress=zstd:5"

################################################################################
# Installer functions
################################################################################
read_name() {
    confirm_yesno=

    until [[ "$confirm_yesno" =~ (Y|y) ]]; do
        printf "Enter %sname: " "$1"
        read -r RV

        until [[ "$RV" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]]; do
            printf "Invalid %sname. Try again." "$1"
            echo

            printf "Enter %sname: " "$1"
            read -r RV
        done

        confirm_yesno=
        until [[ "$confirm_yesno" =~ (Y|y|N|n) ]]; do
            printf "Is '%s' a good %sname? [y/n] " "$RV" "$1"
            read -r confirm_yesno
        done
    done
}

cache_password() {
    keyfile="$1"
    title=$(basename "$1")

    printf "Enter %s password: " "$title"
    read -rs pw_apple
    echo

    printf "Confirm %s password: " "$title"
    read -rs pw_orange
    echo

    until [ "$pw_apple" = "$pw_orange" ]; do
        echo
        echo "Password mismatch! Please try again."
        echo

        printf "Enter %s password: " "$title"
        read -rs pw_apple
        echo

        printf "Confirm %s password: " "$title"
        read -rs pw_orange
        echo
    done

    printf "%s" "$pw_apple" > "$keyfile"
}

choose_disk() {
    disk_list=$(lsblk --list --paths -o NAME,MODEL,SIZE | awk "NF > 2")
    disk_paths=$(awk 'NR > 1 { print $1 }' <<< "$disk_list" )

    confirm_yesno=
    until [[ "$confirm_yesno" =~ (Y|y) ]]; do
        echo "$disk_list"

        RV=
        while [ -z "$RV" ]; do
            select path in $disk_paths; do
                RV="$path"
                break
            done
        done

        confirm_yesno=
        until [[ "$confirm_yesno" =~ (Y|y|N|n) ]]; do
            printf "Is '%s' the correct disk? [y/n] " "$RV"
            read -r confirm_yesno
        done
    done
}

prompt_install() {
    yesno="filler"
    until [[ "$yesno" =~ (Y|y|N|n|^$) ]]; do
        printf "Install %s? [Y/n] " "$1"
        read -r yesno
    done

    ! [ "${yesno,,}" = "n" ]
}

disk_sync_wait() {
    sync
    sleep 0.5
}

@() {
    printf '\033[1;36m%s\033[0m\n' "$1"
}

################################################################################
@ "Confirming installation"
################################################################################
cat << EOF
This is my Arch Linux installer script; it will do the following things:

  1) Set install disk, encryption password, username info and hostname
  2) Create the disk layout:
   |  $ESP_SIZE partion for $ESP with fat32
   |  $BOOT_SIZE boot parition for /boot with fat32
   |  Encrypt remaining space with volume name $CRYPT_NAME
   |  Volume group $LVM_GROUP on $LVM_PHYVOL
   |  $SWAP_SIZE $SWAP_NAME on $LVM_GROUP
   |  Remaining group space for $ROOT_NAME (/) on $LVM_GROUP with btrfs
   |  Create subvolumes for @, @var, @tmp and @home
   |  Enable compression on the subvolumes
  3) Mount the system on $MNT
  4) Install packages, set configs (copying from: $CFG)
  5) Configure locale, timezone, hostname, user, etc
  6) Enable systemd units from choosen packages
  7) Create user, set as sudoer, lock root account
  9) Configure systemd-boot and mkinitcpio, set special kernel params
  8) Install AUR helper \`$AUR_HELPER_PKG\`
  10) Unmount the filesystems, cleanup, and that's it!

This process will wipe the current disk contents. Type YES (all caps) to
continue to the installer:
EOF
read -r confirm_install

until [ "$confirm_install" = "YES" ]; do
    echo "Invalid input. Type YES (all caps) or press Ctrl-c or Ctrl-d to quit."
    read -r confirm_install
done

# start reflector now so it can get a head start while the installer is being
# configured
reflector \
    --latest 10 \
    --protocol https \
    --sort rate \
    --country "United States" \
    --save /etc/pacman.d/mirrorlist \
    &>/dev/null &

reflector_pid=$!

if ! ping -c 1 archlinux.org &>/dev/null; then
    echo "You need to connect to the internet. See iwctl(8) for wifi."
    exit 1
fi

if ! [ -e "$MNT" ]; then
    echo "Creating mountpoint $MNT."
    mkdir -p "$MNT"
fi

if ! [ -d "$MNT" ]; then
    echo "Invalid mountpount $MNT."
    exit 1
fi

clear

################################################################################
@ "Configure OS"
################################################################################
echo
tries=0

while (( tries >= 0 )); do
    if (( tries > 0 )) || [ -z "$OS_DISK" ]; then
        @ "Select target disk"
        choose_disk
        OS_DISK="$RV"
        echo

        @ "Set disk encryption password"
        cache_password "$PWCACHE_DISK"
        echo
    fi

    if (( tries > 0 )) || [ -z "$OS_HOSTNAME" ]; then
        @ "Set hostname"
        read_name "host"
        OS_HOSTNAME="$RV"
        echo
    fi

    @ "Configure user"
    if (( tries > 0 )) || [ -z "$USER_NAME" ]; then
        read_name "user"
        USER_NAME="$RV"
        echo
    fi
    cache_password "$PWCACHE_USER"
    echo

    @ "Confirm config"
    confirm=
    until [[ "$confirm" =~ (Y|y|N|n) ]]; do
        printf "username: %s\n" "$USER_NAME"
        printf "hostname: %s\n" "$OS_HOSTNAME"
        printf "disk:     %s\n" "$OS_DISK"
        printf "Use this configuration? [y/n] "
        read -r confirm
    done

    case "$confirm" in
    Y|y) tries=-1 ;;
    *) (( tries++ )) || {
        clear
        @ "Configure OS"
    } ;;
    esac

    echo
done

################################################################################
@ "Choose packages"
################################################################################
if prompt_install "GNOME"; then
    if (( INSTALLER_ENABLE_DISPLAY_MANAGER )); then
        INSTALLER_ENABLE_UNITS+=(gdm.service)
    fi

    INSTALLER_PACKAGES+=(gnome gnome-tweaks noto-fonts-cjk)

    if prompt_install "WezTerm"; then
        INSTALLER_PACKAGES+=(wezterm ttf-ibm-plex)
    fi

    if prompt_install "Firefox"; then
        INSTALLER_PACKAGES+=(firefox)
    fi
fi

if prompt_install "Docker"; then
    INSTALLER_ENABLE_UNITS+=(docker.service)
    INSTALLER_PACKAGES+=(docker docker-compose)
fi

if prompt_install "ClamAV"; then
    INSTALLER_ENABLE_UNITS+=(clamav-freshclam-once.timer)
    INSTALLER_PACKAGES+=(clamav)
fi

if prompt_install "ydotool"; then
    INSTALLER_ENABLE_UNITS+=(ydotool.service)
    INSTALLER_PKGS+=(ydotool)
fi

################################################################################
@ "Preparing installer"
################################################################################
set -x
timedatectl set-ntp true
pacman-key --init

sed -i \
    -e 's/^#ParallelDownloads/ParallelDownloads/' \
    -e "s/ParallelDownloads = 5$/ParallelDownloads = $INSTALLER_THREADS/" \
    /etc/pacman.conf

set +x

################################################################################
@ "Partitioning disks"
################################################################################
set -x

sfdisk "$OS_DISK" << EOF
label: gpt
start=, size=$ESP_SIZE, type=uefi, name=$ESP_LABEL
start=, size=$BOOT_SIZE, type=xbootldr, name=$BOOT_LABEL
start=, size=, type=linux, name=$CRYPT_LABEL
EOF

disk_sync_wait

cryptsetup luksFormat "$CRYPT_DISK" --key-file - < "$PWCACHE_DISK"
cryptsetup open "$CRYPT_DISK" "$CRYPT_NAME" --key-file - < "$PWCACHE_DISK"

disk_sync_wait

pvcreate "$LVM_PHYVOL"
vgcreate "$LVM_GROUP" "$LVM_PHYVOL"
lvcreate -L "$SWAP_SIZE" -n "$SWAP_NAME" "$LVM_GROUP"
lvcreate -l 100%FREE -n "$ROOT_NAME" "$LVM_GROUP"

disk_sync_wait
set +x

################################################################################
@ "Formating partitions"
################################################################################
set -x

mkfs.fat -F32 "$ESP_DISK"
# bootloader spec says use fat for /boot, i've personally always used ext2 with
# grub.. see:
# https://uapi-group.org/specifications/specs/boot_loader_specification/#the-partitions
# maybe we can install fs drivers from pkg "efifs", but it would require a
# pacman hook to copy to ESP on update
# mkfs.ext2 "$BOOT_DISK"
mkfs.fat -F32 "$BOOT_DISK"
mkswap "$SWAP_DISK"
mkfs.btrfs "$ROOT_DISK"

disk_sync_wait
set +x

################################################################################
@ "Configuring BTRFS"
################################################################################
set -x
mount -o "$ROOT_OPTIONS" "$ROOT_DISK" "$MNT"

btrfs subvolume create "$MNT/@"
btrfs subvolume create "$MNT/@home"
btrfs subvolume create "$MNT/@tmp"
btrfs subvolume create "$MNT/@var"

mount -o "$ROOT_OPTIONS,subvol=@" "$ROOT_DISK" "$MNT"
btrfs subvolume set-default /mnt
umount "$MNT"

disk_sync_wait
set +x

################################################################################
@ "Mounting filesystems"
################################################################################
set -x
mount -o "$ROOT_OPTIONS" "$ROOT_DISK" "$MNT"

mkdir "$MNT/home"
mount -o "$ROOT_OPTIONS,subvol=@home" "$ROOT_DISK" "$MNT/home"

mkdir "$MNT/tmp"
mount -o "$ROOT_OPTIONS,subvol=@tmp" "$ROOT_DISK" "$MNT/tmp"

mkdir "$MNT/var"
mount -o "$ROOT_OPTIONS,subvol=@var" "$ROOT_DISK" "$MNT/var"

mkdir "$MNT/boot"
mount "$BOOT_DISK" "$MNT/boot"

mkdir "$MNT/$ESP"
mount -o "$ESP_OPTIONS" "$ESP_DISK" "$MNT/$ESP"

swapon "$SWAP_DISK"
lsblk "$OS_DISK"
set +x

################################################################################
@ "Running pacstap"
################################################################################
echo "Waiting for reflector to finish syncing..."
while kill -0 "$reflector_pid" 2>/dev/null; do
    :
done
echo "Done!"

pacstrap -K "$MNT" "${INSTALLER_PACKAGES[@]}"

################################################################################
@ "Generating system config"
################################################################################
set -x
# fs config
genfstab -U "$MNT" | tee -a "$MNT/etc/fstab"

# net config
echo "$OS_HOSTNAME" > "$MNT/etc/hostname"

# locale config
echo "$OS_LOCALE UTF-8" > "$MNT/etc/locale.gen"
echo "LANG=$OS_LOCALE" > "$MNT/etc/locale.conf"

# timezone config
ln -rs "$MNT/usr/share/zoneinfo/$OS_TIMEZONE" "$MNT/etc/localtime"

# pacman config
sed -i \
    -e "s/^#Color/Color/" \
    -e "s/^#NoProgressBar/ILoveCandy/" \
    -e 's/^#ParallelDownloads/ParallelDownloads/' \
    -e "s/ParallelDownloads = 5$/ParallelDownloads = $INSTALLER_THREADS/" \
    "$MNT/etc/pacman.conf"

# makepkg config
sed -i \
    -e "s/^#MAKEFLAGS=/MAKEFLAGS=/" \
    -e "s/MAKEFLAGS=.*/MAKEFLAGS=$INSTALLER_THREADS/" \
    -e "s/^\(OPTIONS=.*\) debug \(.*\)/\1 !debug \2/" \
    "$MNT/etc/makepkg.conf"

# vi(m) compatibility
if (( INSTALLER_USE_VI_NVIM_SYMLINK )); then
    ln -rs "$MNT/usr/bin/nvim" "$MNT/usr/bin/vim"
    ln -rs "$MNT/usr/bin/vim" "$MNT/usr/bin/vi"
fi
set +x

################################################################################
@ "Copying installer files"
################################################################################
for cfg in $(find "$CFG" -type f | sed "s|^$CFG/||" | grep -v "README"); do
    dir="$MNT/$(dirname "$cfg")"

    if ! [ -e "$dir" ]; then
        mkdir -vp "$dir"
    fi

    if ! [ -d "$dir" ]; then
        printf "WARNING: %s cannot be made for %s" "$dir" "$cfg"
    fi

    cp -v "$CFG/$cfg" "$MNT/$cfg"
done

################################################################################
@ "Generating bootloader config"
################################################################################
root_uuid="$(blkid -o value -s UUID "$ROOT_DISK")"
crypt_uuid="$(blkid -o value -s UUID "$CRYPT_DISK")"

# FIXME: use variable kernel name
set -x
mkdir -p "$MNT/$ESP/loader/entries"
tee "$MNT/$ESP/loader/loader.conf" << EOF
default  archlinux.conf
timeout  4
console-mode max
editor   no
EOF

mkdir -p "$MNT/boot/loader/entries"
tee "$MNT/boot/loader/entries/archlinux.conf" << EOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options root=UUID=$root_uuid cryptdevice=UUID=$crypt_uuid:$CRYPT_NAME rw
EOF
set +x

################################################################################
@ "Running chroot"
################################################################################
set -x
arch-chroot "$MNT" << STOP_CHROOT
PS1="\033[35mchroot#\033[0m "
set -euo pipefail
trap "exec $USER_SHELL" SIGINT SIGHUP SIGTERM

#
# Set timezone, clock and locale
#

timedatectl set-ntp true
hwclock --systohc
locale-gen

#
# Enabling systemd services
#

[ -n "${INSTALLER_ENABLE_UNITS[@]}" ] \
    && systemctl enable ${INSTALLER_ENABLE_UNITS[@]}

#
# Create user
#

groupadd -g 1000 "$USER_NAME"

useradd \\
    -u 1000 \\
    -g "$USER_NAME" \\
    -G "$USER_GROUPS" \\
    -s "$USER_SHELL" \\
    -m "$USER_NAME"

#
# Add user to sudoers file
#

printf "\n%s\tALL=(ALL:ALL)\tALL" "$USER_NAME" | EDITOR="tee -a" visudo

#
# install AUR helper
#

mkdir -vp "$PKG_ROOT" || true

git clone "$AUR_URL/$AUR_HELPER_PKG.git" "$PKG_ROOT/$AUR_HELPER_PKG"
sleep 0.5

chown -R $USER_NAME:$USER_NAME "$PKG_ROOT"
sleep 0.5

su "$USER_NAME" -l -c "makepkg -s -D '$PKG_ROOT/$AUR_HELPER_PKG'"
sleep 0.5

pacman --noconfirm -U "$PKG_ROOT/$AUR_HELPER_PKG/$AUR_HELPER_PKG"*.zst
rm -fr "$PKG_ROOT"

#
# Lock root account
#

passwd -l root

#
# Regenerate initcpio
#

mkinitcpio -P

#
# Install bootloader
#

bootctl install --esp-path="$ESP" --boot-path="/boot"

STOP_CHROOT

arch-chroot "$MNT" passwd -s "$USER_NAME" < "$PWCACHE_USER"
set +x

################################################################################
@ "Unmounting disks"
################################################################################
set -x
umount \
    "$MNT/$ESP" \
    "$MNT/boot" \
    "$MNT/home" \
    "$MNT/tmp" \
    "$MNT/var" \
    "$MNT"
set +x

echo "Done! Reboot to enter the next stage of the installer."
