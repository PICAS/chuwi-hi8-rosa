#!/bin/sh
#
# Модифицируем ISO образ ОС ROSA
#

# Название результирующего образа получается заменой фрагмента имени оригинала
NAME_ORIG='uefi'
NAME_DEST='uefi3264-Silvermont'

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

echo 'Добавляем 32х разрядный EFI загрузчик'
rm -rf rpms
mkdir rpms
get_rpm()
{
    REPO_URL=http://abf-downloads.rosalinux.ru/rosa2016.1/repository/i586/main/release
    [[ -e $@ ]] || wget $REPO_URL/$@ || die "недоступен $@"
    rpm2cpio $@ | cpio -dium --directory=rpms || die "ошибка распаковки $@"
}
GRUB_PKG=grub2-efi-2.00-79-rosa2014.1.i586.rpm
SHIM_PKG=shim-0.9-3-rosa2016.1.i586.rpm
get_rpm $SHIM_PKG
get_rpm $GRUB_PKG
cp rpms/boot/efi/EFI/rosa/grub2-efi/grubcd.efi $ISO_DIR/EFI/BOOT/grubia32.efi
cp rpms/boot/efi/EFI/rosa/BOOTIA32.efi $ISO_DIR/EFI/BOOT/
echo 'Создаём образ заргузочного EFI раздела'
mkdir efiboot
rm $ISO_DIR/isolinux/efiboot.img &&
dd of=$ISO_DIR/isolinux/efiboot.img if=/dev/zero bs=512K count=`du -sB 512K $ISO_DIR/EFI | sed s/[^0-9]//g` &&
mkfs.fat -F 12 -n 'EFI' $ISO_DIR/isolinux/efiboot.img &&
sudo mount $ISO_DIR/isolinux/efiboot.img efiboot &&
sudo cp -R $ISO_DIR/EFI/ efiboot/EFI/ || die 'ошибка создания загрузочного раздела'
sudo umount efiboot
rmdir efiboot

unsquashfs -d $SQUASHFS_ROOT $ISO_DIR/$SQUASH_IMG || die 'ошибка рапаковки SquashFS'

echo "Монтируем $SYSTEM_IMG"
mkdir $SYSTEM_ROOT
sudo mount -o noatime $SQUASHFS_ROOT/$SYSTEM_IMG $SYSTEM_ROOT || die 'ошибка монтирования'

echo 'Обновляем'

[ -e cache ] && echo 'Копируем кэш пакетов' && sudo rsync -a cache/ $SYSTEM_ROOT/var/cache/urpmi/

echo -en '\x1b[1m'
##############################################################################
sudo tee $SYSTEM_ROOT/runme << EOF
# Следующие команды выполнятся в контексте распакованного образа
cat /etc/os-release

# Отключаем чрезмерные циклы записи при установке пакетов
echo 'export PKGSYSTEM_ENABLE_FSYNC=0' > /etc/profile.d/update-mime-database.sh
echo '%__nofsync nofsync' >> /etc/rpm/macros

# Образ ориентрован не на вирт.машины.
urpme dkms-vboxadditions --auto

# Репозиторий с адаптированным ядром и alsa-lib
urpmi.addmedia st_personal http://abf-downloads.rosalinux.ru/st_personal/repository/rosa2016.1/x86_64/main/release/

# Репозиторий с обновлённым графическим стеком
urpmi.addmedia x11 http://abf-downloads.rosalinux.ru/x11_backports_personal/repository/rosa2016.1/x86_64/main/release/
urpmi.addmedia x11-32 http://abf-downloads.rosalinux.ru/x11_backports_personal/repository/rosa2016.1/i586/main/release/

# Версия драйвера Broadcom-WL для 4.13 на QA
urpmi.addmedia wl http://abf-downloads.rosalinux.ru/rosa2016.1/container/2899354/x86_64/non-free/release/

urpme dkms-broadcom-wl

# Актуализируем версии пакетов
/usr/sbin/urpmi --auto-update --auto

# Дополнительные пакеты
urpmi qt5-qtvirtualkeyboard --auto
urpmi vaapi-driver-intel libva-utils --auto

# Временная конфигурация dracut
echo 'hostonly="no"' > /etc/dracut.conf.d/tmplive.conf
echo 'add_dracutmodules+=" dmsquash-live pollcdrom "' >> /etc/dracut.conf.d/tmplive.conf
echo 'omit_dracutmodules+=" aufs-mount "' >> /etc/dracut.conf.d/tmplive.conf

# Заменяем обычное ядро адаптированным
urpmi kernel-tablet-4.13-latest kernel-tablet-4.13-devel-latest --auto

urpme kernel-nrj-desktop-4.9-devel-latest kernel-nrj-desktop-4.9-latest --force
urpme kernel-nrj-desktop-devel kernel-nrj-desktop -a --auto
urpmi dkms-broadcom-wl
rm -f /boot/initrd-4.{9,11,12}*
rm -f /boot/*old.img
rm /etc/dracut.conf.d/tmplive.conf
chmod +r /boot/initrd*

urpmi.removemedia wl

# Адаптируем конфигурацию PulseAudio
echo '# Byt/Cht' >> /etc/pulse/daemon.conf
echo 'realtime-scheduling = no' >> /etc/pulse/daemon.conf
echo '#sample rate supported by hardware: check "pactl list sinks" output)' >> /etc/pulse/daemon.conf
echo 'default-sample-rate = 48000' >> /etc/pulse/daemon.conf
echo 'resample-method = speex-float-1' >> /etc/pulse/daemon.conf

# Адаптируем конфигурацию NetworkManager для Rtl8723BS
echo '[device]' >> /etc/NetworkManager/NetworkManager.conf
echo '#match-device=interface-name:wlan0' >> /etc/NetworkManager/NetworkManager.conf
echo 'wifi.scan-rand-mac-address=no' >> /etc/NetworkManager/NetworkManager.conf

# Включаем qtvirtualkeyboard
echo 'export QT_IM_MODULE=qtvirtualkeyboard' > /etc/profile.d/qtvk.sh

# Поддержка сенсорного экрана в Firefox
echo 'export MOZ_USE_XINPUT2=1' > /etc/profile.d/firefox.sh

# Значки от Рамиля
urpmi http://abf-downloads.rosalinux.ru/survolog_personal/repository/rosa2016.1/x86_64/main/release/rospo-icon-theme-1.0-1-rosa2016.1.noarch.rpm

# Должно исключить "Rebuild dynamic linker cache" при запуске
rm /etc/ld.so.cache
ldconfig

rpm -qa | sort > /rpm.list
EOF
##############################################################################
echo -en '\x1b[0m'

sudo chmod +x $SYSTEM_ROOT/runme
echo -en '\x1b[1;33m'
sudo mount --bind /dev/    $SYSTEM_ROOT/dev
sudo mount --bind /dev/pts $SYSTEM_ROOT/dev/pts
sudo mount --bind /proc    $SYSTEM_ROOT/proc
sudo mount --bind /sys     $SYSTEM_ROOT/sys
sudo cp /etc/resolv.conf $SYSTEM_ROOT/etc/
sudo env PKGSYSTEM_ENABLE_FSYNC=0 chroot $SYSTEM_ROOT /bin/bash --login /runme
echo -en '\x1b[0m'

sudo umount $SYSTEM_ROOT/sys
sudo umount $SYSTEM_ROOT/proc
sudo umount $SYSTEM_ROOT/dev/pts
sudo umount $SYSTEM_ROOT/dev

echo "Устанавливаем $GRUB_PKG и $SHIM_PKG"
rm -rf rpms/{etc,usr/{bin,sbin,share}}
sudo rsync -rlpt rpms/ $SYSTEM_ROOT/ || die "ошибка копирования $GRUB_PKG и $SHIM_PKG"
# так же исправляет и установленный grub2
sudo patch -p1 -d $SYSTEM_ROOT -i ../grub-install-choose-correct-efi-loader.patch

echo "Копируем дополнительные файлы"
sudo rsync -rlpt extra/ $SYSTEM_ROOT/

# Формируем актуальный перечень установленных пакетов, добавив дату изменения
BUILD_NO=`head --lines 1 $ISO_DIR/rpm.lst`
echo -en "$BUILD_NO\n# Modified on " > $ISO_DIR/rpm.lst
date -R >> $ISO_DIR/rpm.lst
cat $SYSTEM_ROOT/rpm.list >> $ISO_DIR/rpm.lst

# Копируем ядро в стартовый каталог ISO
cp $SYSTEM_ROOT/boot/vmlinuz* $ISO_DIR/isolinux/vmlinuz0
cp $SYSTEM_ROOT/boot/initrd* $ISO_DIR/isolinux/initrd0.img

echo 'Убираем за собой'
sudo rm $SYSTEM_ROOT/runme $SYSTEM_ROOT/rpm.list $SYSTEM_ROOT/Module.symvers
sudo rm -f $SYSTEM_ROOT/var/cache/urpmi/rpms/*

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
