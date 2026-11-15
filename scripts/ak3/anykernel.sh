# AnyKernel3 Ramdisk Mod Script
# osm0sis @ xda-developers

## AnyKernel setup
# begin properties
properties() { '
do.devicecheck=0
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=alioth
device.name2=aliothin
device.name3=apollo
device.name4=apolloin
device.name5=lmi
supported.versions=
supported.patchlevels=
'; } # end properties

# shell variables
block=boot;
is_slot_device=auto;
ramdisk_compression=auto;
patch_vbmeta_flag=auto;
no_block_display=1

## AnyKernel methods (DO NOT CHANGE)
# import patching functions/variables - see for reference
. tools/ak3-core.sh;

## Select the correct image to flash
userflavor="$(file_getprop /system/build.prop "ro.build.flavor")";
case "$userflavor" in
    aospa_alioth-user) os="aospa"; os_string="Paranoid Android ROM";;
    aospa_apollo-user) os="aospa"; os_string="Paranoid Android ROM";;
    aospa_lmi-user) os="aospa"; os_string="Paranoid Android ROM";;
    missi-user) os="miui"; os_string="MIUI ROM";;
    missi_phoneext4_cn-user) os="miui"; os_string="MIUI ROM";;
    missi_phone_cn-user) os="miui"; os_string="MIUI ROM";;
    qssi-user) os="miui"; os_string="MIUI ROM";;
    *) os="aosp"; os_string="AOSP ROM";;
esac;
ui_print "  -> $os_string is detected!";

mv $home/kernels/Image $home/Image;

# If you have some problems with the new kernel, try to uncomment the following line to also flash the [dtb].
# mv $home/kernels/dtb $home/dtb;

## AnyKernel boot install
split_boot;

flash_boot;
# flash_dtbo;
## end boot install

# Vendor boot
#block=vendor_boot;
#is_slot_device=1;
#ramdisk_compression=auto;
#patch_vbmeta_flag=auto;

# reset for vendor_boot patching
#reset_ak;

## AnyKernel vendor_boot install
#split_boot;

#flash_boot;
## end vendor_boot install
