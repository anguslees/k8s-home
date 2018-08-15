#!/bin/sh

: ${KUBECONFIG:=$HOME/.kube/homeconf}
export KUBECONFIG

kubecfg show -V RANDOM=$(date +%s) "$@" |
kubeseal --cert sealkey.crt
