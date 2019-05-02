{
  kube_system: import "kube-system.jsonnet",

  flannel: import "flannel.jsonnet",
  heapster: import "heapster.jsonnet",
  // dashboard (at least v1.7.1) only shows heapster stats
  //kubemetrics: import "kube-metrics.jsonnet",

  ssecrets: import "sealed-secrets.jsonnet",

  metallb: import "metallb.jsonnet",
  nginx_ingress: import "nginx-ingress.jsonnet",
  cert_manager: import "cert-manager.jsonnet",
  dyndns: import "dyndns.jsonnet",

  coreos_pxe_install: import "coreos-pxe-install.jsonnet",
  coreos_updater: import "coreos-updater.jsonnet",
  kured: (import "kured.jsonnet") {
    prometheus_svc: $.prometheus.prometheus.svc,
  },

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

  ipfs: import "ipfs.jsonnet",
  docker_ipfs: (import "docker-ipfs.jsonnet") {
    ipfsSvc: $.ipfs.svc,
  },

  rook_ceph_system: import "rook-ceph-system.jsonnet",
  rook_ceph: import "rook-ceph.jsonnet",

  webcache: import "webcache.jsonnet",
  mail: import "mail.jsonnet",
  cloudprint: import "cloudprint.jsonnet",
  echoheaders: import "echoheaders.jsonnet",
  jenkins: (import "jenkins.jsonnet") {
    http_proxy: $.webcache.svc,
  },
  jenkins_containos: import "jenkins-containos.jsonnet",
  gitlab_runner: import "gitlab-runner.jsonnet",
  openhab: import "openhab.jsonnet",
  mycroft: (import "mycroft.jsonnet") {
    http_proxy: $.webcache.svc,
    openhab: $.openhab.svc,
  },
}
