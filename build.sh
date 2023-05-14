#!/bin/sh

SRC=packer
TARGET=output

# build the boxfile from the iso
(cd $SRC && sudo PACKER_LOG=1 PACKER_LOG_PATH="./packer.log" packer build -force template.json)

# test if there is a boxfile where we expected it
if [ ! -f $SRC/output-qemu/archlinux ]; then
	    echo "Looks like something went wrong building the image, maybe try again?"
	        exit 1
fi;

# clean up any previous loops and mounts
echo "Making sure mountpoint is empty"
LOOP_DEV=$(sudo losetup -f)

sudo umount diskmount -f || /bin/true
sudo kpartx -d $LOOP_DEV || /bin/true
sudo losetup -d $LOOP_DEV || /bin/true

# mount the generated raw image, we do that so we can create
# a json mapping of it and copy it to host on the webserver
mkdir -p diskmount
echo "Mounting the created image so we can convert it to a p9 image"
sudo losetup $LOOP_DEV $SRC/output-qemu/archlinux
sudo kpartx -a $LOOP_DEV
sudo mount /dev/mapper/$(basename $LOOP_DEV)p1 diskmount

# make images dir
mkdir -p $TARGET
mkdir -p $TARGET/images
mkdir -p $TARGET/images/arch

# map the filesystem to json with fs2json
sudo ./tools/fs2json.py --out $TARGET/images/fs.json diskmount
sudo ./tools/copy-to-sha256.py diskmount $TARGET/images/arch

# copy the filesystem and chown to nonroot user
echo "Copying the filesystem to $TARGET/arch"
mkdir $TARGET/arch -p
sudo rsync -q -av diskmount/ $TARGET/arch
sudo chown -R $(whoami):$(whoami) $TARGET/arch

# clean up mount
echo "Cleaning up mounts"
sudo umount diskmount -f
sudo kpartx -d $LOOP_DEV
sudo losetup -d $LOOP_DEV

# Move the image to the images dir
sudo mv $SRC/output-qemu/archlinux $TARGET/images/arch.img
