#!/bin/bash
# @Author: Wang Hong
# @Date:   2022-10-22 12:38:37
# @Last Modified by:   Wang Hong
# @Last Modified time: 2022-12-29 11:47:39

Version=1.4.0
ScriptDir=$(cd $(dirname ${BASH_SOURCE}); pwd)
WorkDir=$(pwd)
LiveCDRoot=${WorkDir}
RootDir=${WorkDir}/squashfs-root
SquashfsFile=${WorkDir}/filesystem.squashfs
FileSystemSize=${WorkDir}/filesystem.size
FileSystemManifest=${WorkDir}/filesystem.manifest

ISOExcludeList=(
    "squashfs-root"
    "squashfs-root.bk"
    "squashfs-root.bak"
    "squashfs-root.back"
    "squashfs-root.backup"
    "squashfs-root.old"
    "filesystem.squashfs.bk"
    "filesystem.squashfs.bak"
    "filesystem.squashfs.back"
    "filesystem.squashfs.backup"
    "filesystem.squashfs.old"
)

# Echo Color Settings
C_CLR="\\e[0m"

C_H="\\e[1m"

C_R="\\e[31m"
C_G="\\e[32m"
C_B="\\e[36m"
C_Y="\\e[33m"

C_HR="${C_H}${C_R}"
C_HG="${C_H}${C_G}"
C_HB="${C_H}${C_B}"
C_HY="${C_H}${C_Y}"

C_OK="${C_G}OK${C_CLR}"
C_FL="${C_R}FAILED${C_CLR}"
C_WARN="${C_Y}WARNNING${C_CLR}"
C_ERROR="${C_R}ERROR${C_CLR}"

CheckPrivilege() {
    if [ $UID -ne 0 ]; then
        echo -e  "Please run this script with \033[1m\033[31mroot\033[0m privileges."
        return 1
    else
        return 0
    fi
}

CheckQemuUserSupport() {
    if ! ls /usr/bin/qemu-*-static > /dev/null 2>&1; then
        echo -e "Please install [${C_RED}qemu-user-static${C_CLR}] first"
        return 1
    fi
}

CheckBuildEnvironment() {
    Utils="blkid lsblk losetup parted mkfs.ext4 mkfs.fat mksquashfs findmnt"

    for Util in ${Utils}; do
        if ! which ${Util} >/dev/null 2>&1; then
            echo -e "Please install [${C_RED}${Util}${C_CLR}] first"
            return 1
        fi
    done

    # CheckQemuUserSupport

    return 0
}

GenUUID() {
    local UUID=4c0efd70-04f4-45c4-88f3-fa943249da15
    if which uuid >/dev/null 2>&1; then
        UUID=$(uuid)
    else
        UUID=$(cat /proc/sys/kernel/random/uuid)
    fi
    echo ${UUID}
}

# Usage: IsTargetMounted <Target>
IsTargetMounted() {
    local Usage="Usage: IsTargetMounted <Target>"
    if [ $# -ne 1 ]; then
        echo -e ${Usage}
        return 1
    fi

    local Target=$1

    if [ -d "${Target}" ]; then
        return $(mountpoint -q "${Target}")
    elif [ -f "${Target}" -o -L "${Target}" ]; then
        return $(cat /proc/mounts | /bin/grep -q ${Target})
    else
        return 1
    fi
}

# Usage: GetTargetMountPoint <Target>
GetTargetMountPoint() {
    local Usage="Usage: GetTargetMountPoint <Target>"
    if [ $# -ne 1 ]; then
        echo -e ${Usage}
        return 1
    fi

    local Target=$1
    if [ -e "${Target}" ]; then
        echo "Target:[${Target}] Not Exist!"
        return 1
    fi

    IsTargetMounted "${Target}" || return 1
    local MountedDir=$(lsblk -n -o MOUNTPOINT "${Target}")
    [ -n "${MountedDir}" ] || return 1

    echo "${MountedDir}"
}

# Usage: Mount [-c <RootDir>] [-t <Type> | -b] <Source> <DstDir>
Mount() {
    local Usage="Usage: Mount [-c <RootDir>] [-t <Type> | -b] <Source> <DstDir>"
    local Prefix=""
    local Options=""
    local RootDir=""

    while [ $# -ne 0 ]
    do
        case $1 in
            -c|--chroot)
                RootDir=$2
                Prefix="${Prefix:+${Prefix} }chroot ${RootDir}"
                shift 2
                ;;
            -t|--types)
                local Type=$2
                Options="${Options:+${Options} }--types $2"
                shift 2
                ;;
            -b|--bind)
                Options="${Options:+${Options} }--bind"
                shift
                ;;
            -ro|--readonly)
                Options="${Options:+${Options} }--options ro"
                shift
                ;;
            *)
                if [ $# -ne 2 ]; then
                    echo -e ${Usage}
                    return 1
                fi
                local Source=$1
                local DstDir=$2
                shift 2
                ;;
        esac
    done

    if [ -z "${Source}" -o -z "${DstDir}" ]; then
        echo -e ${Usage} && return 1
    fi

    if eval ${Prefix} mountpoint -q "${DstDir}"; then
        return 0
    fi

    printf "MOUNT: ${C_GEN}${Options:+[${Options}] }${C_YEL}${Source##*${WorkDir}/}${C_CLR} --> ${C_BLU}${DstDir##*${WorkDir}/}${C_CLR}"
    if ! eval ${Prefix} mount ${Options} "${Source}" "${DstDir}" >/dev/null 2>&1; then
        printf " [${C_FL}]\n"
        return 1
    fi
    printf " [${C_OK}]\n"

    return 0
}

# Usage: ReleaseRes <RootDir>
ReleaseRes() {
    local Usage="Usage: ReleaseRes <RootDir>"
    if [ $# -ne 1 ]; then
        echo -e ${Usage}
        return 1
    fi

    local RootDir=$1

    # Stop All Process first!!! TODO: Test Code!
    pushd "${RootDir}/.." > /dev/null
    local ResUsers=($(fuser -a "$(basename "${RootDir}")" 2>/dev/null | grep $(basename "${RootDir}") | awk -F':' '{print $2}'))
    for ResUser in ${ResUsers[@]}
        do
            local PID=${ResUser:0:-1}
            ps ax | grep -q ${PID} && kill -9 ${PID}
        done
    popd >/dev/null
}

# Usage: UnMount [-c <RootDir>] <Directory>
UnMount() {
    local Usage="Usage: UnMount [-c <RootDir>] <Directory>"
    local Prefix=""
    local RootDir=""
    local Directory=""

    while [ $# -ne 0 ]
    do
        case $1 in
            -c|--chroot)
                RootDir=$2
                Prefix="${Prefix:+${Prefix} }chroot \"${RootDir}\""
                shift 2
                ;;
            *)
                if [ $# -ne 1 ]; then
                    echo -e ${Usage}
                    return 1
                fi
                Directory=$1
                shift
                ;;
        esac
    done

    if [ -z "${Directory}" ]; then
        echo -e ${Usage} && return 1
    fi

    if eval ${Prefix} umount --help | grep -q "recursive"; then
        if eval ${Prefix} mountpoint -q "${Directory}"; then
            printf "UMOUNT: [${C_GEN}Recursive${C_CLR}] ${C_YEL}${Directory##*${WorkDir}/}${C_CLR}"
            if ! eval ${Prefix} umount -R "${Directory}" >/dev/null 2>&1; then
                if ! eval ${Prefix} umount -Rl "${Directory}" >/dev/null 2>&1; then
                    printf " [${C_FL}]\n"
                    return 1
                fi
            fi
            printf " [${C_OK}]\n"
        fi
    else
        dirlist=$(eval ${Prefix} cat /proc/mounts | grep "${Directory}")
        [ -n "${dirlist}" ] && return 0
        for dir in ${dirlist}
        do
            if eval ${Prefix} mountpoint -q "${dir}"; then
                printf "UNMOUNT: ${C_YEL}${dir##*${WorkDir}/}${C_CLR}"
                if ! eval ${Prefix} umount "${dir}"; then
                    if ! eval ${Prefix} umount -l "${dir}"; then
                        printf " [${C_FL}]\n"
                        return 1
                    fi
                fi
                printf " [${C_OK}]\n"
            fi
        done
    fi

    return 0
}

# Usage: MountCache <RootDir> <CacheDir>
MountCache() {
    local Usage="Usage: MountCache <RootDir> <CacheDir>"
    if [ $# -ne 2 ]; then
        echo -e ${Usage}
        return 1
    fi

    local RootDir=$1
    local CacheDir=$2
    local RootAptCache=${RootDir}/var/cache/apt
    local RootAptLists=${RootDir}/var/lib/apt/lists
    local CacheAptCache=${CacheDir}/aptcache
    local CacheAptLists=${CacheDir}/aptlists

    mkdir -p ${CacheAptCache} ${CacheAptLists} ${RootAptCache} ${RootAptLists} || return 1

    Mount --bind ${CacheAptCache} ${RootAptCache} || return 1
    Mount --bind ${CacheAptLists} ${RootAptLists} || return 1

    return 0
}

# Usage: UnMountCache <RootDir>
UnMountCache() {
    "Usage: UnMountCache <RootDir>"
    if [ $# -ne 1 ]; then
        echo -e ${Usage}
        return 1
    fi

    local RootDir=$1
    local RootAptCache=${RootDir}/var/cache/apt
    local RootAptLists=${RootDir}/var/lib/apt/lists

    for dir in ${RootAptCache} ${RootAptLists}
    do
        UnMount ${dir} || return 1
    done

    return 0
}

# Usage: MountSystemEntries <RootDir>
MountSystemEntries() {
    local Usage="Usage: MountSystemEntries <RootDir>"
    if [ $# -ne 1 ]; then
        echo -e ${Usage}
        return 1
    fi

    local RootDir=$1

    mkdir -p ${RootDir}/proc ${RootDir}/sys ${RootDir}/dev ${RootDir}/run ${RootDir}/tmp || return 1

    if [ -x ${RootDir}/bin/mount ]; then
        Mount --chroot ${RootDir} --types proc proc-chroot /proc
        Mount --chroot ${RootDir} --types sysfs sysfs-chroot /sys
        Mount --chroot ${RootDir} --types devtmpfs udev-chroot /dev
        [ -d ${RootDir}/dev/pts ] || mkdir ${RootDir}/dev/pts
        Mount --chroot ${RootDir} --types devpts devpts-chroot /dev/pts
        Mount --bind /run ${RootDir}/run
        Mount --bind /tmp ${RootDir}/tmp

        # Bind rootfs of host os to chroot environment
        if which findmnt > /dev/null 2>&1; then
            mkdir -p ${RootDir}/host || return 1
            findmnt -es --real -n -t "ext2,ext3,ext4,vfat,ntfs,xfs,btrfs" | awk '{print $1}' | while read MountPoint
            do
                Mount --readonly --bind ${MountPoint} ${RootDir}/host${MountPoint%/}
            done
        fi
    else
        echo -e "MOUNT: ${C_WARN} Please unpack rootfs package first."
        return 99
    fi

    return 0
}

# Usage: UnMountSystemEntries <RootDir>
UnMountSystemEntries() {
    local Usage="Usage: MountSystemEntries <RootDir>"
    if [ $# -ne 1 ]; then
        echo -e ${Usage}
        return 1
    fi

    local RootDir=$1

    for dir in host tmp run dev/pts dev sys proc
    do
        UnMount ${RootDir}/${dir} || return 1
    done

    rm -rf ${RootDir}/host

    return 0
}

# Usage: MountUserEntries <RootDir>
MountUserEntries() {
    local Usage="Usage: MountUserEntries <RootDir>"
    if [ $# -ne 1 ]; then
        echo -e ${Usage}
        return 1
    fi

    local RootDir=$1
    local UserDir=${RootDir}/data

    for dir in home root var/log
    do
        mkdir -p ${RootDir}/${dir} ${UserDir}/${dir} || return 1
        Mount --bind ${UserDir}/${dir} ${RootDir}/${dir} || return 1
    done

    # Mount ExtraPackage to rootfs/media
    mkdir -p ${RootDir}/media/PackagesExtra ${ExtPackageDir}
    Mount --bind ${ExtPackageDir} ${RootDir}/media/PackagesExtra

    return 0
}

# Usage: UnMountUserEntries <RootDir>
UnMountUserEntries() {
    local Usage="Usage: UnMountUserEntries <RootDir>"
    if [ $# -ne 1 ]; then
        echo -e ${Usage}
        return 1
    fi

    local RootDir=$1

    # Mount ExtraPackage to rootfs/media
    UnMount ${RootDir}/media/PackagesExtra
    rm -rf ${RootDir}/media/PackagesExtra

    for dir in home root var/log
    do
        UnMount ${RootDir}/${dir} || return 1
    done

    return 0
}

# Usage: MkSquashfs <Squashfs File> <RootDir>
MkSquashfs() {
    local Usage="Usage: MkSquashfs <Squashfs File> <RootDir>"
    if [ $# -ne 2 ]; then
        echo -e ${Usage}
        return 1
    fi

    local Squashfs=$1
    local RootDir=$2

    if [ ! -d "${RootDir}" ]; then
        echo "Cannot find Rootfs dir."
        return 1
    fi

    [ -f "${Squashfs}" ] && rm -f "${Squashfs}"

    local SQUASHFSARGS=''
    SQUASHFSARGS="${SQUASHFSARGS:+${SQUASHFSARGS} }-b 1M"
    # SQUASHFSARGS="${SQUASHFSARGS:+${SQUASHFSARGS} }-comp xz"
    # SQUASHFSARGS="${SQUASHFSARGS:+${SQUASHFSARGS} }-processors 4"

    printf "MKSQUASH: ${C_HL}${RootDir##*${WorkDir}/}${C_CLR} --> ${C_BLU}${Squashfs##*${WorkDir}/}${C_CLR} ..."
    if ! mksquashfs "${RootDir}" "${Squashfs}" ${SQUASHFSARGS} >/dev/null; then
        printf " [${C_FL}]\n"
        return 1
    else
        printf " [${C_OK}]\n"
        return 0
    fi
}

# Usage: UnSquashfs <Squashfs File>
UnSquashfs() {
    local Usage="Usage: UnSquashfs <Squashfs File>"
    if [ $# -ne 1 ]; then
        echo -e ${Usage}
        return 1
    fi

    local Squashfs=$1
    local RootDir=squashfs-root

    [ -d "${RootDir}" ] && rm -rf "${RootDir}"
    
    printf "UNSQUASH: ${C_BLU}${Squashfs##*${WorkDir}/}${C_CLR} --> ${C_HL}${RootDir##*${WorkDir}/}${C_CLR} ..."
    if ! unsquashfs "${Squashfs}" >/dev/null 2>&1; then
        printf " [${C_FL}]\n"
        return 1
    else
        printf " [${C_OK}]\n"
        return 0
    fi
}

# Usage: GenFileSystemSize <FileSystem Size File> <RootDir>
GenFileSystemSize() {
    local Usage="Usage: GenFileSystemSize <FileSystem Size File> <RootDir>"
    if [ $# -ne 2 ]; then
        echo -e ${Usage}
        return 1
    fi

    local FileSystemSize=$1
    local RootDir=$2
    if [ ! -d "${RootDir}" ]; then
        echo -e "Cannot find Rootfs dir."
        return 1
    fi

    [ -f "${FileSystemSize}" ] && rm -f "${FileSystemSize}"

    printf "GENFILESYSTEMSIZE: Calcing ${C_HL}${RootDir##*${WorkDir}/}${C_CLR} Size ..."
    if ! printf $(du -sx --block-size=1 "${RootDir}" | cut -f1) > "${FileSystemSize}"; then
        printf " [${C_FL}]\n"
        return 1
    else
        printf " [${C_OK}]\n"
        return 0
    fi
}

# Usage: GenFileSystemManifest <FileSystem Manifest File> <RootDir>
GenFileSystemManifest() {
    local Usage="Usage: GenFileSystemManifest <FileSystem Manifest File> <RootDir>"
    if [ $# -ne 2 ]; then
        echo -e ${Usage}
        return 1
    fi

    local FileSystemManifest=$1
    local RootDir=$2
    if [ ! -d "${RootDir}" ]; then
        echo -e "Cannot find Rootfs dir."
        return 1
    fi

    [ -f "${FileSystemManifest}" ] && rm -f "${FileSystemManifest}"

    printf "GENFILESYSTEMMANIFEST: Generating ${C_HL}${RootDir##*${WorkDir}/}${C_CLR} Manifest ..."
    if ! chroot "${RootDir}" dpkg-query -W > "${FileSystemManifest}"; then
        printf " [${C_FL}]\n"
        return 1
    else
        printf " [${C_OK}]\n"
        return 0
    fi
}

# Usage: GenSums <Sum Type: md5 | sha256> <Live CD Root Dir>
GenSums() {
    local Usage="Usage: GenSums <Sum Type: md5 | sha256> <Live CD Root Dir>"
    if [ $# -ne 2 ]; then
        echo -e ${Usage}
        return 1
    fi

    local SumType=$1
    local LiveCDRoot=$2
    local ReturnCode=0
    local SUM_TOOL=''
    local SUM_FILE=''

    if [ -z "${LiveCDRoot}" ]; then
        echo -e "Live CD root [${LiveCDRoot}] is empty!"
        echo -e ${Usage}
        return 1
    fi

    if [ ! -d "${LiveCDRoot}" ]; then
        echo -e "Live CD root [${LiveCDRoot}] is not exist or a directory!"
        return 1
    fi

    # Push ISO Root to build
    if [ "x${LiveCDRoot}" != "x." ]; then
        pushd "${LiveCDRoot}" >/dev/null || exit $?
    fi

    local Exclude=''
    Exclude="${Exclude:+${Exclude}|}isolinux/boot.cat"
    Exclude="${Exclude:+${Exclude}|}$(basename ${RootDir})"
    for Ex in ${ISOExcludeList[@]};
    do
        Exclude="${Exclude:+${Exclude}|}${Ex}"
    done

    case $SumType in
        md5|md5sum)
            SUM_TOOL=md5sum
            SUM_FILE="${LiveCDRoot}/md5sum.txt"
            printf "GENMD5SUM: Calcing ${C_HL}$(basename $(pwd))${C_CLR} MD5 Sum ..."
        ;;
        sha256|sha256sum)
            SUM_TOOL=sha256sum
            SUM_FILE="${LiveCDRoot}/SHA256SUMS"
            printf "SHA256SUM: Calcing ${C_HL}$(basename $(pwd))${C_CLR} Sha256 Sum ..."
        ;;
        *)
        ;;
    esac

    [ -f "${SUM_FILE}" ] && rm -f "${SUM_FILE}"
    find -type f -print0 | grep -vzE "\"${Exclude}\"" | xargs -0 ${SUM_TOOL} | tee ${SUM_FILE} >/dev/null;
    if [ $? -ne 0 ]; then
        printf " [${C_FL}]\n"
        ReturnCode=1
    else
        printf " [${C_OK}]\n"
        ReturnCode=0
    fi

    if [ "x${LiveCDRoot}" != "x." ]; then
        popd >/dev/null || return $?
    fi
    return ${ReturnCode}
}

# Usage: PrepareExcludes <Backup|Restore> <ISO Root Dir> <UUID> <Exclude List>
PrepareExcludes() {
    local Usage="Usage: PrepareExcludes <Backup|Restore> <ISO Root Dir> <UUID> <Exclude List>"
    if [ $# -lt 3 ]; then
        echo -e ${Usage}
        return 1
    fi

    local Method=$1
    local ISORootDir=$2
    local UUID=$3
    local ExcludeList=($@)
    if [ ! -d ${ISORootDir} ]; then
        echo -e "ISO Root Dir [${ISORootDir}] is not exist or a directory!"
        return 1
    fi
    local ISORootDirAbs=$(cd ${ISORootDir} && pwd)
    local ISORootParentDirAbs=$(dirname ${ISORootDirAbs})
    local BackupDirAbs=${ISORootParentDirAbs}/.${UUID}

    case ${Method} in
        Backup)
            for Exclude in ${ExcludeList[@]};
            do
                find ${ISORootDirAbs} -name "${Exclude}" | while read ItemAbs;
                do
                    local ItemAbs=${ItemAbs}
                    local Item=${ItemAbs#*${ISORootDirAbs}/}
                    local ItemDirAbs=$(dirname ${ItemAbs})
                    local ItemDir=${ItemDirAbs#*${ISORootDirAbs}/}
                    local TargetDir=${BackupDirAbs}/${ItemDir}

                    # echo "Found Exclude File: ${Item}, Backup it to ${UUID}"
                    mkdir -p ${TargetDir}
                    mv -f ${ItemAbs} ${TargetDir}
                done
            done
        ;;
        Restore)
            if [ -d ${BackupDirAbs} ]; then
                for Exclude in ${ExcludeList[@]};
                do
                    find ${BackupDirAbs} -name "${Exclude}" | while read ItemAbs;
                    do
                        local ItemAbs=${ItemAbs}
                        local Item=${ItemAbs#*${BackupDirAbs}/}
                        local ItemDirAbs=$(dirname ${ItemAbs})
                        local ItemDir=${ItemDirAbs#*${BackupDirAbs}/}
                        local TargetDir=${ISORootDirAbs}/${ItemDir}
                        
                        # echo "Found Exclude File Backup: ${UUID}: ${Item}"
                        mkdir -p ${TargetDir}
                        mv -f ${ItemAbs} ${TargetDir}
                    done
                done
                rm -rf ${BackupDirAbs}
            fi
        ;;
        *)
            echo -e ${Usage}
            return 1
        ;;
    esac
}

# Usage: MakeISO <ISO File> <ISO Label> <Live CD Root>
MakeISO() {
    local Usage="Usage: MakeISO <ISO File> <ISO Label> <Live CD Root>"
    if [ $# -ne 3 ]; then
        echo -e ${Usage}
        return 1
    fi

    local ISOFile=$1
    local ISOLabel=$2
    local LiveCDRoot=$3
    local LiveCDRootAbs=$(cd ${LiveCDRoot} && pwd)
    local ISOLogFile=${ISOFile}.log
    
    if [ -z "${LiveCDRoot}" ]; then
        echo -e "Live CD root [${LiveCDRoot}] is empty!"
        echo -e ${Usage}
        return 1
    fi

    if [ ! -d "${LiveCDRoot}" ]; then
        echo -e "Live CD root [${LiveCDRoot}] is not exist or a directory!"
        return 1
    fi

    [ -f "${ISOFile}" ] && rm -f "${ISOFile}"
    [ -f "${ISOLogFile}" ] && rm -f "${ISOLogFile}"

    # Push ISO Root to build
    if [ "x${LiveCDRoot}" != "x." ]; then
        ISOFile=$(pwd)/${ISOFile}
        ISOLogFile=${ISOFile}.log
        pushd "${LiveCDRoot}" >/dev/null || exit $?
        LiveCDRoot=.
    fi

    local ISOARGS=''
    ISOARGS="${ISOARGS:+${ISOARGS} }-volid \"${ISOLabel}\""
    ISOARGS="${ISOARGS:+${ISOARGS} }-joliet"
    ISOARGS="${ISOARGS:+${ISOARGS} }-joliet-long"
    ISOARGS="${ISOARGS:+${ISOARGS} }-full-iso9660-filenames"
    ISOARGS="${ISOARGS:+${ISOARGS} }-input-charset utf-8"
    ISOARGS="${ISOARGS:+${ISOARGS} }-cache-inodes"
    ISOARGS="${ISOARGS:+${ISOARGS} }-allow-multidot"
    ISOARGS="${ISOARGS:+${ISOARGS} }-rational-rock"
    ISOARGS="${ISOARGS:+${ISOARGS} }-translation-table"
    ISOARGS="${ISOARGS:+${ISOARGS} }-udf"
    # ISOARGS="${ISOARGS:+${ISOARGS} }-allow-limited-size"
    if [ -f "${LiveCDRoot}/isolinux/isolinux.bin" ]; then
        ISOARGS="${ISOARGS:+${ISOARGS} }-no-emul-boot"
        ISOARGS="${ISOARGS:+${ISOARGS} }-boot-load-size 4"
        ISOARGS="${ISOARGS:+${ISOARGS} }-boot-info-table"
        ISOARGS="${ISOARGS:+${ISOARGS} }-eltorito-boot isolinux/isolinux.bin"
        ISOARGS="${ISOARGS:+${ISOARGS} }-eltorito-catalog isolinux/boot.cat"
    fi
    if [ -f "${LiveCDRoot}/boot/grub/efi.img" ]; then
        ISOARGS="${ISOARGS:+${ISOARGS} }-eltorito-alt-boot"
        ISOARGS="${ISOARGS:+${ISOARGS} }-no-emul-boot"
        ISOARGS="${ISOARGS:+${ISOARGS} }-efi-boot boot/grub/efi.img"
    fi
    ISOARGS="${ISOARGS:+${ISOARGS} }-no-bak"
    ISOARGS="${ISOARGS:+${ISOARGS} }-log-file ${ISOLogFile}.tmp"
    ISOARGS="${ISOARGS:+${ISOARGS} }-verbose"
    # ISOARGS="${ISOARGS:+${ISOARGS} }--quiet"

    # Backup Exclude files
    local UUID=$(GenUUID)
    PrepareExcludes Backup ${LiveCDRoot} ${UUID} "${ISOExcludeList[@]}"

    echo "ISO Build Command:" > ${ISOLogFile}
    # eval echo "genisoimage ${ISOARGS} -output \"${ISOFile}\" \"${LiveCDRoot}\" >> ${ISOLogFile}"
    # echo "" >> ${ISOLogFile}

    local ReturnCode=0
    printf "MAKEISO: ${C_HL}$(basename $(pwd))${C_CLR} --> ${C_BLU}$(basename ${ISOFile})${C_CLR} ..."
    eval "genisoimage ${ISOARGS} -output \"${ISOFile}\" \"${LiveCDRoot}\" 2>/dev/null"
    ReturnCode=$?
    cat ${ISOLogFile}.tmp >> ${ISOLogFile}
    rm -f ${ISOLogFile}.tmp
    if [ $ReturnCode -ne 0 ]; then
        printf " [${C_FL}]\n"
        cat ${ISOLogFile}
    else
        printf " [${C_OK}]\n"
    fi

    if [ -f "${LiveCDRoot}/isolinux/isolinux.bin" ]; then
        local ISOHYBRID=""
        ISOHYBRID="${ISOHYBRID:+${ISOHYBRID} }--uefi"
        ISOHYBRID="${ISOHYBRID:+${ISOHYBRID} }--partok"
        ISOHYBRID="${ISOHYBRID:+${ISOHYBRID} }--verbose"

        printf "ISOHYBRID: ${C_BLU}$(basename ${ISOFile})${C_CLR} ..."
        eval "isohybrid ${ISOHYBRID} \"${ISOFile}\"" >> ${ISOLogFile} 2>&1
        ReturnCode=$?
        if [ $ReturnCode -ne 0 ]; then
            printf " [${C_FL}]\n"
        else
            printf " [${C_OK}]\n"
        fi
    fi

    # Calc ISO MD5 Sum
    local ISOFileName=$(basename ${ISOFile})
    local ISOFileDir=$(dirname ${ISOFile})
    local ISOMD5File=${ISOFileName}.md5sum
    pushd $ISOFileDir > /dev/null
    printf "ISOMD5SUM: ${C_BLU}${ISOMD5File}${C_CLR} ..."
    eval "md5sum \"${ISOFileName}\" > \"${ISOMD5File}\"" >> ${ISOLogFile} 2>&1
    ReturnCode=$?
    if [ $ReturnCode -ne 0 ]; then
        printf " [${C_FL}]\n"
    else
        printf " [${C_OK}]\n"
    fi
    popd > /dev/null

    # Restore Exclude files
    PrepareExcludes Restore ${LiveCDRoot} ${UUID} "${ISOExcludeList[@]}"

    if pushd >/dev/null 2>&1; then
        popd >/dev/null || return $?
    fi
    return ${ReturnCode}
}

# Usage: UnpackISO <ISO File> <Target Dir>
UnpackISO() {
    local Usage="Usage: UnpackISO <ISO File> <Target Dir>"
    if [ $# -ne 2 ]; then
        echo -e ${Usage}
        return 1
    fi

    local ISOFile=$1
    local LiveCDRoot=$2
    local ISOMount=.${ISOFile%.*}

    if [ ! -f "${ISOFile}" ]; then
        echo -e "ISO file [${ISOFile}] is not exist or a directory!"
        return 1
    fi

    if [ -d "${LiveCDRoot}" ]; then
        local Size=$(du -sb "${LiveCDRoot}" | awk '{print $1}')
        if [ $Size -gt 4096 ]; then
            echo -e "Target dir [${LiveCDRoot}] is exist and not empty, please remove it manual."
            return 1
        fi
    else
        mkdir -p "${LiveCDRoot}"
    fi

    mkdir -p "${ISOMount}"

    printf "MOUNTISO: Mounting ${C_HL}${ISOFile}${C_CLR} --> ${C_BLU}${ISOMount}${C_CLR} ..."
    mount -r "${ISOFile}" "${ISOMount}"
    if [ $? -ne 0 ]; then
        printf " [${C_FL}]\n"
        return 1
    else
        printf " [${C_OK}]\n"
    fi

    printf "RSYNC: Copying files ${C_HL}${ISOMount}${C_CLR} --> ${C_BLU}${LiveCDRoot}${C_CLR} ..."
    rsync -aq --exclude='*.TBL' --exclude='*.tbl' "${ISOMount}/" "${LiveCDRoot}" > /dev/null
    if [ $? -ne 0 ]; then
        printf " [${C_FL}]\n"
    else
        printf " [${C_OK}]\n"
    fi

    printf "UMOUNTISO: UMounting ${C_HL}${ISOFile}${C_CLR} ..."
    umount "${ISOMount}"
    if [ $? -ne 0 ]; then
        printf " [${C_FL}]\n"
        return 1
    else
        printf " [${C_OK}]\n"
    fi

    rm -rf "${ISOMount}"

    printf "CHMOD: Processing permissive of the files and folders ..."
    chmod u+w -R "${LiveCDRoot}"
    if [ $? -ne 0 ]; then
        printf " [${C_FL}]\n"
        return 1
    else
        printf " [${C_OK}]\n"
        return 0
    fi
}

Usage_enUS() {
    local BASE_TARGET=$(basename ${RootDir})
    local BASE_SQUASH=$(basename ${SquashfsFile})

    echo -e "$(basename $0) <Command> [Arguments]"
    echo -e "Commands:"
    echo -e "  -v | version                                 : Show the version of the tool."
    echo -e "  -m | m | mount | mount-system-entry          : Mount system dirs to \"${BASE_TARGET}\". Used to prepare chroot system env."
    echo -e "  -u | u | umount | umount-system-entry        : Unmount virtual disk from \"${BASE_TARGET}\". Used to clear system env after exit chroot."
    echo -e "  -M | M | mkfs | mksquashfs                   : Package \"squashfs-root\" to squashfs file: \"${BASE_SQUASH}\". Need work in the same folder of squashfs file."
    echo -e "  -U | U | unfs | unsquashfs                   : Unpack \"squashfs-root\" from squashfs file: \"${BASE_SQUASH}\".Need work in the same folder of squashfs file."
    echo -e "  -S | S | filesysteminfo                      : Calc \"squashfs-root\" size and manifest, then generate or update \"filesystem.size/filesystem.manifest\" file.Need work in the same folder of squashfs file."
    echo -e "  -md5    | md5    <iso root>                  : Calc Files MD5 in ISO folder and generate or update \"md5sum.txt\" file."
    echo -e "  -sha256 | sha256 <iso root>                  : Calc Files SHA256 in ISO folder and generate or update \"SHA256SUMS\" file."
    echo -e "  -sum    | sum    <iso root>                  : Calc Files MD5 and SHA256 in ISO folder and generate or update \"md5sum.txt\" and \"SHA256SUMS\" file."
    echo -e "  -iso    | iso    <file> <label> <iso root>   : Build ISO \"file\" with \"label\" from \"iso root\"."
    echo -e "  -uniso  | uniso  <file> <target dir>         : Unpack ISO \"file\" to  \"target dir\"."
}

Usage_zhCN() {
    local BASE_TARGET=$(basename ${RootDir})
    local BASE_SQUASH=$(basename ${SquashfsFile})

    echo -e "$(basename $0) <命令> [参数]"
    echo -e "命令:"
    echo -e "  -v | version                                 : 显示工具的版本。"
    echo -e "  -m | m | mount | mount-system-entry          : 挂载系统目录到 \"${BASE_TARGET}\"。用来准备 chroot 的系统环境。"
    echo -e "  -u | u | umount | umount-system-entry        : 从 \"${BASE_TARGET}\" 卸载系统目录。用来在退出 chroot 后清理系统环境。"
    echo -e "  -M | M | mkfs | mksquashfs                   : 将 \"squashfs-root\" 文件系统打包为 squashfs 文件: \"${BASE_SQUASH}\"。需要在 squashfs 文件同级目录中操作。"
    echo -e "  -U | U | unfs | unsquashfs                   : 从 squashfs 文件: \"${BASE_SQUASH}\" 中解包 \"squashfs-root\" 文件系统。需要在 squashfs 文件同级目录中操作。"
    echo -e "  -S | S | filesysteminfo                      : 计算 \"squashfs-root\" 文件系统大小及包列表，并生成/更新 \"filesystem.size/filesystem.manifest\" 文件。需要在 squashfs 文件同级目录中操作。"
    echo -e "  -md5    | md5    <iso root>                  : 计算 ISO 目录中文件的 MD5 校验并生成/更新 \"md5sum.txt\" 文件。"
    echo -e "  -sha256 | sha256 <iso root>                  : 计算 ISO 目录中文件的 SHA256 校验并生成/更新 \"SHA256SUMS\" 文件。"
    echo -e "  -sum    | sum    <iso root>                  : 计算 ISO 目录中文件的 MD5 和 SHA256 校验并生成/更新 \"md5sum.txt\" 和 \"SHA256SUMS\" 文件。"
    echo -e "  -iso    | iso    <file> <label> <iso root>   : 从 \"iso root\" 构建标签为 \"label\" 的 ISO 文件 \"file\"。"
    echo -e "  -uniso  | uniso  <file> <target dir>         : 将 ISO 文件 \"file\" 释放到目标文件夹 \"target dir\"。"
}

Usage() {
    local LOCALE='en_US'
    if [ -z "${LC_ALL}" ]; then
        if [ -n "${LANG}" ]; then
            LOCALE=${LANG}
        elif which locale >/dev/null 2>&1; then
            LOCALE=$(locale | awk -F '=' '/^LANG=/ {print $2}')
        fi
    fi

    if [ "x${LOCALE%%.*}" = "xzh_CN" ]; then
        Usage_zhCN
    else
        Usage_enUS
    fi
}

if [ $# -eq 0 ]; then
    Usage
    exit 1
fi

CheckBuildEnvironment || exit $?

while [ $# -ne 0 ]
do
    case $1 in
        -m|m|mount|mount-system-entry)
            shift
            CheckPrivilege || exit $?
            MountSystemEntries "${RootDir}" || exit $?
            ;;
        -u|u|umount|umount-system-entry)
            shift
            CheckPrivilege || exit $?
            ReleaseRes "${RootDir}" || exit $?
            UnMountSystemEntries "${RootDir}" || exit $?
            ;;
        -M|M|mkfs|mksquashfs)
            shift
            CheckPrivilege || exit $?
            MkSquashfs "${SquashfsFile}" "${RootDir}" || exit $?
            ;;
        -U|U|unfs|unsquashfs)
            shift
            CheckPrivilege || exit $?
            UnSquashfs "${SquashfsFile}" || exit $?
            ;;
        -S|S|filesysteminfo)
            shift
            GenFileSystemSize "${FileSystemSize}" "${RootDir}" || exit $?
            GenFileSystemManifest "${FileSystemManifest}" "${RootDir}" || exit $?
            ;;
        -md5|md5|md5sum)
            shift
            LiveCDRoot=$1
            shift
            GenSums md5 "${LiveCDRoot}" || exit $?
            ;;
        -sha256|sha256|sha256sum)
            shift
            LiveCDRoot=$1
            shift
            GenSums sha256 "${LiveCDRoot}" || exit $?
            ;;
        -sum|sum)
            shift
            LiveCDRoot=$1
            shift
            GenSums md5 "${LiveCDRoot}" || exit $?
            GenSums sha256 "${LiveCDRoot}" || exit $?
            ;;
        -iso|iso)
            shift
            ISOFile=$1
            ISOLabel=$2
            LiveCDRoot=$3
            shift 3
            MakeISO "${ISOFile}" "${ISOLabel}" "${LiveCDRoot}" || exit $?
            ;;
        -uniso|uniso)
            shift
            ISOFile=$1
            LiveCDRoot=$2
            shift 2
            UnpackISO "${ISOFile}" "${LiveCDRoot}" || exit $?
            ;;
        -v|v|-version|version)
            shift
            echo -e "$(basename $0) Version: ${Version}"
            exit 0
            ;;
        *)
            Usage
            exit 1
            ;;
    esac
done
