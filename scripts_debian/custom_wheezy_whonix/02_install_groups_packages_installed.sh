#!/bin/bash
# vim: set ts=4 sw=4 sts=4 et :

# ------------------------------------------------------------------------------
# Source external scripts
# ------------------------------------------------------------------------------
. $SCRIPTSDIR/vars.sh
. ./umount_kill.sh >/dev/null

# ------------------------------------------------------------------------------
# Configurations
# ------------------------------------------------------------------------------
if [ "$VERBOSE" -ge 2 -o "$DEBUG" == "1" ]; then
    set -x
else
    set -e
fi

# ------------------------------------------------------------------------------
# XXX: Create a snapshot - Only for DEBUGGING!
# ------------------------------------------------------------------------------
# Only execute if SNAPSHOT is set
if [ "$SNAPSHOT" == "1" ]; then
    splitPath "$IMG" path_parts
    PREPARED_IMG="${path_parts[dir]}${path_parts[base]}-updated${path_parts[dotext]}"

    if ! [ -f "$PREPARED_IMG" ]; then
        umount_kill "$INSTALLDIR" || :
        warn "Copying $IMG to $PREPARED_IMG"
        cp -f "$IMG" "$PREPARED_IMG"
        mount -o loop "$IMG" "$INSTALLDIR" || exit 1
        for fs in /dev /dev/pts /proc /sys /run; do mount -B $fs "$INSTALLDIR/$fs"; done
    fi
fi

# ------------------------------------------------------------------------------
# chroot Whonix build script (Make sure set -e is not set)
# ------------------------------------------------------------------------------
read -r -d '' WHONIX_BUILD_SCRIPT <<'EOF'

################################################################################
# Pre Fixups
sudo mkdir -p /boot/grub2
sudo touch /boot/grub2/grub.cfg
sudo mkdir -p /boot/grub
sudo touch /boot/grub/grub.cfg
sudo mkdir --parents --mode=g+rw "/tmp/uwt"

# Whonix seems to re-install sysvinit even though there is a hold
# on the package.  Things seem to work anyway. BUT hopfully the
# hold on grub* don't get removed
sudo apt-mark hold sysvinit
sudo apt-mark hold grub-pc grub-pc-bin grub-common grub2-common

# Whonix expects haveged to be started
sudo /etc/init.d/haveged start

################################################################################
# Whonix installation
export WHONIX_BUILD_UNATTENDED_PKG_INSTALL="1"

pushd ~/Whonix
sudo ~/Whonix/whonix_build \
    --build $1 \
    --64bit-linux \
    --current-sources \
    --enable-whonix-apt-repository \
    --whonix-apt-repository-distribution $2 \
    --install-to-root \
    --skip-verifiable \
    --minimal-report \
    --skip-sanity-tests || { exit 1; }
popd

################################################################################
# Post Fixups

pushd /etc/network
sudo rm -f interfaces
sudo ln -s interfaces.backup interfaces
popd

pushd /etc
sudo rm -f resolv.conf
sudo ln -s resolv.conf.backup resolv.conf
popd

# Enable Tor
sudo sed -i 's/#DisableNetwork 0/DisableNetwork 0/g' /etc/tor/torrc

# Fake that whonixsetup was already run
sudo mkdir -p /var/lib/whonix/do_once
sudo touch /var/lib/whonix/do_once/whonixsetup.done

# Fake that initializer was already run
sudo mkdir -p /root/.whonix
sudo touch /root/.whonix/first_run_initializer.done

# Prevent whonixcheck error
sudo su -c 'echo WHONIXCHECK_NO_EXIT_ON_UNSUPPORTED_VIRTUALIZER=\"1\" >> /etc/whonix.d/30_whonixcheck_default'

# Ensure umask set in /etc/login.defs is used (022)
sudo su -c 'echo "session optional pam_umask.so" >> /etc/pam.d/common-session'

sudo update-rc.d network-manager disable
sudo update-rc.d spice-vdagent disable
sudo update-rc.d swap-file-creator disable
sudo update-rc.d whonix-initializer disable

sudo touch "/tmp/.prepared_whonix"

EOF

# ------------------------------------------------------------------------------
# chroot Whonix fix script (Make sure set -e is not set)
# Run ../whonix_fix when whonix gives grub-pc error
# ------------------------------------------------------------------------------
# TODO:  Do something in whonix build to automatically run fixups and 
# ignore certain errors
read -r -d '' WHONIX_FIX_SCRIPT <<'EOF'
DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    sudo apt-get -y --force-yes remove grub-pc grub-common grub-pc-bin grub2-common
sudo apt-mark hold grub-common grub-pc-bin grub2-common
EOF

read -r -d '' WHONIX_APT_PIN <<'EOF'
Package: grub-pc
Pin: version *
Pin-Priority: -100

Package: grub-pc-bin
Pin: version *
Pin-Priority: -100

Package: grub-common
Pin: version *
Pin-Priority: -100

Package: grub2-common
Pin: version *
Pin-Priority: -100
EOF

# ------------------------------------------------------------------------------
# Set defualts for apt not to install recommended or extra packages
# ------------------------------------------------------------------------------
read -r -d '' WHONIX_APT_PREFERENCES <<'EOF'
Acquire::Languages "none";
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Dpkg::Options "--force-confold";
EOF

# ------------------------------------------------------------------------------
# Cleanup function
# ------------------------------------------------------------------------------
function cleanup() {
    error "Whonix error; umounting $INSTALLDIR to prevent further writes"
    umount_kill "$INSTALLDIR" || :
    exit 1
}
trap cleanup ERR
trap cleanup EXIT

# ------------------------------------------------------------------------------
# Mount devices, etc required for Whonix installation
# ------------------------------------------------------------------------------
if ! [ -f "$INSTALLDIR/tmp/.prepared_whonix" ]; then
    info "Installing Whonix system"

    # --------------------------------------------------------------------------
    # Initialize Whonix submodules
    # --------------------------------------------------------------------------
    pushd "$WHONIX_DIR"
    {
        su user -c "git submodule update --init --recursive"
    }
    popd

    # --------------------------------------------------------------------------
    # Patch Whonix submodules
    # --------------------------------------------------------------------------
    
    # Patch anon-meta-packages to not depend on grub-pc
    pushd "$WHONIX_DIR"
    {
        #su user -c "git branch qubes 9.2" || :;
        #su user -c "git checkout qubes" || :;
        sed -i 's/grub-pc//g' grml_packages || :;
        #su user -c "git commit -am 'removed grub-pc depend'" || :;
    }
    popd

    pushd "$WHONIX_DIR/packages/anon-meta-packages/debian"
    {
        #su user -c "git branch qubes" || :;
        #su user -c "git checkout qubes" || :;
        sed -i 's/ grub-pc,//g' control || :;
        cd ..;
        su user -c "dpkg-source -q --commit . no_grub" || :;
        #git add .
        #su user -c "git commit -am 'removed grub-pc depend'" || :;
    }
    popd

    pushd "$WHONIX_DIR/packages/anon-shared-build-fix-grub/usr/lib/anon-dist/chroot-scripts-post.d"
    {
        #su user -c "git branch qubes" || :;
        #su user -c "git checkout qubes" || :;
        sed -i 's/update-grub/:/g' 85_update_grub || :;
        cd ../../../..;
        su user -c "dpkg-source -q --commit . no_grub" || :;
        #git add .
        #su user -c "git commit -am 'removed grub-pc depend'" || :;
    }
    popd

    pushd "$WHONIX_DIR/build-steps.d"
    {
        sed -i 's/   check_for_uncommited_changes/   #check_for_uncommited_changes/g' 1200_create-debian-packages;
    }
    popd

    # --------------------------------------------------------------------------
    # Whonix system config dependancies
    # --------------------------------------------------------------------------
    #/usr/sbin/grub-probe: error: cannot find a device for / (is /dev mounted?)
    #cannot stat `/boot/grub/grub.cfg': No such file or directory

    # Qubes needs a user named 'user'
    if chroot "$INSTALLDIR" id -u 'user' >/dev/null 2>&1; then
        :
    else
        chroot "$INSTALLDIR" groupadd -f user
        chroot "$INSTALLDIR" useradd -g user -G dialout,cdrom,floppy,sudo,audio,dip,video,plugdev -m -s /bin/bash user
    fi

    # Change hostname to 'host'
    echo "host" > "$INSTALLDIR/etc/hostname"
    chroot "$INSTALLDIR" sed -i "s/localhost/host/g" /etc/hosts

    if ! [ -f "$INSTALLDIR/etc/sudoers.d/qubes" ]; then
        cp -p /etc/sudoers.d/qubes "$INSTALLDIR/etc/sudoers.d/qubes"
    fi

    # --------------------------------------------------------------------------
    # Install Whonix system
    # --------------------------------------------------------------------------
    if ! [ -d "$INSTALLDIR/home/user/Whonix" ]; then
        debug "Installing Whonix build environment..."
        chroot "$INSTALLDIR" su user -c 'mkdir /home/user/Whonix'
    fi

    if [ -d "$INSTALLDIR/home/user/Whonix" ]; then
        debug "Building Whonix..."
        mount --bind "../Whonix" "$INSTALLDIR/home/user/Whonix"

       # This breaks whonix depends since it must just rely on recommended
       # packages since it seems to install just about everything :)
       # Install apt-get preferences
       #echo "$WHONIX_APT_PREFERENCES" > "$INSTALLDIR/etc/apt/apt.conf.d/99whonix"
       #chmod 0644 "$INSTALLDIR/etc/apt/apt.conf.d/99whonix"

       # Pin grub packages so they will not install
       echo "$WHONIX_APT_PIN" > "$INSTALLDIR/etc/apt/preferences.d/whonix_qubes"
       chmod 0644 "$INSTALLDIR/etc/apt/preferences.d/whonix_qubes"

       # Install Whonix fix script
       echo "$WHONIX_FIX_SCRIPT" > "$INSTALLDIR/home/user/whonix_fix"
       chmod 0755 "$INSTALLDIR/home/user/whonix_fix"

       # Install Whonix build scripts
       echo "$WHONIX_BUILD_SCRIPT" > "$INSTALLDIR/home/user/whonix_build"
       chmod 0755 "$INSTALLDIR/home/user/whonix_build"

       if [ "${TEMPLATE_FLAVOR}" == "whonix-gateway" ]; then
           BUILD_TYPE="--torgateway"
       elif [ "${TEMPLATE_FLAVOR}" == "whonix-workstation" ]; then
           BUILD_TYPE="--torworkstation"
       else
           error "Incorrent Whonix type \"${TEMPLATE_FLAVOR}\" selected.  Not building Whonix modules"
           error "You need to set TEMPLATE_FLAVOR environment variable to either"
           error "whonix-gateway OR whonix-workstation"
           exit 1
       fi

       chroot "$INSTALLDIR" su user -c "cd ~; ./whonix_build $BUILD_TYPE $DIST" || { exit 1; }
    fi
fi

# ------------------------------------------------------------------------------
# Execute any custom configuration scripts
# ------------------------------------------------------------------------------
customStep "99_custom_configuration.sh"

# XXX: Why do I need to move them out of the way?  Lets try keeping them
# in place (modify post script too)
# ------------------------------------------------------------------------------
# Move Whonix sources out of way
# ------------------------------------------------------------------------------
#if [ -L "$INSTALLDIR/etc/apt/sources.list.d" ]; then
#    mv "$INSTALLDIR/etc/apt/sources.list.d" "$INSTALLDIR/etc/apt/sources.list.d.qubes"
#    mkdir -p "$INSTALLDIR/etc/apt/sources.list.d"
#    cp -p "$INSTALLDIR/etc/apt/sources.list.d.qubes/debian.list" "$INSTALLDIR/etc/apt/sources.list.d"
#fi

# ------------------------------------------------------------------------------
# Bring back original apt-get for installation of Qubues
# ------------------------------------------------------------------------------
if [ -L "$INSTALLDIR/usr/bin/apt-get" ]; then
    rm "$INSTALLDIR/usr/bin/apt-get"
    chroot "$INSTALLDIR" su -c "cd /usr/bin/; ln -s apt-get.anondist-orig apt-get"
fi

# ------------------------------------------------------------------------------
# Leave cleanup to calling function
# ------------------------------------------------------------------------------
trap - ERR EXIT
trap
