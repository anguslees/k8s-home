#!/bin/sh

: ${KUBECONFIG:=$HOME/.kube/homeconf}
KUBECFG_JPATH=$HOME/src/gus-sre-kube-manifests/lib
export KUBECONFIG KUBECFG_JPATH

# --ignore-unknown is required for the initial bootstrap (else
# SealedSecrets will fail to validate before the SealedSecret CRD is
# created)
exec kubecfg \
    update --gc-tag=garagecloud -V RANDOM=$(date +%s) "$@" all.jsonnet
