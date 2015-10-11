#!/bin/ash
# (the pogoplug ships with busybox, so we have ash instead of bash.)

# pogoplug_mobile_uboot_installer.sh: A script which installs uboot onto 
# a Pogoplug Mobile (allowing you to boot Linux from USB / SD card).
#
# see https://github.com/pepaslabs/pogoplug_mobile_uboot_installer
#
# credits:
#
# this script is based on the instructions in Qui's blog post:
# http://blog.qnology.com/2014/07/hacking-pogoplug-v4-series-4-and-mobile.html
#
# Qui's work was in turn based on work from the crew at the doozan forums.
# see http://forum.doozan.com/


### functions

echo_step()
{
    echo
    echo "* $@"
}

echo2()
{
    echo "$@" >&2
}

prompt_to_proceed()
{
    local message="$1"

    read -p "${message} [y/n]: " yn
    case $yn in
        [Yy]* ) echo "Proceeding..." ; break;;
        * ) echo2 "Exiting..." ; exit 1;;
    esac
    # thanks to http://stackoverflow.com/a/226724
}


### initial sanity-checks

cd /tmp

echo_step "Sanity-checking the stock pogoplug linux install"
md5sum -c - << EOF
0ddfeeeee0d4587dce713895aeb41a7b  /proc/version
818eaefe5af1c1ccdf6eeb343152a983  /bin/busybox
EOF
pogolinux_is_sane=$?

if [ $pogolinux_is_sane -ne 0 ]
then
    echo2
    echo2 "ERROR: The MD5 sums of your /bin/busybox or /proc/version don't match what"
    echo2 "shipped with my pogoplug.  I'm guessing that means you aren't booted into"
    echo2 "the stock Linux distro which shipped with the pogoplug mobile (e.g. you are"
    echo2 "trying to run this script from a Debian or Arch Linux install).  This script"
    echo2 "was written assuming you are running the stock distro, so it isn't safe for"
    echo2 "this script to continue executing."
    echo2
    echo2 "The other possibility is that your pogoplug shipped with an earlier or"
    echo2 "later stock build than mine, which is why the MD5 sums don't match."
    echo2

    if [ "${BRICK_MY_POGO}" -eq 1 ]
    then
        prompt_to_proceed "Proceed anyway?  This might brick your pogo..."
    else
        echo2 "If that's the case, and you are SURE YOU KNOW WHAT YOU ARE DOING, then"
        echo2 "export the env variable BRICK_MY_POGO=1 and re-run this script."
        echo2
        echo2 "e.g.:"
        echo2 "export BRICK_MY_POGO=1"
        echo2 "./pogoplug_mobile_uboot_installer.sh"
        echo2
        echo2 "Exiting..."
        exit 1
    fi
fi


# entering "strict" mode
set -e
set -u
set -o pipefail

# verbose
#set -x

if ps | grep hbwd
then
    echo_step "Stopping my.pogoplug.com service (hbwd)"
    killall hbwd || true
fi


### user info gathering section

mac=$(cat /sys/class/net/eth0/address)
echo_step "Verify your MAC address (see the sticker on the bottom of your pogoplug)"
prompt_to_proceed "Is your MAC address $mac?"


### cache / downloads section

echo_run()
{
    echo "+ $@"
    eval "$@"
}

md5_step()
{
    local file="$1"
    local sum="$2"

    echo_step "Verifying ${file}"
    echo "${sum}  ${file}" | md5sum -c -
}

wget_step()
{
    local file="$1"
    local baseurl="$2"
    local sum="$3"

    if [ ! -e ${file} ]
    then
        echo_step "Downloading ${file}"
        echo_run wget "${baseurl}/${file}"
    fi

    if pwd | grep -q '/bin'
    then
        chmod +x "${file}"
    fi

    md5_step "${file}" "${sum}"
}

mkdir -p /tmp/bin /tmp/dev /tmp/cache /tmp/mnt
export PATH=/tmp/bin:${PATH}

# download flash utils
cd /tmp/bin
baseurl="http://download.qnology.com/pogoplug/v4"
#baseurl="http://pepas.com/pogo/mirrored/download.qnology.com/pogoplug/v4"
wget_step nanddump ${baseurl} 770bbbbe4292747aa8f2163bb1e677bb
wget_step nandwrite ${baseurl} 47974246185ee52deae7cc6cfea5e8fc
wget_step flash_erase ${baseurl} 8b5f9961376281e30a1bd519353484b0
wget_step fw_printenv ${baseurl} 7d28314b0d2737094e57632a6fe43bbe
wget_step fw_setenv ${baseurl} 7d28314b0d2737094e57632a6fe43bbe

# download uboot and uboot env settings
cd /tmp/cache
baseurl="http://download.qnology.com/pogoplug/v4"
#baseurl="http://pepas.com/pogo/mirrored/download.qnology.com/pogoplug/v4"
wget_step uboot.2014.07-tld-1.pogo_v4.bodhi.tar ${baseurl} d4b497dc5239844fd2d45f4ca83132e0
wget_step uboot.2014.07-tld-1.environment.img.bodhi.tar ${baseurl} c5921e3ea0a07a859878339ffb771088

# download original uboot for boot chaining
cd /tmp/cache
baseurl="http://download.doozan.com/uboot/files/uboot"
#baseurl="http://pepas.com/pogo/mirrored/download.doozan.com/uboot/files/uboot"
wget_step uboot.mtd0.dockstar.original.kwb ${baseurl} b2d9681ef044e9ab6b058ef442b30b6e

echo_step "Extracting uboot"
cd /tmp
rm -f uboot.2014.07-tld-1.pogo_v4.mtd0.kwb
cat /tmp/cache/uboot.2014.07-tld-1.pogo_v4.bodhi.tar | tar x
md5_step uboot.2014.07-tld-1.pogo_v4.mtd0.kwb 16a7507135cd4ac8a0795fc9fd8ea0a5

echo_step "Extracting uboot environment settings"
cd /tmp
rm -f uboot.2014.07-tld-1.environment.img
cat /tmp/cache/uboot.2014.07-tld-1.environment.img.bodhi.tar | tar x
md5_step uboot.2014.07-tld-1.environment.img 0069d3706d3c8a4a0c83ab118eaa0cb5


### uboot section

echo_step "Remounting '/' as read/write"
#by default the Pogoplug OS (internal flash) is read only
mount -o remount,rw /

mtd0_md5sum_is_valid()
{
    local bs="${1}"
    local count="${2}"
    local skip="${3}"
    local sum="${4}"

    mtd0_sum=$(dd if=/dev/mtd0 "${bs}" "${count}" "${skip}" | md5sum - | awk '{print $1}')
    [ "${mtd0_sum}" == "${sum}" ]
}

uboot_flash_is_valid()
{
    mtd0_md5sum_is_valid bs=1k count=512 skip=0 16a7507135cd4ac8a0795fc9fd8ea0a5
}

echo_step "Verifying uboot in /dev/mtd0"
if uboot_flash_is_valid
then
    echo_step "Detected up-to-date uboot in /dev/mtd0, skipping install"
else
    echo_step "Detected out-of-date uboot in /dev/mtd0, installing"
    prompt_to_proceed "About to write uboot to /dev/mtd0.  Proceed?"
    echo_run flash_erase /dev/mtd0 0 4
    echo_run nandwrite /dev/mtd0 /tmp/uboot.2014.07-tld-1.pogo_v4.mtd0.kwb

    echo_step "Verifying uboot in /dev/mtd0"
    if ! uboot_flash_is_valid
    then
        echo2
        echo2 "ERROR: Bad md5sum of uboot in /dev/mtd0 after writing!"
        echo2 "Exiting..."
        exit 1
    fi

    rm /tmp/uboot.2014.07-tld-1.pogo_v4.mtd0.kwb
fi

uboot_default_settings_flash_is_valid()
{
    mtd0_md5sum_is_valid bs=1k count=128 skip=768 0069d3706d3c8a4a0c83ab118eaa0cb5
}

echo_step "Setting up default uboot settings in /dev/mtd0"
prompt_to_proceed "About to write uboot settings to /dev/mtd0.  Proceed?"
echo_run flash_erase /dev/mtd0 0xc0000 1
echo_run nandwrite -s 786432 /dev/mtd0 /tmp/uboot.2014.07-tld-1.environment.img

echo_step "Verifying default uboot settings in /dev/mtd0"
if ! uboot_default_settings_flash_is_valid
then
    echo2
    echo2 "ERROR: Bad md5sum of uboot settings in /dev/mtd0 after writing!"
    echo2 "Exiting..."
    exit 1
fi
rm /tmp/uboot.2014.07-tld-1.environment.img


### firmware settings section

echo_step "Setting up /etc/fw_env.config"
echo '/dev/mtd0 0xc0000 0x20000 0x20000' > /etc/fw_env.config

fw_setenv_if_needed()
{
    local key="${1}"
    local value="${2}"

    if [ "$(fw_printenv ${key} 2>/dev/null)" != "${key}=${value}" ]
    then
        echo_step "Setting ${key} in firmware"
        echo "+ fw_setenv" "${key}" "${value}"
        fw_setenv "${key}" "${value}"
    else
        echo_step "Detected up-to-date ${key} in firmware, skipping"
    fi
}

# mac address
fw_setenv_if_needed ethaddr "${mac}"

# arcNumber and machid (for LED)
fw_setenv_if_needed arcNumber 3960
fw_setenv_if_needed machid F78

# Setting rootfs file system type to ext3
fw_setenv_if_needed usb_rootfstype ext3

# Setting to original mtd partition layout
fw_setenv_if_needed mtdparts 'mtdparts=orion_nand:2M(u-boot),3M(uImage),3M(uImage2),8M(failsafe),112M(root)'

# Updating boot order to include pogoplug OS
fw_setenv_if_needed bootcmd 'run bootcmd_usb; run bootcmd_mmc; run bootcmd_sata; run bootcmd_pogo; reset'

# Setting up chain loading (using original uboot)
cd /
rm -f uboot.mtd0.dockstar.original.kwb
cp /tmp/cache/uboot.mtd0.dockstar.original.kwb /
fw_setenv_if_needed bootcmd_pogo 'if ubi part root 2048 && ubifsmount ubi:rootfs && ubifsload 0x800000 uboot.mtd0.dockstar.original.kwb ; then go 0x800200; fi'

# Making SD card the first boot device
# (Default boot order was USB->MMC/SD->SATA->POGO_OS)
fw_setenv_if_needed bootcmd 'run bootcmd_mmc; run bootcmd_usb; run bootcmd_sata; run bootcmd_pogo; reset'


### reboot section

sync

echo
prompt_to_proceed "Ready to reboot.  Proceed?"
/sbin/reboot
