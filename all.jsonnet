{
  kube_system: import "kube-system.jsonnet",

  calico: import "calico.jsonnet",

  kubelet_approver: import "kubelet-csr-approver.jsonnet",

  ssecrets: import "sealed-secrets.jsonnet",

  metallb: import "metallb.jsonnet",
  nginx_ingress: import "nginx-ingress.jsonnet",
  cert_manager: import "cert-manager.jsonnet",
  external_dns: import "external-dns.jsonnet",

  coreos_pxe_install: import "coreos-pxe-install.jsonnet",
  coreos_updater: import "coreos-updater.jsonnet",
  kured: (import "kured.jsonnet") {
    prometheus_svc: $.prometheus.prometheus.svc,
  },

  local_volume: import "local-volume.jsonnet",
  nfs: import "nfs.jsonnet",

  prometheus: (import "prometheus.jsonnet") {
    config+: {global+: {external_labels+: {cluster: "home"}}},
  },

  ipfs: import "ipfs.jsonnet",
  docker_ipfs: import "docker-ipfs.jsonnet",

  rook_ceph_system: import "rook-ceph-system.jsonnet",
  rook_ceph: (import "rook-ceph.jsonnet") {
    blockCsi+: {
      metadata+: {
        // There can be only one default, so set here rather than rook-ceph.jsonnet
        annotations+: {"storageclass.kubernetes.io/is-default-class": "true"},
      },
    },
  },

  webcache: import "webcache.jsonnet",
  mail: import "mail.jsonnet",
  echoheaders: import "echoheaders.jsonnet",
  openhab: import "openhab.jsonnet",
  restic: import "restic.jsonnet",
}
