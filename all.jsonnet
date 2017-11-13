// Terrible workaround for
// https://github.com/kubernetes/kubernetes/issues/53379
local dummychange = {
  metadata+: {annotations+: {"dummychange": std.extVar("RANDOM")}},
};

{
  kube_system: import "kube-system.jsonnet",

  dashboard: import "dashboard.jsonnet",
  flannel: import "flannel.jsonnet",
  heapster: import "heapster.jsonnet",
  // dashboard (at least v1.7.1) only shows heapster stats
  //kubemetrics: import "kube-metrics.jsonnet",

  ssecrets: import "sealed-secrets.jsonnet",

  keepalived: import "keepalived.jsonnet",
  nginx_ingress: import "nginx-ingress.jsonnet",
  kube_lego: import "kube-lego.jsonnet",
  dyndns: (import "dyndns.jsonnet") {
    secret+: dummychange,
  },

  coreos_pxe_install: import "coreos-pxe-install.jsonnet",
  coreos_updater: import "coreos-updater.jsonnet",

  nfs: (import "nfs.jsonnet") {
    storageClass+: {
      metadata+: {
        // There can be only one default, so set here rather than nfs.jsonnet
        annotations+: {"storageclass.kubernetes.io/is-default-class": "true"},
      },
    },
  },

  prometheus: (import "prometheus.jsonnet") {
    config+: {global+: {external_labels+: {cluster: "home"}}},
  },

  //docker_ipfs: import "docker-ipfs.jsonnet",
  //ipfs: import "ipfs.jsonnet",

  ghomekodi: (import "ghomekodi.jsonnet") {
    config+: dummychange,
  },
  cloudprint: (import "cloudprint.jsonnet") {
    config+: dummychange,
  },
  echoheaders: import "echoheaders.jsonnet",
}
