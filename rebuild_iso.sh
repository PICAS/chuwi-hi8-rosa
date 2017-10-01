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
SQUASHFS_ROOT='squashfs-root'
SYSTEM_ROOT='system-root'

echo 'Распаковываем образ'
rm -rf $ISO_DIR
mkdir $ISO_DIR
7z x $ISO_SRC -o$ISO_DIR -bso0 || die 'ошибка распаковки ISO'
rm -rf $ISO_DIR'/[BOOT]'

unsquashfs -d $SQUASHFS_ROOT $ISO_DIR/$SQUASH_IMG || die 'ошибка рапаковки SquashFS'

echo "Монтируем $SYSTEM_IMG"
mkdir $SYSTEM_ROOT
sudo mount -o noatime $SQUASHFS_ROOT/$SYSTEM_IMG $SYSTEM_ROOT || die 'ошибка монтирования'

echo 'Обновляем'
echo -en '\x1b[1m'
##############################################################################
sudo tee $SYSTEM_ROOT/runme << EOF
# Следующие команды выполнятся в контексте распакованного образа
cat /etc/os-release

rpm -qa | sort > /rpm.list
EOF
##############################################################################
echo -en '\x1b[0m'

sudo chmod +x $SYSTEM_ROOT/runme
echo -en '\x1b[1;33m'
sudo systemd-nspawn --directory=$SYSTEM_ROOT /runme
echo -en '\x1b[0m'

# Формируем актуальный перечень установленных пакетов, добавив дату изменения
BUILD_NO=`head --lines 1 $ISO_DIR/rpm.lst`
echo -en "$BUILD_NO\n# Modified on " > $ISO_DIR/rpm.lst
date -R >> $ISO_DIR/rpm.lst
cat $SYSTEM_ROOT/rpm.list >> $ISO_DIR/rpm.lst

echo 'Убираем за собой'
sudo rm $SYSTEM_ROOT/runme $SYSTEM_ROOT/rpm.list

# Для лучшего сжатия зануляем свободные блоки файловой системы
sudo cp /dev/zero $SYSTEM_ROOT/free_space 2> /dev/null
sudo rm $SYSTEM_ROOT/free_space

sudo umount $SYSTEM_ROOT
rmdir $SYSTEM_ROOT

sudo tune2fs -C 0 -M '' $SQUASHFS_ROOT/$SYSTEM_IMG

rm -f $ISO_DIR/$SQUASH_IMG
if [ "x$COMPRESSOR" == "x" ] ; then
    echo 'Запуск ОС без SquashFS не поддерживается!?'
    mv $SQUASHFS_ROOT/$SYSTEM_IMG $ISO_DIR/$SQUASH_IMG
else
    mksquashfs $SQUASHFS_ROOT $ISO_DIR/$SQUASH_IMG -no-exports -noappend -no-recovery -no-fragments -all-root -comp $COMPRESSOR
fi

rm -r $SQUASHFS_ROOT

echo "Создаём новый образ $ISO_DST"

if (( 0 )) ; then
genisoimage -JURT -quiet \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -eltorito-alt-boot \
    -e EFI/BOOT/grubx64.efi \
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
    -e EFI/BOOT/grubx64.efi \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -V $ISO_VOL \
    -o $ISO_DST \
    $ISO_DIR
fi
