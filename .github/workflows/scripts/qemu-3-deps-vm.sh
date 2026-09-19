#!/usr/bin/env bash

######################################################################
# 3) install dependencies for compiling and loading
#
# qemu-3-deps-vm.sh [--poweroff] OS_NAME [FEDORA_VERSION]
#
# --poweroff: Power off the VM after installing dependencies
# OS_NAME: OS name (like 'fedora41')
# FEDORA_VERSION: (optional) Experimental Fedora kernel version, like "6.14" to
#     install instead of Fedora defaults.
######################################################################

set -eu

function alpine() {
  echo "##[group]Install Development Tools"
  sudo apk add \
    acl alpine-sdk attr autoconf automake bash build-base clang22 coreutils \
    cpio cryptsetup curl curl-dev dhcpcd diffutils eudev eudev-dev eudev-libs \
    findutils fio gawk gdb gettext-dev git grep jq libaio libaio-dev \
    libcap-utils libcurl libtirpc-dev libtool libunwind libunwind-dev \
    linux-headers linux-tools linux-stable linux-stable-dev lsscsi m4 make \
    nfs-utils openssl-dev parted pax procps py3-cffi py3-distlib py3-packaging \
    py3-setuptools python3 python3-dev qemu-guest-agent rng-tools rsync samba \
    samba-server sed strace sysstat tzdata util-linux util-linux-dev wget \
    words xfsprogs xxhash zlib-dev pamtester@testing
  echo "##[endgroup]"

  # Build objtool with and without the AT_MINSIGSTKSZ fix and run both
  # of them.  This is the end-to-end check that the LD_PRELOAD shim only
  # stands in for: where the kernel's floor exceeds musl's SIGSTKSZ the
  # unpatched binary has to abort and the patched one has to run.  On a
  # host below that floor both run and the result says nothing either
  # way, so print AT_MINSIGSTKSZ alongside to show which case this is.
  echo "##[group]objtool on this host"
  grep -m1 '^model name' /proc/cpuinfo || true
  sudo apk add elfutils-dev

  cat > /tmp/atmin.c <<'ATMIN'
#include <signal.h>
#include <stdio.h>
#include <sys/auxv.h>
#ifndef AT_MINSIGSTKSZ
#define AT_MINSIGSTKSZ	51
#endif
int main(void)
{
	unsigned long a = getauxval(AT_MINSIGSTKSZ);
	printf("%lu\n", a);
	return a > (unsigned long)SIGSTKSZ ? 0 : 1;
}
ATMIN
  cc -o /tmp/atmin /tmp/atmin.c
  atmin=$(/tmp/atmin) && amx=yes || amx=no
  echo "AT_MINSIGSTKSZ = $atmin, musl SIGSTKSZ = 8192"
  echo "above musl's SIGSTKSZ: $amx (if no, this host proves nothing)"

  git clone --depth 1 --filter=blob:none --sparse --no-checkout \
    https://github.com/torvalds/linux /tmp/linux
  git -C /tmp/linux sparse-checkout set tools/objtool tools/lib \
    tools/include tools/arch tools/build tools/scripts scripts \
    arch/x86/include arch/x86/lib include/linux
  git -C /tmp/linux checkout

  make -C /tmp/linux/tools/objtool
  cp /tmp/linux/tools/objtool/objtool /tmp/objtool-unpatched

  python3 - <<'FIX'
p = "/tmp/linux/tools/objtool/signal.c"
s = open(p).read()

subs = [
("#include <sys/resource.h>\n",
 "#include <sys/resource.h>\n#include <sys/auxv.h>\n"),

("#include <objtool/warn.h>\n\n",
 "#include <objtool/warn.h>\n\n"
 "#ifndef AT_MINSIGSTKSZ\n#define AT_MINSIGSTKSZ\t51\n#endif\n\n"),

("\tint signals[] = {SIGSEGV, SIGBUS, SIGILL, SIGABRT};\n"
 "\tstruct sigaction sa;\n\tstack_t ss;\n",
 "\tint signals[] = {SIGSEGV, SIGBUS, SIGILL, SIGABRT};\n"
 "\tstruct sigaction sa;\n\tlong stack_size;\n\tstack_t ss;\n"),

("\tss.ss_sp = malloc(SIGSTKSZ);\n",
 "\t/*\n"
 "\t * SIGSTKSZ is a compile-time constant here, and can be smaller\n"
 "\t * than the signal frame on the running CPU.  AT_MINSIGSTKSZ is\n"
 "\t * the kernel's own figure for that frame; spend SIGSTKSZ on top\n"
 "\t * of it for the handler that runs there, as\n"
 "\t * tools/testing/selftests/signal/sas.c does.  The auxv entry is\n"
 "\t * absent before v5.14, where getauxval() returns 0 and this is\n"
 "\t * SIGSTKSZ.\n"
 "\t */\n"
 "\tstack_size = getauxval(AT_MINSIGSTKSZ) + SIGSTKSZ;\n\n"
 "\tss.ss_sp = malloc(stack_size);\n"),

("\tss.ss_size = SIGSTKSZ;\n", "\tss.ss_size = stack_size;\n"),
]

for old, repl in subs:
    if s.count(old) != 1:
        raise SystemExit("signal.c has moved: %d matches for %r"
                         % (s.count(old), old[:40]))
    s = s.replace(old, repl)

open(p, "w").write(s)
print("patched signal.c")
FIX
  make -C /tmp/linux/tools/objtool
  cp /tmp/linux/tools/objtool/objtool /tmp/objtool-patched

  # A real object file to chew on, so this exercises more than --help.
  obj=$(find /usr/src /lib/modules -name '*.o' 2>/dev/null | head -1)

  # The discriminator is objtool's own message, not the exit status:
  # "check" on an arbitrary object can fail for unrelated reasons, but
  # only a refused sigaltstack() stops it before it does any work.
  for bin in /tmp/objtool-unpatched /tmp/objtool-patched; do
    echo "--- $bin ---"
    out=$("$bin" --help 2>&1 || true)
    if echo "$out" | grep -q "sigaltstack failed"; then
      echo "RESULT: aborted at sigaltstack"
    else
      echo "RESULT: started up"
    fi
    echo "$out" | head -3
    if [ -n "$obj" ]; then
      echo "check $obj:"
      "$bin" check "$obj" 2>&1 | head -3 || true
    fi
  done
  echo "##[endgroup]"

  echo "##[group]Switch to eudev"
  sudo setup-devd udev
  echo "##[endgroup]"

  echo "##[group]Boot the -stable kernel instead of -virt"
  # -virt has CONFIG_SCSI_DEBUG disabled, which several ZTS tests
  # (zpool_expand, zpool_reopen, fault/auto_*, ...) need to simulate
  # disks that support expand/fault-injection scenarios real static
  # disks can't easily provide.  -stable has it enabled.  This takes
  # effect on the VM's next boot, which happens naturally when this
  # deps step powers off and qemu-prepare-for-build.sh starts the VM
  # back up for the build step -- no explicit reboot needed here.
  sudo sed -i 's/^default=virt$/default=stable/' /etc/update-extlinux.conf
  sudo update-extlinux
  echo "##[endgroup]"

  echo "##[group]Install ksh93 from Source"
  # Build the actively-maintained "1.0" branch instead of the
  # default "dev" branch for a reproducible, stable build.
  git clone --depth 1 --branch 1.0 https://github.com/ksh93/ksh.git /tmp/ksh
  cd /tmp/ksh
  ./bin/package make
  sudo ./bin/package install /
  echo "##[endgroup]"
}

function archlinux() {
  echo "##[group]Running pacman -Syu"
  sudo btrfs filesystem resize max /
  sudo pacman -Syu --noconfirm
  echo "##[endgroup]"

  echo "##[group]Install Development Tools"
  sudo pacman -Sy --noconfirm base-devel bc cpio cryptsetup dhclient dkms \
    fakeroot fio gdb inetutils jq less linux linux-headers lsscsi nfs-utils \
    parted pax perf python-packaging python-setuptools qemu-guest-agent ksh \
    samba strace sysstat rng-tools rsync wget xxhash
  echo "##[endgroup]"
}

function debian() {
  export DEBIAN_FRONTEND="noninteractive"

  echo "##[group]Wait for cloud-init to finish"
  cloud-init status --wait
  echo "##[endgroup]"

  echo "##[group]Running apt-get update+upgrade"
  sudo sed -i '/[[:alpha:]]-backports/d' /etc/apt/sources.list
  sudo apt-get update -y
  sudo apt-get upgrade -y
  echo "##[endgroup]"

  echo "##[group]Install Development Tools"
  sudo apt-get install -y \
    acl alien attr autoconf bc cpio cryptsetup curl dbench dh-python dkms \
    fakeroot fio gdb gdebi git ksh lcov isc-dhcp-client jq libacl1-dev \
    libaio-dev libattr1-dev libblkid-dev libcurl4-openssl-dev libdevmapper-dev \
    libelf-dev libffi-dev libmount-dev libpam0g-dev libselinux-dev libssl-dev \
    libtool libtool-bin libudev-dev libunwind-dev linux-headers-$(uname -r) \
    lsscsi nfs-kernel-server pamtester parted python3 python3-all-dev \
    python3-cffi python3-dev python3-distlib python3-packaging libtirpc-dev \
    python3-setuptools python3-sphinx qemu-guest-agent rng-tools rpm2cpio \
    rsync samba strace sysstat uuid-dev watchdog wget xfslibs-dev xxhash \
    zlib1g-dev
  echo "##[endgroup]"
}

function freebsd() {
  export ASSUME_ALWAYS_YES="YES"

  echo "##[group]Install Development Tools"
  sudo pkg install -y autoconf automake autotools base64 checkbashisms fio \
    gdb gettext gettext-runtime git gmake gsed jq ksh lcov libtool lscpu \
    pkgconf python python3 pamtester pamtester qemu-guest-agent rsync xxhash
  sudo pkg install -xy \
    '^samba4[[:digit:]]+$' \
    '^py3[[:digit:]]+-cffi$' \
    '^py3[[:digit:]]+-sysctl$' \
    '^py3[[:digit:]]+-setuptools$' \
    '^py3[[:digit:]]+-packaging$'
  echo "##[endgroup]"
}

# common packages for: almalinux, centos, redhat
function rhel() {
  echo "##[group]Running dnf update"
  echo "max_parallel_downloads=10" | sudo -E tee -a /etc/dnf/dnf.conf
  sudo dnf clean all
  sudo dnf update -y --setopt=fastestmirror=1 --refresh
  echo "##[endgroup]"

  echo "##[group]Install Development Tools"

  # Alma wants "Development Tools", Fedora 41 wants "development-tools"
  if ! sudo dnf group install -y "Development Tools" ; then
    echo "Trying 'development-tools' instead of 'Development Tools'"
    sudo dnf group install -y development-tools
  fi

  sudo dnf install -y \
    acl attr bc bzip2 cryptsetup curl dbench dkms elfutils-libelf-devel fio \
    gdb git jq kernel-rpm-macros ksh libacl-devel libaio-devel \
    libargon2-devel libattr-devel libblkid-devel libcurl-devel libffi-devel \
    ncompress libselinux-devel libtirpc-devel libtool libudev-devel \
    libuuid-devel lsscsi mdadm nfs-utils openssl-devel pam-devel pamtester \
    parted perf python3 python3-cffi python3-devel python3-packaging \
    kernel-devel python3-setuptools qemu-guest-agent rng-tools rpcgen \
    rpm-build rsync samba strace sysstat systemd watchdog wget xfsprogs-devel \
    xxhash zlib-devel

  # These are needed for building Lustre.  We only install these on EL VMs since
  # we don't plan to test build Lustre on other platforms.
  sudo dnf install -y libnl3-devel libyaml-devel libmount-devel

  echo "##[endgroup]"
}

function tumbleweed() {
  echo "##[group]Running zypper is TODO!"
  sleep 23456
  echo "##[endgroup]"
}

# $1: Kernel version to install (like '6.14rc7')
function install_fedora_experimental_kernel {

  our_version="$1"
  sudo dnf -y copr enable @kernel-vanilla/stable
  sudo dnf -y copr enable @kernel-vanilla/mainline
  all="$(sudo dnf list --showduplicates kernel-* python3-perf* perf* bpftool*)"
  echo "Available versions:"
  echo "$all"

  # You can have a bunch of minor variants of the version we want '6.14'.
  # Pick the newest variant (sorted by version number).
  specific_version=$(echo "$all" | grep $our_version | awk '{print $2}' | sort -V | tail -n 1)
  list="$(echo "$all" | grep $specific_version | grep -Ev 'kernel-rt|kernel-selftests|kernel-debuginfo' | sed 's/.x86_64//g' | awk '{print $1"-"$2}')"
  sudo dnf install -y $list
  sudo dnf -y copr disable @kernel-vanilla/stable
  sudo dnf -y copr disable @kernel-vanilla/mainline
}

POWEROFF=""
if [ "$1" == "--poweroff" ] ; then
        POWEROFF=1
        shift
fi

# Install dependencies
case "$1" in
  almalinux8)
    echo "##[group]Enable epel and powertools repositories"
    sudo dnf config-manager -y --set-enabled powertools
    sudo dnf install -y epel-release
    echo "##[endgroup]"
    rhel
    echo "##[group]Install kernel-abi-whitelists"
    sudo dnf install -y kernel-abi-whitelists
    echo "##[endgroup]"
    ;;
  almalinux9|almalinux10|centos-stream9|centos-stream10)
    echo "##[group]Enable epel and crb repositories"
    sudo dnf config-manager -y --set-enabled crb
    sudo dnf install -y epel-release
    echo "##[endgroup]"
    rhel
    echo "##[group]Install kernel-abi-stablelists"
    sudo dnf install -y kernel-abi-stablelists
    echo "##[endgroup]"
    ;;
  alpine*)
    alpine
    ;;
  archlinux)
    archlinux
    ;;
  debian*)
    echo 'debconf debconf/frontend select Noninteractive' | sudo debconf-set-selections
    debian
    echo "##[group]Install Debian specific"
    sudo apt-get install -yq linux-perf dh-sequence-dkms
    echo "##[endgroup]"
    ;;
  fedora*)
    rhel
    sudo dnf install -y libunwind-devel

    # Fedora 42+ moves /usr/bin/script from 'util-linux' to 'util-linux-script'
    sudo dnf install -y util-linux-script || true

    # Optional: Install an experimental kernel ($2 = kernel version)
    if [ -n "${2:-}" ] ; then
      install_fedora_experimental_kernel "$2"
    fi
    ;;
  freebsd*)
    freebsd
    ;;
  tumbleweed)
    tumbleweed
    ;;
  ubuntu22|ubuntu24)
    debian
    echo "##[group]Install Ubuntu specific"
    sudo apt-get install -yq linux-tools-common libtirpc-dev \
      linux-modules-extra-$(uname -r)
    sudo apt-get install -yq dh-sequence-dkms

    # Need 'build-essential' explicitly for ARM builder
    # https://github.com/actions/runner-images/issues/9946
    sudo apt-get install -yq build-essential

    echo "##[endgroup]"
    echo "##[group]Delete Ubuntu OpenZFS modules"
    for i in $(find /lib/modules -name zfs -type d); do sudo rm -rvf $i; done
    echo "##[endgroup]"
    ;;
  ubuntu26)
    debian
    echo "##[group]Install Ubuntu specific"
    # Skip linux-modules-extra which is already installed
    sudo apt-get install -yq linux-tools-common
    sudo apt-get install -yq libtirpc-dev
    sudo apt-get install -yq dh-sequence-dkms

    # Need 'build-essential' explicitly for ARM builder
    # https://github.com/actions/runner-images/issues/9946
    sudo apt-get install -yq build-essential

    # Replace sudo-rs with sudo for now because the Rust version
    # does not support -E to preserve the entire environment
    sudo update-alternatives --set sudo /usr/bin/sudo.ws

    echo "##[endgroup]"
    echo "##[group]Delete Ubuntu OpenZFS modules"
    for i in $(find /lib/modules -name zfs -type d); do sudo rm -rvf $i; done
    echo "##[endgroup]"
    ;;
esac

# This script is used for checkstyle + zloop deps also.
# Install only the needed packages and exit - when used this way.
test -z "${ONLY_DEPS:-}" || exit 0

# Start services
echo "##[group]Enable services"
case "$1" in
  alpine*)
    sudo -E rc-update add qemu-guest-agent
    sudo -E rc-update add nfs
    sudo -E rc-update add samba
    sudo -E rc-update add dhcpcd
    # Remove services related to cloud-init.
    sudo -E rc-update del cloud-init-local boot
    sudo -E rc-update del cloud-init default
    sudo -E rc-update del cloud-final default
    sudo -E rc-update del cloud-config default
    ;;
  freebsd*)
    # add virtio things
    echo 'virtio_load="YES"' | sudo -E tee -a /boot/loader.conf
    for i in balloon blk console random scsi; do
      echo "virtio_${i}_load=\"YES\"" | sudo -E tee -a /boot/loader.conf
    done
    echo "fdescfs /dev/fd fdescfs rw 0 0" | sudo -E tee -a /etc/fstab
    sudo -E mount /dev/fd
    sudo -E touch /etc/zfs/exports
    sudo -E sysrc mountd_flags="/etc/zfs/exports"
    echo '[global]' | sudo -E tee /usr/local/etc/smb4.conf >/dev/null
    sudo -E service nfsd enable
    sudo -E service qemu-guest-agent enable
    sudo -E service samba_server enable
    ;;
  debian*|ubuntu*)
    sudo -E systemctl enable nfs-kernel-server
    sudo -E systemctl enable smbd

    # enable usershares (disabled by default on ubuntu 26.04)
    sudo -E sed -i '/usershare max shares/s/^#//' /etc/samba/smb.conf

    # add systemd drop-in to allow the service to be enabled
    sudo -E mkdir -p /etc/systemd/system/qemu-guest-agent.service.d/
    sudo -E tee /etc/systemd/system/qemu-guest-agent.service.d/override.conf <<EOF
[Install]
WantedBy=multi-user.target
EOF
    sudo -E systemctl daemon-reload
    sudo -E systemctl enable qemu-guest-agent
    ;;
  *)
    # All other linux distros
    sudo -E systemctl enable nfs-server
    sudo -E systemctl enable qemu-guest-agent
    sudo -E systemctl enable smb
    ;;
esac
echo "##[endgroup]"

# Setup Kernel cmdline
CMDLINE="console=tty0 console=ttyS0,115200n8"
CMDLINE="$CMDLINE selinux=0"
CMDLINE="$CMDLINE random.trust_cpu=on"
CMDLINE="$CMDLINE no_timer_check"
case "$1" in
  almalinux*|centos*|fedora*)
    GRUB_CFG="/boot/grub2/grub.cfg"
    GRUB_MKCONFIG="grub2-mkconfig"
    CMDLINE="$CMDLINE biosdevname=0 net.ifnames=0"
    echo 'GRUB_SERIAL_COMMAND="serial --speed=115200"' \
      | sudo tee -a /etc/default/grub >/dev/null
    # Force GRUB itself onto the serial console.  These VMs have no display,
    # and without this grub2-mkconfig can emit 'terminal_output gfxterm',
    # which leaves GRUB stuck before the kernel starts on a headless VM.
    sudo sed -i -e '/^GRUB_TERMINAL_INPUT/d' -e '/^GRUB_TERMINAL_OUTPUT/d' /etc/default/grub
    echo 'GRUB_TERMINAL_INPUT="serial console"' | sudo tee -a /etc/default/grub >/dev/null
    echo 'GRUB_TERMINAL_OUTPUT="serial console"' | sudo tee -a /etc/default/grub >/dev/null
    ;;
  ubuntu24|ubuntu26)
    GRUB_CFG="/boot/grub/grub.cfg"
    GRUB_MKCONFIG="grub-mkconfig"
    echo 'GRUB_DISABLE_OS_PROBER="false"' \
      | sudo tee -a /etc/default/grub >/dev/null
    ;;
  *)
    GRUB_CFG="/boot/grub/grub.cfg"
    GRUB_MKCONFIG="grub-mkconfig"
    ;;
esac

case "$1" in
  alpine*|archlinux|freebsd*)
    true
    ;;
  *)
    echo "##[group]Edit kernel cmdline"
    sudo sed -i -e '/^GRUB_CMDLINE_LINUX/d' /etc/default/grub || true
    echo "GRUB_CMDLINE_LINUX=\"$CMDLINE\"" \
      | sudo tee -a /etc/default/grub >/dev/null
    sudo $GRUB_MKCONFIG -o $GRUB_CFG
    echo "##[endgroup]"
    ;;
esac

# reset cloud-init configuration and poweroff
sudo cloud-init clean --logs
if [ "$POWEROFF" == "1" ] ; then
        sleep 2 && sudo poweroff &
fi
exit 0
