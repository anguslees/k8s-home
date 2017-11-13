#!/bin/sh

# scp root@kube.lan:/etc/kubernetes/admin.conf /tmp/kubeconfig

KUBECONFIG=/tmp/kubeconfig
KUBECFG_JPATH=$HOME/go/src/github.com/ksonnet/kubecfg/lib:$HOME/src/ksonnet-lib:$HOME/src/gus-sre-kube-manifests/lib
export KUBECONFIG KUBECFG_JPATH

exec kubecfg \
    --kubeconfig /tmp/kubeconfig \
    update -v --gc-tag=garagecloud "$@" all.jsonnet
