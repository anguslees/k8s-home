#!/bin/sh

: ${KUBECONFIG:=$HOME/.kube/homeconf}
export KUBECONFIG

kubecfg show "$@" |
kubeseal --cert sealkey.crt
