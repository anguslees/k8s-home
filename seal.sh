#!/bin/sh

KUBECFG_JPATH=$HOME/src/gus-sre-kube-manifests/lib
export KUBECFG_JPATH

kubecfg show -V RANDOM=$(date +%s) "$@" |
kubeseal --cert sealkey.crt
