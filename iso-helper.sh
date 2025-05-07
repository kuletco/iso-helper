#!/bin/bash
# shellcheck disable=SC2034

# @Author: Wang Hong
# @Date:   2022-10-22 12:38:37
# @Last Modified by:   Wang Hong
# @Last Modified time: 2024-09-03 10:19:43

# set -e

Version=1.6.0

ExecDir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WorkDir=$(pwd)
LiveCDRoot=${WorkDir}
RootDir=${WorkDir}/squashfs-root
SquashfsFile=${WorkDir}/filesystem.squashfs
FileSystemSize=${WorkDir}/filesystem.size
FileSystemManifest=${WorkDir}/filesystem.manifest

ISOExcludeList=(
    squashfs-root
    squashfs-root.bk
    squashfs-root.bak
    squashfs-root.back
    squashfs-root.backup
    squashfs-root.old
    filesystem.squashfs.bk
    filesystem.squashfs.bak
    filesystem.squashfs.back
    filesystem.squashfs.backup
    filesystem.squashfs.old
    initrd.file
    initrd.dir
    initrd.tmp
    initrd.lz.bk
    initrd.lz.bak
    initrd.lz.back
    initrd.lz.backup
    initrd.lz.old
    initrd.img.bk
    initrd.img.bak
    initrd.img.back
    initrd.img.backup
    initrd.img.old
)

SystemProfiles=(
    /etc/hosts
    /etc/resolv.conf
)
SysFileBackSuff="sys_backup"
SysFileAppliedSuff="sys_applied"

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
C_WARN="${C_Y}WARNING${C_CLR}"
C_ERROR="${C_R}ERROR${C_CLR}"

# Cmd Hook Methods:
# hook_mkdir() {
#     echo "$@"
#     /usr/bin/mkdir "$@"
# }
# alias mkdir='hook_mkdir'

# Usage: Caller <Prefix> <Desc> <Cmd>
Caller() {
    Usage="Caller <Prefix> <Desc> <Cmd>"
    if [ $# -lt 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
        echo "${Usage}"
        return 1
    fi

    local Prefix=$1
    local Desc=$2
    shift 2
    local Cmd=$*
    local ReturnCode=0
    local LogFile=/tmp/.caller.log

    echo -en "${C_HB}${Prefix}${C_CLR}: ${Desc}"
    if eval "${Cmd}" > "${LogFile}" 2>&1; then
        ReturnCode=$?
        echo -e "[${C_OK}]"
    else
        ReturnCode=$?
        echo -e "[${C_FL}]"
        cat "${LogFile}"
    fi
    rm -f "${LogFile}"
    return ${ReturnCode}
}

CheckPrivilege() {
    if [ ${UID} -ne 0 ]; then
        echo -e "Please run this script with ${C_HY}root${C_CLR} privileges."
        return 1
    else
        return 0
    fi
}

CheckQemuBinfmtSupport() {
    if ! ls "/usr/share/binfmts/qemu-*" > /dev/null 2>&1; then
        echo -e "Please install [${C_R}qemu-user${C_CLR} or ${C_R}qemu-user-static${C_CLR}] first"
        return 1
    fi
}

CheckBuildEnvironment() {
    Utils=(fuseiso fusermount blkid lsblk losetup parted mkfs.ext4 mkfs.fat mksquashfs findmnt)

    for Util in "${Utils[@]}"; do
        if ! which "${Util}" >/dev/null 2>&1; then
            echo -e "Please install [${C_R}${Util}${C_CLR}] first"
            return 1
        fi
    done

    # CheckQemuBinfmtSupport

    return 0
}

GenUUID() {
    local UUID=4c0efd70-04f4-45c4-88f3-fa943249da15
    if which uuid >/dev/null 2>&1; then
        UUID=$(uuid)
    else
        UUID=$(cat /proc/sys/kernel/random/uuid)
    fi
    [ -n "${UUID}" ] || UUID=4c0efd70-04f4-45c4-88f3-fa943249da15
    echo "${UUID}"
}

# Usage: IsTargetMounted <Target>
IsTargetMounted() {
    local Usage="Usage: IsTargetMounted <Target>"
    if [ $# -ne 1 ] || [ -z "$1" ]; then
        echo -e "${Usage}"
        return 1
    fi

    local Target=$1

    if [ -d "${Target}" ]; then
        mountpoint -q "${Target}"
    elif [ -f "${Target}" ] || [ -L "${Target}" ]; then
        /bin/grep -q "${Target}" "/proc/mounts"
    else
        return 1
    fi
}

# Usage: GetTargetMountPoint <Target>
GetTargetMountPoint() {
    local Usage="Usage: GetTargetMountPoint <Target>"
    if [ $# -ne 1 ] || [ -z "$1" ]; then
        echo -e "${Usage}"
        return 1
    fi

    local Target=$1
    local MountedDir

    if [ -e "${Target}" ]; then
        echo "Target:[${Target}] Not Exist!"
        return 1
    fi

    IsTargetMounted "${Target}" || return 1
    if ! MountedDir=$(lsblk -n -o MOUNTPOINT "${Target}"); then
        return 1
    fi
    [ -n "${MountedDir}" ] || return 1

    echo "${MountedDir}"
}

# Usage: Mount [-c <RootDir>] [-t <Type> | -b] <Source> <Target>
Mount() {
    local Usage="Usage: Mount [-c <RootDir>] [-t <Type> | -b] <Source> <Target>"
    local Prefix=""
    local Options=""
    local RootDir=""

    while [ $# -ne 0 ]; do
        case $1 in
            -c|--chroot)
                RootDir=$2
                Prefix="${Prefix:+${Prefix} }chroot ${RootDir}"
                shift 2
                ;;
            -t|--types)
                local Type=$2
                Options="${Options:+${Options} }--types ${Type}"
                shift 2
                ;;
            -b|--bind)
                Options="${Options:+${Options} }--bind"
                shift
                ;;
            -r|-ro|--readonly)
                Options="${Options:+${Options} }--options ro"
                shift
                ;;
            *)
                if [ $# -ne 2 ]; then
                    echo -e "${Usage}"
                    return 1
                fi
                local Source=$1
                local Target=$2
                shift 2
                ;;
        esac
    done

    if [ -z "${Source}" ] || [ -z "${Target}" ]; then
        echo -e "${Usage}"
        return 1
    fi

    if eval "${Prefix}" mountpoint -q "${Target}"; then
        return 0
    fi

    # When ${Target} dir is a symbolic link and point to ${Source} dir, skip this mount.
    if [ -L "${Target}" ] && [ "$(realpath "${Target}")" = "${Source}" ]; then
        return 0
    fi

    local Desc Cmd
    Desc="${Options:+[${C_G}${Options}${C_CLR}] }${C_Y}${Source##*${WorkDir}/}${C_CLR} --> ${C_B}${Target##*${WorkDir}/}${C_CLR} ... "
    Cmd="${Prefix} mount ${Options} \"${Source}\" \"${Target}\""
    Caller "MOUNT" "${Desc}" "${Cmd}"
}

# Usage: ReleaseRes <RootDir>
ReleaseRes() {
    local Usage="Usage: ReleaseRes <RootDir>"
    if [ $# -ne 1 ] || [ -z "$1" ]; then
        echo -e "${Usage}"
        return 1
    fi

    local RootDir=$1
    local ResUsers

    # Stop All Process first!!! TODO: Test Code!
    pushd "${RootDir}/.." > /dev/null || exit $?
    read -ra ResUsers <<< "$(fuser -a "$(basename "${RootDir}")" 2>/dev/null | grep "$(basename "${RootDir}")" | awk -F':' '{print $2}')"
    for ResUser in "${ResUsers[@]}"; do
        local PID=${ResUser:0:-1}
        pgrep "${PID}" > /dev/null && kill -9 "${PID}"
    done
    popd >/dev/null || exit $?
}

# Usage: UnMount [-c <RootDir>] <Directory>
UnMount() {
    local Usage="Usage: UnMount [-c <RootDir>] <Directory>"
    local Prefix=""
    local RootDir=""
    local Directory=""

    while [ $# -ne 0 ]; do
        case $1 in
            -c|--chroot)
                RootDir=$2
                Prefix="${Prefix:+${Prefix} }chroot \"${RootDir}\""
                shift 2
                ;;
            *)
                if [ $# -ne 1 ]; then
                    echo -e "${Usage}"
                    return 1
                fi
                Directory=$1
                shift
                ;;
        esac
    done

    if [ -z "${Directory}" ]; then
        echo -e "${Usage}"
        return 1
    fi

    local Desc Cmd
    if eval "${Prefix}" umount --help | grep -iq "recursive"; then
        if eval "${Prefix}" mountpoint -q "${Directory}"; then
            Desc="[${C_G}Recursive${C_CLR}] ${C_Y}${Directory##*${WorkDir}/}${C_CLR} ... "
            Cmd="${Prefix} umount -R \"${Directory}\""
            if ! Caller "UMOUNT" "${Desc}" "${Cmd}"; then
                Desc="[${C_Y}Retry${C_CLR}] ${Desc}"
                Cmd="${Prefix} umount -Rl \"${Directory}\""
                Caller "UMOUNT" "${Desc}" "${Cmd}"
            fi
        fi
    else
        dirlist=$(eval "${Prefix}" cat /proc/mounts | grep "${Directory}")
        [ -n "${dirlist}" ] && return 0
        for dir in ${dirlist}; do
            if eval "${Prefix}" mountpoint -q "${dir}"; then
                Desc="${C_Y}${dir##*${WorkDir}/}${C_CLR} ... "
                Cmd="${Prefix} umount \"${dir}\""
                if ! Caller "UMOUNT" "${Desc}" "${Cmd}"; then
                    Desc="[${C_Y}Retry${C_CLR}] ${Desc}"
                    Cmd="${Prefix} umount -l \"${Directory}\""
                    Caller "UMOUNT" "${Desc}" "${Cmd}"
                fi
            fi
        done
    fi

    return 0
}

# Usage: MountCache <RootDir> <CacheDir>
MountCache() {
    local Usage="Usage: MountCache <RootDir> <CacheDir>"
    if [ $# -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
        echo -e "${Usage}"
        return 1
    fi

    local RootDir=$1
    local CacheDir=$2
    local RootAptCache=${RootDir}/var/cache/apt
    local RootAptLists=${RootDir}/var/lib/apt/lists
    local CacheAptCache=${CacheDir}/aptcache
    local CacheAptLists=${CacheDir}/aptlists

    mkdir -p "${CacheAptCache}" "${CacheAptLists}" "${RootAptCache}" "${RootAptLists}" || return 1

    Mount --bind "${CacheAptCache}" "${RootAptCache}" || return 1
    Mount --bind "${CacheAptLists}" "${RootAptLists}" || return 1

    return 0
}

# Usage: UnMountCache <RootDir>
UnMountCache() {
    local Usage="Usage: UnMountCache <RootDir>"
    if [ $# -ne 1 ] || [ -z "$1" ]; then
        echo -e "${Usage}"
        return 1
    fi

    local RootDir=$1
    local RootAptCache=${RootDir}/var/cache/apt
    local RootAptLists=${RootDir}/var/lib/apt/lists

    for dir in ${RootAptCache} ${RootAptLists}; do
        UnMount "${dir}" || return 1
    done

    return 0
}

# Usage: ApplySystemSettings <RootDir>
ApplySystemSettings() {
    local Usage="Usage: ApplySystemSettings <RootDir>"
    if [ $# -ne 1 ] || [ -z "$1" ]; then
        echo -e "${Usage}"
        return 1
    fi

    local RootDir=$1

    for Profile in "${SystemProfiles[@]}"; do
        local Desc Cmd
        if [ -e "${RootDir}${Profile}.${SysFileBackSuff}" ]; then
            Desc="Backup File [${C_B}${RootDir##*${WorkDir}/}${Profile}.${SysFileBackSuff}${C_CLR}] exist ..."
            Cmd=false
            Caller "APPLY" "${Desc}" "${Cmd}"
        elif [ -e "${RootDir}${Profile}" ]; then
            Desc="${C_Y}${Profile}${C_CLR} --> ${C_B}${RootDir##*${WorkDir}/}${Profile}${C_CLR} ... "
            Cmd="mv \"${RootDir}${Profile}\" \"${RootDir}${Profile}.${SysFileBackSuff}\" && cp -a \"${Profile}\" \"${RootDir}${Profile}\""
            Caller "APPLY" "${Desc}" "${Cmd}" || continue
            touch "${RootDir}${Profile}.${SysFileAppliedSuff}"
        fi
    done
}

# Usage: RestoreSystemSettings <RootDir>
RestoreSystemSettings() {
    local Usage="Usage: RestoreSystemSettings <RootDir>"
    if [ $# -ne 1 ] || [ -z "$1" ]; then
        echo -e "${Usage}"
        return 1
    fi

    local RootDir=$1

    for Profile in "${SystemProfiles[@]}"; do
        if [ -e "${RootDir}${Profile}.${SysFileBackSuff}" ] && [ -f "${RootDir}${Profile}.${SysFileAppliedSuff}" ]; then
            local Desc Cmd
            Desc="${C_B}${RootDir##*${WorkDir}/}${Profile}${C_CLR} ... "
            Cmd="rm -f \"${RootDir}${Profile}\"; mv \"${RootDir}${Profile}.${SysFileBackSuff}\" \"${RootDir}${Profile}\""
            Caller "RESTORE" "${Desc}" "${Cmd}"
        fi
    done
}

# Usage: MountSystemEntries <RootDir>
MountSystemEntries() {
    local Usage="Usage: MountSystemEntries <RootDir>"
    if [ $# -ne 1 ] || [ -z "$1" ]; then
        echo -e "${Usage}"
        return 1
    fi

    local RootDir=$1

    mkdir -p "${RootDir}/proc" "${RootDir}/sys" "${RootDir}/dev" "${RootDir}/run" "${RootDir}/tmp" || return 1

    if [ -x "${RootDir}/bin/mount" ]; then
        Mount --chroot "${RootDir}" --types proc proc-chroot "/proc"
        Mount --chroot "${RootDir}" --types sysfs sysfs-chroot "/sys"
        Mount --chroot "${RootDir}" --types devtmpfs udev-chroot "/dev"
        [ -d "${RootDir}/dev/pts" ] || mkdir -p "${RootDir}/dev/pts"
        Mount --chroot "${RootDir}" --types devpts devpts-chroot "/dev/pts"
        Mount --bind /run "${RootDir}/run"
        Mount --bind /tmp "${RootDir}/tmp"

        # Bind rootfs of host os to chroot environment
        if which findmnt > /dev/null 2>&1; then
            mkdir -p "${RootDir}/host" || return 1
            findmnt -es --real -n -t "ext2,ext3,ext4,vfat,ntfs,xfs,btrfs" | awk '{print $1}' | while read -r MountPoint; do
                # Skip unused folder binding: /boot;/boot/efi;/var;/backup;
                (echo "${MountPoint}" | grep -q -E "\/boot|\/boot\/efi|\/var|\/backup") && continue
                mkdir -p "${RootDir}/host${MountPoint%/}"
                Mount --readonly --bind "${MountPoint}" "${RootDir}/host${MountPoint%/}"
            done
        fi
    else
        echo -e "MOUNT: ${C_WARN} Please unpack rootfs package first."
        return 99
    fi

    ApplySystemSettings "${RootDir}"

    return 0
}

# Usage: UnMountSystemEntries <RootDir>
UnMountSystemEntries() {
    local Usage="Usage: UnMountSystemEntries <RootDir>"
    if [ $# -ne 1 ] || [ -z "$1" ]; then
        echo -e "${Usage}"
        return 1
    fi

    local RootDir=$1

    for dir in sys dev/pts dev proc; do
        UnMount --chroot "${RootDir}" "/${dir}" || return 1
    done

    for dir in host tmp run; do
        UnMount "${RootDir}/${dir}" || return 1
    done

    rm -rf "${RootDir}/host"

    RestoreSystemSettings "${RootDir}"

    return 0
}

# Usage: MountUserEntries <RootDir> <ExtPackageDir>
MountUserEntries() {
    local Usage="Usage: MountUserEntries <RootDir> <ExtPackageDir>"
    if [ $# -ne 1 ] || [ -z "$1" ]; then
        echo -e "${Usage}"
        return 1
    fi

    local RootDir=$1
    local ExtPackageDir=$2
    local UserDir=${RootDir}/data

    for dir in home root var/log; do
        mkdir -p "${RootDir}/${dir}" "${UserDir}/${dir}" || return 1
        Mount --bind "${UserDir}/${dir}" "${RootDir}/${dir}" || return 1
    done

    # Mount ExtraPackage to rootfs/media
    mkdir -p "${RootDir}/media/PackagesExtra" "${ExtPackageDir}"
    Mount --bind "${ExtPackageDir}" "${RootDir}/media/PackagesExtra"

    return 0
}

# Usage: UnMountUserEntries <RootDir>
UnMountUserEntries() {
    local Usage="Usage: UnMountUserEntries <RootDir>"
    if [ $# -ne 1 ] || [ -z "$1" ]; then
        echo -e "${Usage}"
        return 1
    fi

    local RootDir=$1

    # Mount ExtraPackage to rootfs/media
    UnMount "${RootDir}/media/PackagesExtra"
    rm -rf "${RootDir}/media/PackagesExtra"

    for dir in home root var/log; do
        UnMount "${RootDir}/${dir}" || return 1
    done

    return 0
}

# Usage: MkSquashfs <Squashfs File> <RootDir>
MkSquashfs() {
    local Usage="Usage: MkSquashfs <Squashfs File> <RootDir>"
    if [ $# -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
        echo -e "${Usage}"
        return 1
    fi

    local Squashfs=$1
    local RootDir=$2

    if [ ! -d "${RootDir}" ]; then
        echo "Cannot find Rootfs dir."
        return 1
    fi

    local SQUASHFSARGS=''
    SQUASHFSARGS="${SQUASHFSARGS:+${SQUASHFSARGS} }-b 1M"
    # SQUASHFSARGS="${SQUASHFSARGS:+${SQUASHFSARGS} }-comp xz"
    # SQUASHFSARGS="${SQUASHFSARGS:+${SQUASHFSARGS} }-processors 4"

    local Desc Cmd
    if [ -d "${RootDir}" ]; then
        Desc="Removing exist squashfs file [${C_H}${Squashfs##*${WorkDir}/}${C_CLR}] ... "
        Cmd="rm -f \"${Squashfs}\""
        Caller "REMOVE" "${Desc}" "${Cmd}"
    fi
    Desc="${C_B}${RootDir##*${WorkDir}/}${C_CLR} --> ${C_H}${Squashfs##*${WorkDir}/}${C_CLR} ... "
    Cmd="mksquashfs \"${RootDir}\" \"${Squashfs}\" ${SQUASHFSARGS}"
    Caller "MKSQUASH" "${Desc}" "${Cmd}"
}

# Usage: UnSquashfs <Squashfs File>
UnSquashfs() {
    local Usage="Usage: UnSquashfs <Squashfs File>"
    if [ $# -ne 1 ] || [ -z "$1" ]; then
        echo -e "${Usage}"
        return 1
    fi

    local Squashfs=$1
    local RootDir=squashfs-root

    local Desc Cmd
    if [ -d "${RootDir}" ]; then
        Desc="Removing exist RootDir [${C_B}${RootDir##*${WorkDir}/}${C_CLR}] ... "
        Cmd="rm -rf \"${RootDir}\""
        Caller "REMOVE" "${Desc}" "${Cmd}"
    fi
    Desc="${C_H}${Squashfs##*${WorkDir}/}${C_CLR} --> ${C_B}${RootDir##*${WorkDir}/}${C_CLR} ... "
    Cmd="unsquashfs \"${Squashfs}\""
    Caller "UNSQUASH" "${Desc}" "${Cmd}"
}

# Usage: GenFileSystemSize <FileSystem Size File> <RootDir>
GenFileSystemSize() {
    local Usage="Usage: GenFileSystemSize <FileSystem Size File> <RootDir>"
    if [ $# -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
        echo -e "${Usage}"
        return 1
    fi

    local FileSystemSize=$1
    local RootDir=$2
    if [ ! -d "${RootDir}" ]; then
        echo -e "Cannot find Rootfs dir."
        return 1
    fi

    [ -f "${FileSystemSize}" ] && rm -f "${FileSystemSize}"

    local Desc Cmd
    Desc="Calculating ${C_B}${RootDir##*${WorkDir}/}${C_CLR} Size ... "
    Cmd="du -sx --block-size=1 \"${RootDir}\" | cut -f1 > \"${FileSystemSize}\""
    Caller "GEN SIZE" "${Desc}" "${Cmd}"
}

# Usage: GenFileSystemManifest <FileSystem Manifest File> <RootDir>
GenFileSystemManifest() {
    local Usage="Usage: GenFileSystemManifest <FileSystem Manifest File> <RootDir>"
    if [ $# -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
        echo -e "${Usage}"
        return 1
    fi

    local FileSystemManifest=$1
    local RootDir=$2
    if [ ! -d "${RootDir}" ]; then
        echo -e "Cannot find Rootfs dir."
        return 1
    fi

    [ -f "${FileSystemManifest}" ] && rm -f "${FileSystemManifest}"

    local Desc Cmd
    Desc="Calculating ${C_B}${RootDir##*${WorkDir}/}${C_CLR} Manifest ... "
    Cmd="chroot \"${RootDir}\" dpkg-query -W > \"${FileSystemManifest}\""
    Caller "GEN MANIFEST" "${Desc}" "${Cmd}"
}

# Usage: GenSums <Sum Type: md5 | sha256> <Live CD Root Dir>
GenSums() {
    local Usage="Usage: GenSums <Sum Type: md5 | sha256> <Live CD Root Dir>"
    if [ $# -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
        echo -e "${Usage}"
        return 1
    fi

    local SumType=$1
    local LiveCDRoot=$2
    local ReturnCode=0
    local SUM_TOOL=''
    local SUM_FILE=''

    if [ -z "${LiveCDRoot}" ]; then
        echo -e "Live CD root [${LiveCDRoot}] is empty!"
        echo -e "${Usage}"
        return 1
    fi

    if [ ! -d "${LiveCDRoot}" ]; then
        echo -e "Live CD root [${LiveCDRoot}] is not exist or a directory!"
        return 1
    fi

    # Push ISO Root to build
    pushd "${LiveCDRoot}" >/dev/null || exit $?

    local Exclude=''
    Exclude="${Exclude:+${Exclude}|}isolinux/boot.cat"
    Exclude="${Exclude:+${Exclude}|}$(basename "${RootDir}")"
    for Ex in "${ISOExcludeList[@]}"; do
        Exclude="${Exclude:+${Exclude}|}${Ex}"
    done

    local Desc Cmd
    case $SumType in
        md5|md5sum)
            SUM_TYPE_STR="MD5SUM"
            SUM_TOOL=md5sum
            SUM_FILE="md5sum.txt"
            ;;
        sha256|sha256sum)
            SUM_TYPE_STR="SHA256SUM"
            SUM_TOOL=sha256sum
            SUM_FILE="SHA256SUMS"
            ;;
        *)
            ;;
    esac

    [ -f "${SUM_FILE}" ] && rm -f "${SUM_FILE}"

    Desc="Calculating ${C_B}$(basename "$(pwd)")${C_CLR} ${SUM_TYPE_STR} ... "
    Cmd="find . -type f -print0 | grep -vzE "\"${Exclude}\"" | xargs -0 \"${SUM_TOOL}\" | tee \"${SUM_FILE}\""
    if ! Caller "GEN ${SUM_TYPE_STR}" "${Desc}" "${Cmd}"; then
        ReturnCode=1
    fi

    popd >/dev/null || return $?

    return ${ReturnCode}
}

# Usage: PrepareExcludes <Backup|Restore> <ISO Root Dir> <UUID> <Exclude List>
PrepareExcludes() {
    local Usage="Usage: PrepareExcludes <Backup|Restore> <ISO Root Dir> <UUID> <Exclude List>"
    if [ $# -lt 3 ] || [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
        echo -e "${Usage}"
        return 1
    fi

    local Method=$1
    local ISORootDir=$2
    local UUID=$3
    local ExcludeList
    read -ra ExcludeList <<< "$@"
    if [ ! -d "${ISORootDir}" ]; then
        echo -e "ISO Root Dir [${ISORootDir}] is not exist or a directory!"
        return 1
    fi
    local ISORootDirAbs
    local ISORootParentDirAbs
    local BackupDirAbs
    ISORootDirAbs=$(cd "${ISORootDir}" && pwd)
    ISORootParentDirAbs=$(dirname "${ISORootDirAbs}")
    BackupDirAbs=${ISORootParentDirAbs}/.${UUID}

    local ItemAbs Item ItemDirAbs ItemDir TargetDir
    case ${Method} in
        Backup)
            for Exclude in "${ExcludeList[@]}"; do
                find "${ISORootDirAbs}" -name "${Exclude}" | while read -r ItemAbs; do
                    Item=${ItemAbs#*"${ISORootDirAbs}"/}
                    ItemDirAbs=$(dirname "${ItemAbs}")
                    ItemDir=${ItemDirAbs#*"${ISORootDirAbs}"/}
                    TargetDir=${BackupDirAbs}/${ItemDir}

                    echo -e "Found Exclude File: [${C_B}${Item}${C_CLR}], Backup it to [${C_HY}${UUID}${C_CLR}]"
                    mkdir -p "${TargetDir}"
                    mv -f "${ItemAbs}" "${TargetDir}"
                done
            done
            ;;
        Restore)
            if [ -d "${BackupDirAbs}" ]; then
                for Exclude in "${ExcludeList[@]}"; do
                    find "${BackupDirAbs}" -name "${Exclude}" | while read -r ItemAbs; do
                        Item=${ItemAbs#*"${BackupDirAbs}"/}
                        ItemDirAbs=$(dirname "${ItemAbs}")
                        ItemDir=${ItemDirAbs#*"${BackupDirAbs}"/}
                        TargetDir=${ISORootDirAbs}/${ItemDir}
                        
                        echo -e "Found Exclude File Backup: [${C_HY}${UUID}${C_CLR}]: [${C_B}${Item}${C_CLR}]"
                        mkdir -p "${TargetDir}"
                        mv -f "${ItemAbs}" "${TargetDir}"
                    done
                done
                rm -rf "${BackupDirAbs}"
            fi
            ;;
        *)
            echo -e "${Usage}"
            return 1
            ;;
    esac
}

# Usage: GetDebFileInfo <Section Title> <Live CD Root>
function GetDebFileInfo() {
    local Usage="Usage: GetDebFileInfo <Section Title> <Live CD Root>"
    if [ $# -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
        echo -e "${Usage}"
        return 1
    fi

    local SectionTitle=$1
    local LiveCDRoot=$2

    echo "##### ${SectionTitle} #####"
    if [ -d "${LiveCDRoot}" ]; then
        find "${LiveCDRoot}" -type f -name "*.deb" | while read -r line; do
            echo "##### ${SectionTitle}.$(basename "${line}") #####"
            dpkg-deb --info "${line}" | grep -E "Package:|Version:|Architecture:|Description:"
        done
    fi
}

# Usage: GenerateISOInfo <ISO File>
function GenerateISOInfo() {
    local Usage="Usage: GenerateISOInfo <ISO File>"
    if [ $# -ne 1 ] || [ -z "$1" ]; then
        echo -e "${Usage}"
        return 1
    fi

    local ISOFile=$1
    local ISOBaseName=${ISOFile%.iso}
    local ISOInfoFile=${ISOBaseName}.info
    local ISOMountDir=${ISOBaseName}
    local FSMountDir=${ISOBaseName}.filesystem.squashfs
    local User
    if [ -n "${SUDO_USER}" ]; then
        User=${SUDO_USER}
    else
        User=${USER}
    fi

    rm -f "${ISOInfoFile}"

    if [ -f "${ISOFile}" ]; then
        echo "##### ${ISOFile} #####" >> "${ISOInfoFile}"

        if test -d "${FSMountDir}"; then
            mountpoint -q "${FSMountDir}" && umount "${FSMountDir}"
        fi
        if test -d "${ISOMountDir}"; then
            mountpoint -q "${ISOMountDir}" && umount "${ISOMountDir}"
        fi

        mkdir -p "${ISOMountDir}" "${FSMountDir}"
        mount -o loop,ro "${ISOFile}" "${ISOMountDir}"
        mount "${ISOMountDir}/casper/filesystem.squashfs" "${FSMountDir}"

        {
            echo "##### cdrom.casper.filesystem.manifest #####"
            cat "${ISOMountDir}/casper/filesystem.manifest"
            
            echo "##### cdrom.casper.filesystem.manifest-remove #####"
            cat "${ISOMountDir}/casper/filesystem.manifest-remove"

            GetDebFileInfo "cdrom.casper.filesystem.squashfs.opt.third" "${FSMountDir}/opt/third"
            GetDebFileInfo "cdrom.casper.filesystem.squashfs.opt.kscset" "${FSMountDir}/opt/kscset"
            GetDebFileInfo "cdrom.third-party" "${ISOMountDir}/third-party"
            GetDebFileInfo "cdrom.citrix" "${ISOMountDir}/citrix"
            GetDebFileInfo "cdrom.sdm" "${ISOMountDir}/sdm"
            GetDebFileInfo "cdrom.ecp" "${ISOMountDir}/ecp"
            GetDebFileInfo "cdrom.ecp" "${ISOMountDir}/ECIP_ALL_1101"
            GetDebFileInfo "cdrom.mail" "${ISOMountDir}/mail"
            GetDebFileInfo "cdrom.rhtx" "${ISOMountDir}/rhtx"
            GetDebFileInfo "cdrom.sogou" "${ISOMountDir}/sogou"
            GetDebFileInfo "cdrom.kernel" "${ISOMountDir}/kernel"

            echo "##### cdrom.kylin-post-actions #####"
            cat "${ISOMountDir}/.kylin-post-actions"
        } | sed -e "s/${ISOMountDir}\//iso\//g" -e "s/${ISOMountDir}\./iso\./g" >> "${ISOInfoFile}"

        umount "${FSMountDir}"
        umount "${ISOMountDir}"
        rm -rf "${ISOMountDir}" "${FSMountDir}"

        chown "${User}":"${User}" "${ISOInfoFile}"
    fi
}

# Usage: MakeISO <ISO File> <ISO Label> <Live CD Root>
MakeISO() {
    local Usage="Usage: MakeISO <ISO File> <ISO Label> <Live CD Root>"
    if [ $# -ne 3 ] || [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
        echo -e "${Usage}"
        return 1
    fi

    local ISOFile=$1
    local ISOLabel=$2
    local LiveCDRoot=$3
    local ISOLogFile=${ISOFile}.log
    local ReturnCode=0
    local User
    if [ -n "${SUDO_USER}" ]; then
        User=${SUDO_USER}
    else
        User=${USER}
    fi
    
    if [ -z "${LiveCDRoot}" ]; then
        echo -e "Live CD root [${LiveCDRoot}] is empty!"
        echo -e "${Usage}"
        return 1
    fi

    if [ ! -d "${LiveCDRoot}" ]; then
        echo -e "Live CD root [${LiveCDRoot}] is not exist or a directory!"
        return 1
    fi

    # Push ISO Root to build
    if [ "${LiveCDRoot}" != "." ]; then
        ISOFile=$(pwd)/${ISOFile}
        ISOLogFile=${ISOFile}.log
        pushd "${LiveCDRoot}" >/dev/null || exit $?
        LiveCDRoot=.
    fi

    local ISOARGS=''
    # ISOARGS="${ISOARGS:+${ISOARGS} }-check-oldnames"
    ISOARGS="${ISOARGS:+${ISOARGS} }-sysid 'LINUX'"
    ISOARGS="${ISOARGS:+${ISOARGS} }-volid \"${ISOLabel}\""
    ISOARGS="${ISOARGS:+${ISOARGS} }-joliet"
    ISOARGS="${ISOARGS:+${ISOARGS} }-joliet-long"
    ISOARGS="${ISOARGS:+${ISOARGS} }-full-iso9660-filenames"
    # ISOARGS="${ISOARGS:+${ISOARGS} }-max-iso9660-filenames"
    ISOARGS="${ISOARGS:+${ISOARGS} }-untranslated-filenames"
    # ISOARGS="${ISOARGS:+${ISOARGS} }-no-iso-translate"
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
    # ISOARGS="${ISOARGS:+${ISOARGS} }-no-bak"
    ISOARGS="${ISOARGS:+${ISOARGS} }-log-file ${ISOLogFile}.tmp"
    # ISOARGS="${ISOARGS:+${ISOARGS} }-quiet"
    ISOARGS="${ISOARGS:+${ISOARGS} }-verbose"
    # ISOARGS="${ISOARGS:+${ISOARGS} }-debug"

    # Backup Exclude files
    local UUID
    UUID=$(GenUUID)
    PrepareExcludes Backup "${LiveCDRoot}" "${UUID}" "${ISOExcludeList[@]}"

    echo "ISO Build Command:" > "${ISOLogFile}"
    # eval echo "genisoimage ${ISOARGS} -output \"${ISOFile}\" \"${LiveCDRoot}\" >> ${ISOLogFile}"
    # echo "" >> "${ISOLogFile}"

    local Desc Cmd
    if [ -f "${ISOFile}" ]; then
        Desc="Removing exist ISO file [${C_B}$(basename "${ISOFile}")${C_CLR}] ... "
        Cmd="rm -f \"${ISOFile}\""
        Caller "REMOVE" "${Desc}" "${Cmd}"
    fi
    if [ -f "${ISOLogFile}" ]; then
        Desc="Removing exist ISO log file [${C_B}$(basename "${ISOLogFile}")${C_CLR}] ... "
        Cmd="rm -f \"${ISOLogFile}\""
        Caller "REMOVE" "${Desc}" "${Cmd}"
    fi
    Desc="${C_B}$(basename "$(pwd)")${C_CLR} --> ${C_H}$(basename "${ISOFile}")${C_CLR} ... "
    Cmd="genisoimage ${ISOARGS} -output \"${ISOFile}\" \"${LiveCDRoot}\"; cat \"${ISOLogFile}.tmp\" >> \"${ISOLogFile}\"; rm -f \"${ISOLogFile}.tmp\""
    if ! Caller "MAKEISO" "${Desc}" "${Cmd}"; then
        ReturnCode=1
        cat "${ISOLogFile}"
    fi

    if which isohybrid > /dev/null && [ -f "${LiveCDRoot}/isolinux/isolinux.bin" ]; then
        local ISOHYBRID=""
        ISOHYBRID="${ISOHYBRID:+${ISOHYBRID} }--uefi"
        ISOHYBRID="${ISOHYBRID:+${ISOHYBRID} }--partok"
        ISOHYBRID="${ISOHYBRID:+${ISOHYBRID} }--verbose"

        Desc="${C_B}$(basename "${ISOFile}")${C_CLR} ... "
        Cmd="isohybrid ${ISOHYBRID} \"${ISOFile}\""
        if ! Caller "ISOHYBRID" "${Desc}" "${Cmd}"; then
            ReturnCode=1
        fi
    fi
    chown "${User}":"${User}" "${ISOFile}"

    # Calc ISO Sum
    local ISOFileName ISOFileDir ISOSumFile
    ISOFileName=$(basename "${ISOFile}")
    ISOFileDir=$(dirname "${ISOFile}")

    pushd "${ISOFileDir}" > /dev/null || exit $?

    ISOSumFile=${ISOFileName}.md5sum
    Desc="Calculating ${C_H}${ISOFileName}${C_CLR} MD5SUM ... "
    Cmd="md5sum \"${ISOFileName}\" > \"${ISOSumFile}\""
    if ! Caller "GEN ISO MD5SUM" "${Desc}" "${Cmd}"; then
        ReturnCode=1
    fi
    chown "${User}":"${User}" "${ISOSumFile}"

    ISOSumFile=${ISOFileName}.sha256sum
    Desc="Calculating ${C_H}${ISOFileName}${C_CLR} SHA256SUM ... "
    Cmd="sha256sum \"${ISOFileName}\" > \"${ISOSumFile}\""
    if ! Caller "GEN ISO SHA256SUM" "${Desc}" "${Cmd}"; then
        ReturnCode=1
    fi
    chown "${User}":"${User}" "${ISOSumFile}"

    popd > /dev/null || exit $?

    # Restore Exclude files
    PrepareExcludes Restore "${LiveCDRoot}" "${UUID}" "${ISOExcludeList[@]}"

    if pushd >/dev/null 2>&1; then
        popd >/dev/null || return $?
    fi
    return ${ReturnCode}
}

# Usage: UnpackISO <ISO File> <Target Dir>
UnpackISO() {
    local Usage="Usage: UnpackISO <ISO File> <Target Dir>"
    if [ $# -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
        echo -e "${Usage}"
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
        local Size
        Size=$(du -sb "${LiveCDRoot}" | awk '{print $1}')
        if [ "${Size}" -gt 4096 ]; then
            echo -e "Target dir [${C_B}${LiveCDRoot}${C_CLR}] is exist and not empty, please remove it manual."
            return 1
        fi
    else
        mkdir -p "${LiveCDRoot}"
    fi

    mkdir -p "${ISOMount}"

    local Desc Cmd
    Desc="${C_H}${ISOFile}${C_CLR} --> ${C_Y}${ISOMount}${C_CLR} ... "
    Cmd="fuseiso \"${ISOFile}\" \"${ISOMount}\""
    if ! Caller "MOUNTISO" "${Desc}" "${Cmd}"; then
        return $?
    fi

    Desc="Copying files ${C_Y}${ISOMount}${C_CLR} --> ${C_B}${LiveCDRoot}${C_CLR} ... "
    Cmd="rsync -aq --exclude='*.TBL' --exclude='*.tbl' \"${ISOMount}/\" \"${LiveCDRoot}\""
    if ! Caller "RSYNC" "${Desc}" "${Cmd}"; then
        return $?
    fi

    Desc="${C_Y}${ISOMount}${C_CLR} ... "
    Cmd="fusermount -u \"${ISOMount}\""
    if ! Caller "UMOUNTISO" "${Desc}" "${Cmd}"; then
        return $?
    fi

    rm -rf "${ISOMount}"

    Desc="Processing permissive of the files and folders [${C_B}${LiveCDRoot}${C_CLR}] ... "
    Cmd="chmod u+w -R \"${LiveCDRoot}\""
    if ! Caller "CHMOD" "${Desc}" "${Cmd}"; then
        return $?
    fi
}

Usage_enUS() {
    local BASE_TARGET BASE_SQUASH
    BASE_TARGET=$(basename "${RootDir}")
    BASE_SQUASH=$(basename "${SquashfsFile}")

    echo -e "$(basename "$0") <Command> [Arguments]"
    echo -e "Commands:"
    echo -e "  -v | version                                 : Show the version of the tool."
    echo -e "  -m | mount                                   : Prepare chroot env. Mount system dirs to \"${BASE_TARGET}\"."
    echo -e "  -u | umount                                  : Clear chroot env. Unmount system dirs from \"${BASE_TARGET}\"."
    echo -e "  -M | mkfs                                    : Build image file \"${BASE_SQUASH}\"] from \"${BASE_TARGET}\". Need work in the same folder of \"${BASE_SQUASH}\" file."
    echo -e "  -U | unfs                                    : Extract \"${BASE_TARGET}\" from image file \"${BASE_SQUASH}\".Need work in the same folder of \"${BASE_SQUASH}\" file."
    echo -e "  -i | fsinfo                                  : Update \"filesystem.size/filesystem.manifest\" for \"${BASE_TARGET}\". Need work in the same folder of \"${BASE_SQUASH}\" file."
    echo -e "  -md5    <iso root>                           : Update or generate \"md5sum.txt\" in ISO root folder."
    echo -e "  -sha256 <iso root>                           : Update or generate \"SHA256SUMS\" in ISO root folder."
    echo -e "  -sum    <iso root>                           : The same as -md5 -sha256."
    echo -e "  -iso    <file> <label> <iso root>            : Build ISO \"file\" with \"label\" from \"ISO root folder\"."
    echo -e "  -uniso  <file> <target dir>                  : Extract files to \"ISO dir\" in ISO file \"file\"."
    echo -e "  -info   <file>                               : Generate ISO Info to \"<file>.info\"."
}

Usage_zhCN() {
    local BASE_TARGET BASE_SQUASH
    BASE_TARGET=$(basename "${RootDir}")
    BASE_SQUASH=$(basename "${SquashfsFile}")

    echo -e "$(basename "$0") <命令> [参数]"
    echo -e "命令:"
    echo -e "  -v | version                                 : 显示工具的版本。"
    echo -e "  -m | mount                                   : 准备 chroot 环境。将系统目录挂载到 \"${BASE_TARGET}\"。"
    echo -e "  -u | umount                                  : 清理 chroot 环境。从 \"${BASE_TARGET}\" 卸载系统目录。"
    echo -e "  -M | mkfs                                    : 从 \"${BASE_TARGET}\" 目录制作镜像文件 \"${BASE_SQUASH}\"。需要在 \"${BASE_SQUASH}\" 文件同级目录中操作。"
    echo -e "  -U | unfs                                    : 将 \"${BASE_SQUASH}\" 文件解包至 \"${BASE_TARGET}\"。需要在 \"${BASE_SQUASH}\" 文件同级目录中操作。"
    echo -e "  -i | fsinfo                                  : 从 \"${BASE_TARGET}\" 更新/生成 \"filesystem.size/filesystem.manifest\" 文件。需要在 \"${BASE_SQUASH}\" 文件同级目录中操作。"
    echo -e "  -md5    <iso root>                           : 更新/生成 ISO 根目录中 \"md5sum.txt\" 文件。"
    echo -e "  -sha256 <iso root>                           : 更新/生成 ISO 根目录中 \"SHA256SUMS\" 文件。"
    echo -e "  -sum    <iso root>                           : 等同于 -md5 -sha256。"
    echo -e "  -iso    <file> <label> <iso root>            : 从 \"iso root\" 构建标签为 \"label\" 的 ISO 文件 \"file\"。"
    echo -e "  -uniso  <file> <target dir>                  : 将 ISO 文件 \"file\" 释放到目标文件夹 \"target dir\"。"
    echo -e "  -info   <file>                               : 生成 ISO 信息文件 \"<file>.info\"."
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

    if [ "${LOCALE%%.*}" = "zh_CN" ]; then
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

while [ $# -ne 0 ]; do
    case $1 in
        -m|m|mount)
            shift 1
            CheckPrivilege || exit $?
            MountSystemEntries "${RootDir}" || exit $?
            ;;
        -u|u|umount)
            shift 1
            CheckPrivilege || exit $?
            ReleaseRes "${RootDir}" || exit $?
            UnMountSystemEntries "${RootDir}" || exit $?
            ;;
        -M|M|mkfs)
            shift 1
            CheckPrivilege || exit $?
            MkSquashfs "${SquashfsFile}" "${RootDir}" || exit $?
            ;;
        -U|U|unfs)
            shift 1
            CheckPrivilege || exit $?
            UnSquashfs "${SquashfsFile}" || exit $?
            ;;
        -i|i|fsinfo)
            shift 1
            GenFileSystemSize "${FileSystemSize}" "${RootDir}" || exit $?
            GenFileSystemManifest "${FileSystemManifest}" "${RootDir}" || exit $?
            ;;
        -md5|md5|md5sum)
            shift 1
            LiveCDRoot=$1
            shift 1
            GenSums md5 "${LiveCDRoot}" || exit $?
            ;;
        -sha256|sha256|sha256sum)
            shift 1
            LiveCDRoot=$1
            shift 1
            GenSums sha256 "${LiveCDRoot}" || exit $?
            ;;
        -sum|sum)
            shift 1
            LiveCDRoot=$1
            shift 1
            GenSums md5 "${LiveCDRoot}" || exit $?
            GenSums sha256 "${LiveCDRoot}" || exit $?
            ;;
        -iso|iso)
            shift 1
            ISOFile=$1
            ISOLabel=$2
            LiveCDRoot=$3
            shift 3
            MakeISO "${ISOFile}" "${ISOLabel}" "${LiveCDRoot}" || exit $?
            ;;
        -uniso|uniso)
            shift 1
            ISOFile=$1
            LiveCDRoot=$2
            shift 2
            UnpackISO "${ISOFile}" "${LiveCDRoot}" || exit $?
            ;;
        -info|info)
            shift 1
            ISOFile=$1
            shift 1
            GenerateISOInfo "${ISOFile}" || exit $?
            ;;
        -v|v|-version|version)
            shift 1
            echo -e "$(basename "$0") Version: ${Version}"
            exit 0
            ;;
        *)
            Usage
            exit 1
            ;;
    esac
done
