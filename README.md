# iso-helper 帮助文件

iso-helper 是用来辅助进行 kylin-desktop-v10-sp1 进行 iso 定制的工具。



### **其主要功能如下：**

* 释放/打包 live 系统的镜像文件（filesystem.squashfs）。

* 生成/更新 live 系统大小文件（filesystem.size）。

* 生成/更新 live 系统包列表（filesystem.manifest）。

* 生成/更新 iso 根目录中的 md5 校验文件（md5sum.txt）。

* 生成/更新 iso 根目录中的 sha256 校验文件（SHA256SUMS）。

* 制作 iso 镜像。

* 生成 iso 镜像的 md5 校验文件（xxxx.iso.md5sum）。

* 生成 iso 镜像的 sha256 校验文件（xxxx.iso.sha256sum）。

* 准备 chroot 环境，

* 自动为 chroot 环境挂载必备的内存文件系统（procfs、devtmpfs、sysfs、tmpfs等）

* 并将主机根目录以只读方式挂载到 chroot 环境的 /host 目录中，方便进行文件的操作。

* 清理 chroot 环境，主要是对第 7 点进行反向操作（卸载已挂载的文件系统）。

* 生成 iso 信息文件，包括镜像内软件包+版本的列表，及一些定制内容。



### **使用方法如下：**

**内置帮助：**

```shell
iso-helper.sh <命令> [参数]
命令:
  -v | version                                 : 显示工具的版本。
  -m | m | mount | mount-system-entry          : 准备 chroot 环境。将系统目录挂载到 "squashfs-root"。
  -u | u | umount | umount-system-entry        : 清理 chroot 环境。从 "squashfs-root" 卸载系统目录。
  -M | M | mkfs | mksquashfs                   : 从 "squashfs-root" 目录制作镜像文件 "filesystem.squashfs"。需要在 "filesystem.squashfs" 文件同级目录中操作。
  -U | U | unfs | unsquashfs                   : 将 "filesystem.squashfs" 文件解包至 "squashfs-root"。需要在 "filesystem.squashfs" 文件同级目录中操作。
  -S | S | filesysteminfo                      : 从 "squashfs-root" 更新/生成 "filesystem.size/filesystem.manifest" 文件。需要在 "filesystem.squashfs" 文件同级目录中操作。
  -md5     | md5    <iso root>                 : 更新/生成 ISO 根目录中 "md5sum.txt" 文件。
  -sha256  | sha256 <iso root>                 : 更新/生成 ISO 根目录中 "SHA256SUMS" 文件。
  -sum     | sum    <iso root>                 : 等同于 -md5 -sha256。
  -iso     | iso    <file> <label> <iso root>  : 从 "iso root" 构建标签为 "label" 的 ISO 文件 "file"。
  -uniso   | uniso  <file> <target dir>        : 将 ISO 文件 "file" 释放到目标文件夹 "target dir"。
  -info    | info  <file>                      : 生成 ISO 信息文件 "<file>.info".
```



**简单用例：**

```shell
# 解包 ISO 文件，将 iso 镜像文件 Kylin-Desktop-V10-SP1.iso 释放到 v10sp1 目录
$ iso-helper.sh -uniso Kylin-Desktop-V10-SP1.iso v10sp1

# 将 v10sp1 目录打包为 iso 镜像文件 Kylin-Desktop-V10-SP1.iso，标签为 Kylin-Desktop-V10-SP1
$ iso-helper.sh -iso Kylin-Desktop-V10-SP1.iso "Kylin-Desktop-V10-SP1" v10sp1

# 解包 filesystem.squashfs 文件
$ cd v10sp1/casper
$ iso-helper.sh -U

# 打包 filesystem.squashfs 文件
$ cd v10sp1/casper
$ iso-helper.sh -M

# 根据修改后的 filesystem.squashfs 文件更新 filesystem.size 和 filesystem.manifest
$ cd v10sp1/casper
$ iso-helper.sh -S

# 准备 chroot 环境，为定制 filesystem.squashfs 文件做准备，随后进行 chroot
$ cd v10sp1/casper
$ iso-helper.sh -m
$ chroot squashfs-root /bin/bash

# 退出 chroot 环境后，清理定制的文件系统 squashfs-root
$ iso-helper.sh -u
```



**定制镜像一般流程**

1. 解包 ISO 文件
2. 解包 filesystem.squash
3. 准备 chroot 环境
4. chroot
5. 一系列定制，比如安装软件等
6. 退出 chroot
7. 清理 chroot 环境
8. 打包 filesystem.squashfs
9. 更新包列表及文件系统大小
10. 更新 ISO 根目录中的 md5 和 sha256 文件
11. 打包 ISO 文件

