# Arch Linux installer
----------------------
This is my Arch Linux installer script. To use the installer, boot into an
Arch ISO and run the following commands:

```
archiso# pacman --needed --noconfirm -S git
archiso# git clone https://github.com/lamekino/my-arch-installer
archiso# ./my-arch-installer/installer.sh
```

# Configuration
---------------
I tried to make the installer fairly modular, in the top section of the script
you can change variables to change how the installer works, ie:

### Directories
- $MNT: path to mount the system to
- $ESP: path for UEFI partition (either /boot/efi or /efi [UNTESTED])
- $CFG: the directory to copy configurations from
- $PKG_ROOT: the directory to build AUR packages in chroot

### Installer
- $INSTALLER_*: installer behavior
- $INSTALLER_PACKAGES: packages to install on pacstrap.
- $AUR_HELPER_PKG: the AUR helper to install

### System configuration
- $OS_*: configures installed OS
- $USER_*: configures the non-root user

### Partition Configuration
- $*_LABEL   : partition label
- $*_NAME    : mapped partition name
- $*_DISK    : path to disk (via /dev/disk/by-partlabel)
- $*_SIZE    : size of partition in SI units
- $*_OPTIONS : options to pass to to mount (-o)

# Testing
---------
Thanks to [qemus/qemu](https://github.com/qemus/qemu) you can test the installer
in a virtual machine pretty easily with Docker Compose.

GDM won't start in the VM. It can be disabled in the installer by setting the
`INSTALLER_ENABLE_DISPLAY_MANAGER` variable to 0.

### 1. Start the VM:

```
host# docker compose up
```

### 2. Open the VM in a web browser: [localhost:8006](http://127.0.0.1:8006/).

### 3. Mount the installer directory

```
vm-archiso# mkdir -p '/net'
vm-archiso# mount -t 9p -o trans=virtio 'shared' '/net'
```

You can bind `./utils/vm-mount-ydotool.sh` to a keyboard macro to automate
copying this to the VM window.

### 4. Reset the installation and remove the VM's data

```
host# rm -fr ./vm-files/data.img
```

# Feature Wishlist
------------------
- Allow installing a kernel other than `linux`, ie `linux-lts`
- Make the AUR helper optional
