#!/bin/sh

usage() {
cat <<EOM
Usage: toolbox <command> [args]

 init                 -- configure initial setup
 doctor               -- perform sanity checks
 list                 -- list available tools
 update               -- update all installed tools
 install [tool]       -- install a tool
 uninstall [tool]     -- uninstall a previously installed tool
 shell [tool] [tool]  -- create a project dev shell with a list of tools
 completions          -- output completion script

In order to enable context-sensitive completions (bash only!) run:

  $ source <(./toolbox completions)

You should add this to your init scripts.
EOM
}


log() {
    local args="$*"
    local PLEASE="\e[32m[toolbox]:\e[0m"
    echo -e "$PLEASE $args"
}

log-error() {
    local args="$*"
    local PLEASE="\e[31m[toolbox]\e[0m"
    echo -e "$PLEASE $args"
}

log-run() {
    local cmd="$1"
    log "Running \"$cmd\"\n"
    eval $cmd
}

_get_name() {
    local pkg="$1"
    nix-instantiate --strict --eval --expr "(import $ENTRYPOINT {}).$1.name" | tr -d '"'
}

check_args() {
    local actual="$1"
    local expected="$2"
    local cmd="$3"

    if [ "$actual" -ne "$expected" ]; then
        log-error "'$cmd' requires $expected arguments but $actual were given"
        exit 1
    fi
}

#
# sanity check functions
#

_isRegularUser() {
    test $(id -u) -ne 0
}

_hasKvmSupport() {
    test -c /dev/kvm && test -w /dev/kvm && test -r /dev/kvm
}

_isNixInstalled() {
    nix --version >/dev/null 2>&1
}

_sourceNix() {
    NIX_SH="$HOME/.nix-profile/etc/profile.d/nix.sh"
    test -f "$NIX_SH" && source "$NIX_SH" || true
}

_isSubstituterConfigured() {
    nix show-config | grep "toolbox.cachix.org" >/dev/null
}

_addCacheConfig() {
    if test -f ~/.config/nix/nix.conf
    then
        log "$HOME/.config/nix/nix.conf exists. Please follow the instructions from the README"
    else
        mkdir -p "$HOME"/.config/nix/
        cat << EOF > "$HOME"/.config/nix/nix.conf
substituters = https://cache.nixos.org https://toolbox.cachix.org
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= toolbox.cachix.org-1:ZFzO+86jD4G5ukgmLOnQRxjVmMcqu+60JTusH6pv8/8=
EOF
    fi
}
