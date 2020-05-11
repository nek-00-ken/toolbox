#!/usr/bin/env bash
# shellcheck disable=SC2086

set -eu
set -o pipefail

log() {
  echo -e "\e[32m--- $*\e[0m" >&2
}

log-error() {
  echo -e "\e[31m--- $*\e[0m" >&2
}

run() {
  echo -e "\e[33m+++ $1\e[0m" >&2
  eval "$1"
}

run_c() {
  echo -e "\e[33m+++ $1\e[0m" >&2
  _continue
  eval "$1"
}

_continue() {
  read -p "Continue [y/n]: " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]] || exit 1
}

bash-completions() {
  cat <<EOF
_kswitch_completions() {
  local curr_arg;
  curr_arg=\${COMP_WORDS[COMP_CWORD]}
  if [ \${#COMP_WORDS[@]} -ge 3 ]; then
    return
  fi
  COMPREPLY=( \$(compgen -W "- \$(kubectl config get-contexts --output='name')" -- \$curr_arg ) );
}
complete -F _kswitch_completions kswitch
EOF
}

usage() {
  cat <<EOF
Usage:
  kswitch               Show kswitch status
  kswitch ZONE_NAME     Start tunnel to ZONE_NAME and change kubectl context
  kswitch -k, --kill    Stop any active tunnel
  kswitch -h, --help    This help

kswitch automatically setup an SSH tunnel to the specified zone K8S cluster.

To do this it will configure the local kubectl configuration (usually ~/.kube/config)
by adding the zone as a context and the user credentials by downloading them
from the .kube/config file of the bastion of the zone.

If the zone has not been configured with kswitch only the kubectl context is
changed.

You can get bash completions for kswitch, add this to your ~/.bashrc:

  source <(kswitch bash-completions)
EOF
}

setup() {
  if [ ! -d $configDir ]; then
    log "Looks like you are running kswitch for the first-time!"
    log "I'm going to create $configDir for storing kswitch configurations."
    _continue
    mkdir -p $configDir
  fi

  if ! kubectl config get-clusters | grep -q tunnel; then
    log "I'm going to add a cluster named tunnel to the local kube configuration:"
    run_c "kubectl config set-cluster tunnel --server https://localhost:${localPort} --insecure-skip-tls-verify=true"
  fi
}

kill-tunnel() {
  # Add unused argument foo to run the command
  # it's not used but cli parsing requires it
  # This will kill the active ssh tunnel if any
  ssh -S /dev/shm/kswitch -O exit foo 2>/dev/null || true
}

vault_login() {
    vault token lookup >/dev/null 2>&1 || vault login -method oidc
}

vault_config() {
    vault read "secret/zones/fe/${zone}/kubeconfig" -format=json
}

kubeconfig_bastion() {
  dest=cloud@bst.${zone}.caascad.com

  if [ ! -f ${configDir}/${zone} ]; then
    log "No configuration has been found for zone ${zone}"
    log "Fetching kubeconfig on ${zone} bastion..."
    kubeconfig=$(mktemp)
    run "ssh -o ConnectTimeout=3 $dest cat .kube/config > $kubeconfig"
    jq -r .clusters[].cluster.server $kubeconfig | cut -d'/' -f3 > $configDir/$zone
    jq -r '.users[].user["client-certificate-data"]' $kubeconfig | base64 -d > ${configDir}/${zone}-cert
    jq -r '.users[].user["client-key-data"]' $kubeconfig | base64 -d > ${configDir}/${zone}-key
    chmod 600 ${configDir}/${zone}-key
    log "Configuring kube credentials for zone ${zone}..."
    run "kubectl config set-credentials $zone-admin --client-certificate=${configDir}/${zone}-cert --client-key=${configDir}/${zone}-key"
    log "Configuring kube context for zone ${zone}..."
    run "kubectl config set-context $zone --user=${zone}-admin --cluster=tunnel"
    rm -f $kubeconfig
    log "Configuration for ${zone} is completed!"
  fi
}

kubeconfig_vault() {
    if ! kubectl config get-contexts ocb-test01 >/dev/null 2>&1; then
        log "No configuration has been found for zone ${zone}"
        log "Fetching zone info on ${VAULT_ADDR}"
        log "Configuring kube credentials for zone ${zone}..."
        run "kubectl config set-credentials $zone-admin --exec-api-version=client.authentication.k8s.io/v1beta1 --exec-command=kswitch --exec-arg=-v --exec-arg=-c --exec-arg=${zone}"
        log "Configuring kube context for zone ${zone}..."
        run "kubectl config set-context $zone --user=${zone}-admin --cluster=tunnel"
    fi
}

tunnel() {
    dest=cloud@bst.${zone}.caascad.com

    if [ $useVault -eq 1 ]; then
        vault_login
        kube=$(vault_config | jq -r .data.clusters[].cluster.server | cut -d'/' -f3)
    else
        kube=$(cat ${configDir}/${zone})
    fi
    log "Forwarding through ${dest}..."
    ssh -4 -M -S /dev/shm/kswitch -fnNT -L ${localPort}:${kube} -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 $dest
}

credentials() {
  vault_login
  vault_config | jq '{"apiVersion": "client.authentication.k8s.io/v1beta1", "kind": "ExecCredential", "status": { "clientCertificateData": .data.users[].user["client-certificate-data"] | @base64d, "clientKeyData": .data.users[].user["client-key-data"] | @base64d }}'
  exit 0
}


status() {
  context=$(kubectl config current-context)
  log "Current context is $context"
  if [ ! -S /dev/shm/kswitch ]; then
    log-error "Tunnel is down: run kswitch $context"
    exit 1
  fi
  tunnelPID=$(ssh -S /dev/shm/kswitch -O check foo 2>&1 | sed 's/.*pid=\([0-9]*\).*/\1/')
  cmd=$(tr '\000' ':' </proc/${tunnelPID}/cmdline | rev | cut -c 2- | rev)
  log "Tunnel is active (pid=$tunnelPID)"
  log "Tunneling through ${cmd##*:}"
  exit 0
}

localPort=30000
configDir=$HOME/.config/kswitch
zoneVault="infra-stg"
zone=""
useVault=0
execCredentialMode=0

while (( "$#" )); do
    case "$1" in
        bash-completions)
        bash-completions
        exit 0
        ;;
        -h|--help)
        usage
        exit 0
        ;;
        -k|--kill)
        kill-tunnel
        exit 0
        ;;
        -v|--vault)
        useVault=1
        shift
        ;;
        -c)
        execCredentialMode=1
        shift
        ;;
        *)
        [ "$zone" != "" ] && (echo -e "Error: too much arguments\n" && usage && exit 1)
        zone=$1
        shift
        ;;
    esac
done

# Makes sure to use ~/.kube/config
unset KUBECONFIG

export VAULT_ADDR="https://vault.${zoneVault}.caascad.com"

[ "$zone" == "" ] && status

[ $execCredentialMode -eq 1 ] && credentials

setup

zoneCluster=$(kubectl config view -o json | jq -r "select(.contexts != null) |.contexts[] | select(.name == \"$zone\") | .context.cluster")

kill-tunnel

if [ "$zoneCluster" = "tunnel" ] || [ "$zoneCluster" = "" ]; then
  if [ $useVault -eq 1 ]; then
    kubeconfig_vault
  else
    kubeconfig_bastion
  fi
  tunnel
fi

kubectl config use-context $zone
