#!/bin/sh
#
# Модифицируем ISO образ ОС ROSA
#

# Название результирующего образа получается заменой фрагмента имени оригинала
NAME_ORIG='.iso'
NAME_DEST='-v2.iso'

# Имя файла SquashFS в составе образа
SQUASH_IMG='LiveOS/squashfs.img'
SYSTEM_IMG='LiveOS/ext3fs.img'

# Алгоритм сжатия SquashFS
#COMPRESSOR='lz4'
#COMPRESSOR='lz4 -Xhc'
#COMPRESSOR='lzo'
#COMPRESSOR='lzo -Xcompression-level 9'
#COMPRESSOR='gzip'
COMPRESSOR='xz'

die()
{
    echo -e "\x1b[1;31m$@\x1b[0m"
    exit 1
}

((`ls -l *.iso 2> /dev/null | wc -l` == 1)) || die 'Поместите 1 ISO образ в рабочий каталог'

ISO_SRC=`ls *.iso`
ISO_VOL=`isoinfo -j UTF-8 -d -i $ISO_SRC | grep 'Volume id:' | sed 's/Volume id: //'`
echo "Обрабатывается $ISO_SRC [Volume id: $ISO_VOL]"
ISO_DST=`echo $ISO_SRC | sed s/$NAME_ORIG/$NAME_DEST/`

ISO_DIR='iso'
SYSTEM_ROOT='system-root'

echo 'Монтируем слои'
mkdir mnt mnt/iso mnt/squash
mount $ISO_SRC mnt/iso || die "ошибка монтирования $ISO_SRC"
mount mnt/iso/$SQUASH_IMG mnt/squash || die "ошибка монтирования $SQUASH_IMG"
if [[ -f mnt/squash/$SYSTEM_IMG ]]; then
    echo 'SquashFS содержит образ с файловой системой'
    mkdir mnt/fs
    mount -o ro mnt/squash/$SYSTEM_IMG mnt/fs || die "ошибка монтирования $SYSTEM_IMG"
else
    ln -rs mnt/squash mnt/fs
fi

echo 'Копируем образ'
rm -rf $ISO_DIR
mkdir $ISO_DIR
rsync --exclude=$SQUASH_IMG -a mnt/iso/ $ISO_DIR

echo 'Копируем файловую систему'
rsync -a mnt/fs/ $SYSTEM_ROOT

[[ -f mnt/squash/$SYSTEM_IMG ]] && umount mnt/fs
umount mnt/squash mnt/iso
rm -rf mnt

echo 'Обновляем'
echo -en '\x1b[1m'
##############################################################################
tee $SYSTEM_ROOT/runme << EOF
# Следующие команды выполнятся в контексте распакованного образа
cat /etc/os-release

rpm -qa | sort > /rpm.list
EOF
##############################################################################
echo -en '\x1b[0m'

chmod +x $SYSTEM_ROOT/runme
echo -en '\x1b[1;33m'
systemd-nspawn --directory=$SYSTEM_ROOT /runme
echo -en '\x1b[0m'

# Формируем актуальный перечень установленных пакетов, добавив дату изменения
BUILD_NO=`head --lines 1 $ISO_DIR/rpm.lst`
echo -en "$BUILD_NO\n# Modified on " > $ISO_DIR/rpm.lst
date -R >> $ISO_DIR/rpm.lst
cat $SYSTEM_ROOT/rpm.list >> $ISO_DIR/rpm.lst

echo 'Убираем за собой'
rm $SYSTEM_ROOT/runme $SYSTEM_ROOT/rpm.list

echo 'Создаём SquashFS'
rm -f $ISO_DIR/$SQUASH_IMG
[[ "x$COMPRESSOR" == "x" ]] && COMPRESSOR='xz'
mksquashfs $SYSTEM_ROOT $ISO_DIR/$SQUASH_IMG -no-exports -noappend -no-recovery -no-fragments -comp $COMPRESSOR 2>/dev/null

echo "Создаём новый образ $ISO_DST"

if (( 0 )) ; then
genisoimage -JURT -quiet \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -eltorito-alt-boot \
    -e isolinux/efiboot.img \
    -no-emul-boot \
    -input-charset utf-8 \
    -V $ISO_VOL \
    -o $ISO_DST \
    $ISO_DIR
isohybrid --uefi $ISO_DST
else
xorriso -as mkisofs \
    -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -eltorito-alt-boot \
    -e isolinux/efiboot.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -V $ISO_VOL \
    -o $ISO_DST \
    $ISO_DIR
fi
