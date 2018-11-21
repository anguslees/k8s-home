#!/bin/sh

: ${KUBECONFIG:=$HOME/.kube/homeconf}
export KUBECONFIG

# --ignore-unknown is required for the initial bootstrap (else
# SealedSecrets will fail to validate before the SealedSecret CRD is
# created)
exec kubecfg \
    update --ignore-unknown --gc-tag=garagecloud "$@" all.jsonnet
