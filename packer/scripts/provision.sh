#!/bin/bash
echo "Creating a GPT partition on /dev/sda1"
echo -e "g\nn\n\n\n\nw" | fdisk /dev/sda

# In case you might want to create a DOS partition instead. It doesn't really matter.
#echo "Creating a DOS partition on /dev/sda1"
#echo -e "o\nn\np\n1\n\n\nw" | fdisk /dev/sda

echo "Formatting /dev/sda1 to ext4"
mkfs -t ext4 /dev/sda1

echo "Mounting new filesystem"
mount -t ext4 /dev/sda1 /mnt

echo "Create pacman package cache dir"
mkdir -p /mnt/var/cache/pacman/pkg

# We don't want the pacman cache to fill up the image. After reboot whatever tarballs pacman has cached are gone.
echo "Mount the package cache dir in memory so it doesn't fill up the image"
mount -t tmpfs none /mnt/var/cache/pacman/pkg

echo "Updating archlinux-keyring"
pacman -Sy archlinux-keyring --noconfirm

# uncomment to remove signing if unable to resolve signing errors
sed -i 's/SigLevel.*/SigLevel = Never/g' /etc/pacman.conf

# Install the Archlinux base system, feel free to add packages you need here
echo "Performing pacstrap"
pacstrap -i /mnt base linux dhcpcd curl openssh --noconfirm

echo "Writing fstab"
genfstab -p /mnt >> /mnt/etc/fstab

# When the Linux boots we want it to automatically log in on tty1 as root
echo "Ensuring root autologin on tty1"
mkdir -p /mnt/etc/systemd/system/getty@tty1.service.d
cat << 'EOF' > /mnt/etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin root --noclear %I $TERM
EOF

# This is the tricky part. The current root will be mounted on /dev/sda1 but after we reboot
# it will try to mount root during boot using the 9p network filesystem. This means the emulator
# will request all files over the network using XMLHttpRequests from the server. This is great
# because then you only need to provide the client with a saved state (the memory) and the
# session will start instantly and load needed files on the fly. This is fast and it saves bandwidth.
echo "Ensuring root is remounted using 9p after reboot"
mkdir -p /mnt/etc/initcpio/hooks
cat << 'EOF' > /mnt/etc/initcpio/hooks/9p_root
run_hook() {
    mount_handler="mount_9p_root"
}

mount_9p_root() {
    msg ":: mounting '$root' on real root (9p)"
    # Note the host9p. We won't mount /dev/sda1 on root anymore,
    # instead we mount the network filesystem and the emulator will
    # retrieve the files on the fly.
    if ! mount -t 9p host9p "$1"; then
        echo "You are now being dropped into an emergency shell."
        launch_interactive_shell
        msg "Trying to continue (this will most likely fail) ..."
    fi
}
EOF

echo "Adding initcpio build hook for 9p root remount"
mkdir -p /mnt/etc/initcpio/install
cat << 'EOF' > /mnt/etc/initcpio/install/9p_root
#!/bin/bash
build() {
	add_runscript
}
EOF

# We need to load some modules into the kernel for it to play nice with the emulator
# The atkbd and i8042 modules are for keyboard input in the browser. If you do not
# want to use the network filesystem you only need these. The 9p, 9pnet and 9pnet_virtio
# modules are needed for being able to mount 9p network filesystems using the emulator.
echo "Configure mkinitcpio for 9p"
sed -i 's/MODULES=()/MODULES=(atkbd i8042 libps2 serio serio_raw psmouse virtio_pci virtio_pci_modern_dev 9p 9pnet 9pnet_virtio fscache netfs)/g' /mnt/etc/mkinitcpio.conf

# Because we want to mount the root filesystem over the network during boot, we need to
# hook into initcpio. If you do not want to mount the root filesystem during boot but
# only want to mount a 9p filesystem later, you can leave this out. Once the system
# has been booted you should be able to mount 9p filesystems with mount -t 9p host9p /blabla
# without this hook.
sed -i 's/fsck"/fsck 9p_root"/g' /mnt/etc/mkinitcpio.conf

# enable ssh password auth and root login
sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config

echo "Writing the installation script"
cat << 'EOF' > /mnt/bootstrap.sh
#!/usr/bin/bash
echo "Re-generate initial ramdisk environment"
mkinitcpio -p linux

# uncomment to remove signing if you are unable to resolve signing errors otherwise
sed -i 's/SigLevel.*/SigLevel = Never/g' /etc/pacman.conf

pacman -S --noconfirm syslinux gptfdisk
syslinux-install_update -i -a -m

# disabling ldconfig to speed up boot (to remove Rebuild dynamic linker cache...)
# you may want to comment this out
echo "Disabling ldconfig service"
systemctl mask ldconfig.service

sync
EOF

echo "Chrooting and bootstrapping the installation"
arch-chroot /mnt bash bootstrap.sh


cat << 'EOF' > /mnt/boot/syslinux/syslinux.cfg
# Config file for Syslinux -
# /boot/syslinux/syslinux.cfg
#
# Comboot modules:
#   * menu.c32 - provides a text menu
#   * vesamenu.c32 - provides a graphical menu
#   * chain.c32 - chainload MBRs, partition boot sectors, Windows bootloaders
#   * hdt.c32 - hardware detection tool
#   * reboot.c32 - reboots the system
#
# To Use: Copy the respective files from /usr/lib/syslinux to /boot/syslinux.
# If /usr and /boot are on the same file system, symlink the files instead
# of copying them.
#
# If you do not use a menu, a 'boot:' prompt will be shown and the system
# will boot automatically after 5 seconds.
#
# Please review the wiki: https://wiki.archlinux.org/index.php/Syslinux
# The wiki provides further configuration examples

DEFAULT arch
PROMPT 0        # Set to 1 if you always want to display the boot: prompt
TIMEOUT 100

# Menu Configuration
# Either menu.c32 or vesamenu32.c32 must be copied to /boot/syslinux
UI menu.c32
#UI vesamenu.c32

# Refer to http://syslinux.zytor.com/wiki/index.php/Doc/menu
MENU TITLE Arch Linux
#MENU BACKGROUND splash.png
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std
MENU COLOR help         37;40   #c0ffffff #a0000000 std
MENU COLOR timeout_msg  37;40   #80ffffff #00000000 std
MENU COLOR timeout      1;37;40 #c0ffffff #00000000 std
MENU COLOR msg07        37;40   #90ffffff #a0000000 std
MENU COLOR tabmsg       31;40   #30ffffff #00000000 std

# boot sections follow
#
# TIP: If you want a 1024x768 framebuffer, add "vga=773" to your kernel line.
#
#-*

LABEL arch
    MENU LABEL Arch Linux 9p
    LINUX ../vmlinuz-linux
    APPEND root=/dev/sda1 rw quiet
    INITRD ../initramfs-linux.img

LABEL arch2
    MENU LABEL Arch Linux Disk
    LINUX ../vmlinuz-linux
    APPEND root=/dev/sda1 rw quiet disablehooks=9p_root
    INITRD ../initramfs-linux.img

LABEL hdt
        MENU LABEL HDT (Hardware Detection Tool)
        COM32 hdt.c32

LABEL reboot
        MENU LABEL Reboot
        COM32 reboot.c32

LABEL poweroff
        MENU LABEL Poweroff
        COM32 poweroff.c32
EOF
umount -R /mnt
