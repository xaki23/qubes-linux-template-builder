#!/bin/sh
# vim: set ts=4 sw=4 sts=4 et :

# ------------------------------------------------------------------------------
# Configurations
# ------------------------------------------------------------------------------
. $SCRIPTSDIR/vars.sh

set -e
if [ "$VERBOSE" -ge 2 -o "$DEBUG" == "1" ]; then
    set -x
fi

# ------------------------------------------------------------------------------
# Execute any custom pre configuration scripts
# ------------------------------------------------------------------------------
customStep "$0" "pre"

# ------------------------------------------------------------------------------
# Install base debian system
# ------------------------------------------------------------------------------
if ! [ -f "$INSTALLDIR/tmp/.prepared_debootstrap" ]; then
    echo "-> Installing base ${DEBIANVERSION} system"
    COMPONENTS="" debootstrap --arch=amd64 --include=ncurses-term \
        --components=main --keyring="${SCRIPTSDIR}/keys/debian-${DEBIANVERSION}-archive-keyring.gpg" \
        "$DEBIANVERSION" "$INSTALLDIR" "$DEBIAN_MIRROR" || { echo "Debootstrap failed!"; exit 1; }
    chroot "$INSTALLDIR" chmod 0666 "/dev/null"
    touch "$INSTALLDIR/tmp/.prepared_debootstrap"
fi

# ------------------------------------------------------------------------------
# Execute any custom post configuration scripts
# ------------------------------------------------------------------------------
customStep "$0" "post"
