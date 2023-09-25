// kubeadm is dead to me :(
// (not true: I use kubeadm to join nodes, but from there it's self-hosted via this file)
//
// https://github.com/kubernetes/kubeadm/issues/413
// https://github.com/kubernetes/enhancements/issues/415#issuecomment-409989216
//

local kube = import "kube.libsonnet";
local kubecfg = import "kubecfg.libsonnet";
local utils = import "utils.libsonnet";
local certman = import "cert-manager.jsonnet";

// NB: Kubernetes (minor semver) upgrade order is:
// 1. apiserver first
// 2. rest of control plane
// 3. kubelets (see coreos-pxe-install.jsonnet:coreos_kubelet_tag)

// renovate: depName=registry.k8s.io/kube-proxy
local version = "v1.25.11";
// renovate: depName=registry.k8s.io/kube-apiserver
local apiserverVersion = "v1.25.11";

local externalHostname = "kube.lan";
local apiServer = "https://%s:6443" % [externalHostname];
local clusterCidr = "10.244.0.0/16,2406:3400:249:1703::/64";
local serviceClusterCidr = "10.96.0.0/12,fdd6:fe3c:9ebc:33e2::/112";
local dnsIP = "10.96.0.10";
local dnsDomain = "cluster.local";

// NB: these IPs are also burnt into the peer/server certificates,
// because of the golang TLS verification wars.
local etcdMembers = {
  "b4c71f92c2214edb97a4a11e17482a01": "192.168.0.166", // etcd-2 - Dell optiplex
  // Flaky
  //"fc4698cdc1184810a2c3447a7ee66689": "192.168.0.129",  // etcd-0 - Red HP
  // Dead
  //"0b5642a6cc18493d81a606483d9cbb7b": "192.168.0.132",  // etcd-1 - Red Lenovo
  "887f1b514ea54520a61643163d427d42": "192.168.0.161",  // etcd-2 - Old tower
  "765885d83e774555bc7ee0f9c6fc1178": "192.168.0.117",  // etcd-1 - Dell silver/stickers (new)
  "6751cbb9e81a4a928510cec6eec02a78": "192.168.0.102",  // etcd-3 - Lenovo T530
};
local etcdLearners = std.set(["b4c71f92c2214edb97a4a11e17482a01"]);

local isolateMasters = false;

local labelSelector(labels) = {
  matchExpressions+: [
    {key: kv[0], operator: "In", values: [kv[1]]}
    for kv in kube.objectItems(labels)
  ],
};

local bootstrapTolerations = [{
  key: t[0],
  effect: t[1],
  operator: "Exists",
} for t in [
  ["node.kubernetes.io/not-ready", "NoExecute"],
  ["node.kubernetes.io/unreachable", "NoExecute"],
]];

local andTerm(orig, extra) = (
  local base = if std.length(orig) == 0 then [{}] else orig;
  [t + extra for t in base]
);

local checkpoint = {
  metadata+: {
    annotations+: {
      "checkpointer.alpha.coreos.com/checkpoint": "true",
    },
  },
  spec+: {
    affinity+: {
      nodeAffinity+: {
        requiredDuringSchedulingIgnoredDuringExecution+: {
          // Limit checkpointer to amd64 nodes for now.
          local superterm = if 'nodeSelectorTerms' in super then super.nodeSelectorTerms else [],
          nodeSelectorTerms: andTerm(superterm, labelSelector(utils.archSelector("amd64"))),
        },
      },
    },
  },
};

local apiGroup(gv) = (
  local split = std.splitLimit(gv, "/", 1);
  if std.length(split) == 1 then "" else split[0]
);

local issuerRef(issuer) = {
  group: apiGroup(issuer.apiVersion),
  kind: issuer.kind,
  name: issuer.metadata.name,
};

local Certificate(name, issuer) = certman.Certificate(name) {
  spec+: {
    issuerRef: issuerRef(issuer),
    isCA: false,
    usages_:: ["digital signature", "key encipherment"],
    usages: std.set(self.usages_),
    subject: {organizations: []},
    dnsNames_:: [],
    dnsNames: std.set(self.dnsNames_),
    ipAddresses_:: [],
    ipAddresses: std.set(self.ipAddresses_),
    commonName: name,
    secretName: name,
    duration_h_:: 365 * 24 / 4, // 3 months
    duration: "%dh" % self.duration_h_,
    renewBefore_h_:: self.duration_h_ / 3,
    renewBefore: "%dh" % self.renewBefore_h_,
    //privateKey+: {rotationPolicy: "Always"},  TODO: set this, after upgrading to newer cert-manager
    privateKey: {algorithm: "ECDSA"},
    revisionHistoryLimit: 1,
  },

  // Fake Secret, used to represent the _real_ cert Secret to jsonnet
  secret_:: kube.Secret($.spec.secretName) {
    metadata+: {namespace: $.metadata.namespace},
    type: "kubernetes.io/tls",
    data: {[k]: error "attempt to access TLS value directly"
      for k in ["tls.crt", "tls.key", "ca.crt"]},
  },
};

local CA(name, namespace, issuer) = {
  cert: Certificate(name, issuer) {
    metadata+: {namespace: namespace},
    spec+: {
      isCA: true,
      usages_+: ["cert sign", "crl sign"],
      // CA rotation is still clumsy in cert-manager.
      // https://github.com/jetstack/cert-manager/issues/2478
      duration_h_: 365 * 24 * 10, // 10y
    },
  },

  issuer: certman.Issuer(name) {
    metadata+: {namespace: namespace},
    spec+: {
      ca: {secretName: $.cert.spec.secretName},
    },
  },
};

// Inspiration:
//  https://github.com/kubernetes/kubeadm/blob/master/docs/design/design_v1.10.md
//  https://github.com/kubernetes-incubator/bootkube/blob/master/pkg/asset/internal/templates.go

{
  namespace:: {
    metadata+: { namespace: "kube-system" },
  },

  etcd: {
    ca: CA("kube-etcd-ca", $.namespace.metadata.namespace, $.selfSigner),

    // kubeadm uses /etc/kubernetes/pki/etcd-ca.crt
    ca_bundle: kube.Secret("kube-etcd-ca-bundle") + $.namespace {
      data_: {
        "ca.crt": importstr "pki/etcd-ca.pem",
      },
    },


    serverCert: Certificate("etcd-server", self.ca.issuer) + $.namespace {
      spec+: {
        usages_+: ["server auth"],
        ipAddresses_: kube.objectValues(etcdMembers) + ["127.0.0.1", "::1"],
      },
    },

    peerCert: Certificate("etcd-peer", self.ca.issuer) + $.namespace {
      spec+: {
        usages_+: ["server auth", "client auth"],
        commonName: "etcd.local", // historical.
        ipAddresses_: kube.objectValues(etcdMembers),
      },
    },

    monitorCert: Certificate("etcd-monitor", self.ca.issuer) + $.namespace {
      spec+: {
        usages_+: ["client auth"],
      },
    },

    svc: kube.Service("etcd") + $.namespace {
      target_pod: $.etcd.deploy.spec.template,
      spec+: {
        clusterIP: "None", // headless
        ports: [{
          // NB: etcd DNS (SRV) discovery uses _etcd-server-ssl._tcp
          name: "etcd-server-ssl",
          port: 2379,
          targetPort: self.port,
          protocol: "TCP",
        }],
      },
    },

    pdb: kube.PodDisruptionBudget("etcd") + $.namespace {
      target_pod: $.etcd.deploy.spec.template,
      spec+: {minAvailable: 2},
    },

    deploy: kube.StatefulSet("etcd") + $.namespace {
      local this = self,
      spec+: {
        replicas: 4, // 3 full + 1 learner
        podManagementPolicy: "Parallel",
        updateStrategy+: {
          type: "RollingUpdate",
        },
        volumeClaimTemplates_: {
          // NB: No good!  Can't have a PVC in a (checkpointed)
          // static bootstrap manifest.  Need to use regular host mount
          // paths :(
          //data: {storage: "10Gi", storageClass: "local-storage"},
        },
        template+: utils.CriticalPodSpec + utils.PromScrape(2381) + checkpoint {
          spec+: {
            hostNetwork: true,
            dnsPolicy: "ClusterFirstWithHostNet",
            tolerations+: utils.toleratesMaster + bootstrapTolerations + [{
              effect: "NoSchedule",
              key: "node.cloudprovider.kubernetes.io/uninitialized",
              value: "true",
            }],
            automountServiceAccountToken: false,

            // etcd is really 'system-cluster-critical', but if we get
            // pre-empted we can end up in a place where the cluster
            // can't recover.  Really we want "don't preempt me."
            priorityClassName: "system-node-critical",

            securityContext+: {
              // uid=0 needed to write to /var/lib/etcd.  NB:
              // kubelet always creates DirectoryOrCreate hostpaths
              // with uid:gid 0:0, perms 0755.
              //runAsNonRoot: true,
              //runAsUser: 2000,
              //fsGroup: 0,
            },
            volumes_: {
              data: kube.HostPathVolume("/var/lib/etcd", "DirectoryOrCreate"),
              etcd_ca: kube.SecretVolume($.etcd.ca_bundle),
              etcd_server: kube.SecretVolume($.etcd.serverCert.secret_),
              etcd_peer: kube.SecretVolume($.etcd.peerCert.secret_),
              etcd_client: kube.SecretVolume($.etcd.monitorCert.secret_),
            },
            affinity+: {
              nodeAffinity+: {
                requiredDuringSchedulingIgnoredDuringExecution+: {
                  nodeSelectorTerms: andTerm(super.nodeSelectorTerms, {
                    matchExpressions+: [
                      {
                        key: "kubernetes.io/hostname",
                        operator: "In",
                        values: std.objectFields(etcdMembers),
                      },
                    ],
                  }),
                },
              },
              podAntiAffinity+: {
                requiredDuringSchedulingIgnoredDuringExecution+: [{
                  labelSelector: labelSelector(this.spec.template.metadata.labels),
                  topologyKey: "kubernetes.io/hostname",
                }],
              },
            },
            containers_+: {
              etcd: kube.Container("etcd") {
                image: "gcr.io/etcd-development/etcd:v3.5.9", // renovate
                securityContext+: {
                  allowPrivilegeEscalation: false,
                },
                command: ["etcd"],
                args_+: {
                  "advertise-client-urls": "https://$(POD_IP):2379",
                  "data-dir": "/data",
                  "listen-client-urls": "https://127.0.0.1:2379,https://$(POD_IP):2379",
                  // Imposes even more restrictions on SANs :(
                  //"discovery-srv": $.etcd.svc.host,
                  "initial-cluster": std.join(",", [
                    "%s=https://%s:2380" % kv for kv in kube.objectItems(etcdMembers)
                  ]),
                  "initial-advertise-peer-urls": "https://$(POD_IP):2380",
                  "initial-cluster-state": "existing",
                  "cert-file": "/keys/etcd-server/tls.crt",
                  "key-file": "/keys/etcd-server/tls.key",
                  "peer-cert-file": "/keys/etcd-peer/tls.crt",
                  "peer-key-file": "/keys/etcd-peer/tls.key",
                  "peer-trusted-ca-file": "/keys/etcd-ca/ca.crt",
                  "peer-client-cert-auth": true,
                  "peer-cert-allowed-cn": $.etcd.peerCert.spec.commonName,
                  "listen-peer-urls": "https://$(POD_IP):2380",
                  "client-cert-auth": true,
                  "trusted-ca-file": "/keys/etcd-ca/ca.crt",
                  "election-timeout": "10000",
                  "heartbeat-interval": "1000",
                  "experimental-warning-apply-duration": "1s", // default 100ms too noisy
                  "listen-metrics-urls": "http://0.0.0.0:2381",

                  "experimental-initial-corrupt-check": true,
                  "v2-deprecation": "write-only",  // accelerate v2 deprecation
                },
                env_+: {
                  ETCD_NAME: kube.FieldRef("spec.nodeName"),
                  POD_IP: kube.FieldRef("status.podIP"),
                  ETCDCTL_API: "3",
                  ETCDCTL_CACERT: "/keys/etcd-server/ca.crt",
                  ETCDCTL_CERT: "/keys/etcd-client/tls.crt",
                  ETCDCTL_KEY: "/keys/etcd-client/tls.key",
                  // AA_POD_IP is a hack to force jsonnet to order it
                  // before the variable is used in ETCDCTL_ENDPOINTS.
                  // TODO: Teach kube.libsonnet about env variable
                  // dependencies.
                  AA_POD_IP: kube.FieldRef("status.podIP"),
                  ETCDCTL_ENDPOINTS: "https://$(AA_POD_IP):2379/",
                  GOGC: "25",
                  GOMEMLIMIT: kube.ResourceFieldRef("requests.memory"),
                },
                livenessProbe: {
                  httpGet: {path: "/health?serializable=true&exclude=NOSPACE", port: 2381, scheme: "HTTP"},
                  // v1.23 + GRPCContainerProbe feature gate
                  //grpc: {port: 2379}
                  failureThreshold: 5,
                  timeoutSeconds: 15,
                  periodSeconds: 30,
                },
                readinessProbe: self.livenessProbe {
                  httpGet+: {path: "/health?serializable=false"},
                  tcpSocket: null,
                  failureThreshold: 3,
                },
                startupProbe: self.livenessProbe {
                  httpGet+: {path: "/health?serializable=false"},
                  local timeoutSeconds = 30 * 60,
                  failureThreshold: std.ceil(timeoutSeconds / self.periodSeconds),
                },
                volumeMounts_+: {
                  data: {mountPath: "/data"},
                  etcd_ca: {mountPath: "/keys/etcd-ca", readOnly: true},
                  etcd_peer: {mountPath: "/keys/etcd-peer", readOnly: true},
                  etcd_server: {mountPath: "/keys/etcd-server", readOnly: true},
                  etcd_client: {mountPath: "/keys/etcd-client", readOnly: true},
                },
                resources+: {
                  limits: {memory: "700Mi", cpu: "700m"},
                  requests: {memory: "400Mi", cpu: "400m"},
                },
                // lifecycle+: {
                //   local etcdctl = ["etcdctl"],
                //   postStart: {
                //     exec: {
                //       command: etcdctl + [
                //         // FIXME: shadows ETCDCTL_ENDPOINTS env var (fatal error)
                //         "--endpoints=https://etcd:2379",
                //         "member",
                //         "add",
                //         "$(ETCD_NAME)",
                //         "--peer-urls=https://$(POD_IP):2380",
                //       ],
                //     },
                //   },
                //   preStop: {
                //     exec: {
                //       command: etcdctl + [
                //         "member",
                //         "remove",
                //         // FIXME: needs to be ID, not NAME
                //         "$(ETCD_NAME)",
                //       ],
                //     },
                //   },
                // },
              },
            },
          },
        },
      },
    },
  },

  // Quoting the same comment from bootkube:
  // KubeConfigInCluster instructs clients to use their service account token,
  // but unlike an in-cluster client doesn't rely on the `KUBERNETES_SERVICE_PORT`
  // and `KUBERNETES_PORT` to determine the API servers address.
  //
  // This kubeconfig is used by bootstrapping pods that might not have access to
  // these env vars, such as kube-proxy, which sets up the API server endpoint
  // (chicken and egg), and the checkpointer, which needs to run as a static pod
  // even if the API server isn't available.
  kubeconfig_in_cluster: kube.ConfigMap("kubeconfig-in-cluster") + $.namespace {
    data+: {
      "kubeconfig.conf": kubecfg.manifestYaml(self.kubeconfig_),
      kubeconfig_:: {
        apiVersion: "v1",
        kind: "Config",
        clusters: [{
          name: "default",
          cluster: {
            "certificate-authority": "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt",
            server: apiServer,
          },
        }],
        users: [{
          name: "default",
          user: {tokenFile: "/var/run/secrets/kubernetes.io/serviceaccount/token"},
        }],
        contexts: [{
          name: "default",
          context: {
            cluster: "default",
            namespace: "default",
            user: "default",
          },
        }],
        "current-context": "default",
      },
    },
  },

  selfSigner: certman.Issuer("selfsign") + $.namespace {
    spec+: {selfSigned: {}},
  },

  secrets: {
    local tlsType = "kubernetes.io/tls",

    // Public CA bundle (ca.crt - possibly contains multiple certificates)
    // Same as /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    // kubeadm (incorrectly) uses /etc/kubernetes/pki/ca.crt
    ca_bundle: kube.Secret("kube-ca-bundle") + $.namespace {
      data_: {
        "ca.crt": importstr "pki/ca.crt",
      },
    },

    // Private CA key and matching (single) certificate
    // kubeadm uses /etc/kubernetes/pki/ca.{crt,key}
    ca: CA("kube-ca", $.namespace.metadata.namespace, $.selfSigner),

    kubernetes_admin: Certificate("kubernetes-admin", $.secrets.ca.issuer) + $.namespace {
      spec+: {
        usages_+: ["client auth"],
        subject+: {organizations: ["system:masters"]},
        duration_h_: 365 * 24 / 2, // 6 months - requires manually copying out the key/cert
      },
    },

    // kubeadm uses /etc/kubernetes/pki/sa.{pub,key}
    // TODO: auto-rotate this. (NB: 'public key' (not cert) is currently unsupported by cert-manager)
    service_account: kube.Secret("kube-service-account") + $.namespace {
      data_: {
        "key.pub": importstr "pki/sa.pub",
        "key.key": importstr "pki/sa.key",
      },
    },

    // CA bundle (ca.crt)
    // kubeadm uses /etc/kubernetes/pki/front-proxy-ca.{crt,key}
    // TODO: I suspect this should be a CA bundle, not a crt/key pair??
    // TODO: unused
    front_proxy_ca: CA("kube-front-proxy-ca", $.namespace.metadata.namespace, $.selfSigner),

    // kubeadm uses /etc/kubernetes/pki/front-proxy-client.{crt,key}
    front_proxy_client: Certificate("kube-front-proxy-client", $.secrets.front_proxy_ca.issuer) + $.namespace {
      spec+: {
        usages_+: ["client auth"],
        commonName: "front-proxy-client",
      },
    },
  },

  kube_proxy: {
    sa: kube.ServiceAccount("kube-proxy") + $.namespace,

    // This duplicates kubeadm:node-proxier
    binding: kube.ClusterRoleBinding("kube-proxy") {
      roleRef: {
        apiGroup: "rbac.authorization.k8s.io",
        kind: "ClusterRole",
        name: "system:node-proxier",
      },
      subjects_: [$.kube_proxy.sa],
    },

    deploy: kube.DaemonSet("kube-proxy") + $.namespace {
      spec+: {
        template+: utils.CriticalPodSpec + utils.PromScrape(10249) {
          spec+: {
            dnsPolicy: "ClusterFirst",
            hostNetwork: true,
            serviceAccountName: $.kube_proxy.sa.metadata.name,
            priorityClassName: "system-node-critical",
            tolerations: utils.toleratesMaster + [{
              effect: "NoSchedule",
              key: "node.cloudprovider.kubernetes.io/uninitialized",
              value: "true",
            }],
            volumes_+: {
              kubeconfig: kube.ConfigMapVolume($.kubeconfig_in_cluster),
              xtables_lock: kube.HostPathVolume("/run/xtables.lock", "FileOrCreate"),
              lib_modules: kube.HostPathVolume("/lib/modules"),
            },
            containers_: {
              kube_proxy: kube.Container("kube-proxy") {
                image: "registry.k8s.io/kube-proxy:%s" % [version],
                command: ["kube-proxy"],
                args_+: {
                  "kubeconfig": "/etc/kubernetes/kubeconfig.conf",
                  "proxy-mode": "ipvs",
                  "cluster-cidr": clusterCidr,
                  "hostname-override": "$(NODE_NAME)",
                  "metrics-bind-address": "$(POD_IP):10249",
                  "healthz-bind-address": "$(POD_IP):10256",
                  feature_gates_:: {
                  },
                  "feature-gates": std.join(",", ["%s=%s" % kv for kv in kube.objectItems(self.feature_gates_)]),
                },
                env_+: {
                  NODE_NAME: kube.FieldRef("spec.nodeName"),
                  POD_IP: kube.FieldRef("status.podIP"),
                  GOGC: "25",
                  GOMEMLIMIT: kube.ResourceFieldRef("requests.memory"),
                },
                ports_+: {
                  metrics: {containerPort: 10249},
                },
                resources+: {
                  requests: {cpu: "20m", memory: "50Mi"},
                },
                securityContext: {
                  privileged: true,
                },
                volumeMounts_+: {
                  kubeconfig: {mountPath: "/etc/kubernetes", readOnly: true},
                  xtables_lock: {mountPath: "/run/xtables.lock"},
                  lib_modules: {mountPath: "/lib/modules", readOnly: true},
                },
                startupProbe: self.livenessProbe {
                  failureThreshold: 10,
                },
                readinessProbe: self.livenessProbe {
                  successThreshold: 1,
                },
                livenessProbe: {
                  httpGet: {path: "/healthz", port: 10256, scheme: "HTTP"},
                  timeoutSeconds: 10,
                  failureThreshold: 3,
                },
              },
            },
          },
        },
      },
    },
  },

  apiserver: {
    // kubeadm uses /etc/kubernetes/pki/etcd-apiserver-client.{crt,key}
    etcdClientCert: Certificate("kube-etcd-apiserver-client", $.etcd.ca.issuer) + $.namespace {
      spec+: {
        usages_+: ["client auth"],
      },
    },

    // kubeadm uses /etc/kubernetes/pki/apiserver.{crt,key}
    servingCert: Certificate("kube-apiserver", $.secrets.ca.issuer) + $.namespace {
      spec+: {
        usages_+: ["server auth"],
        ipAddresses_+: ["127.0.0.1", "10.96.0.1"],
        dnsNames_+: ["kube.lan", "kubernetes", "kubernetes.default", "kubernetes.default.svc", "kubernetes.default.svc.cluster", "kubernetes.default.svc.cluster.local"],
      },
    },

    // kubeadm uses /etc/kubernetes/pki/apiserver-kubelet-client.{crt,key}
    kubeletClientCert: Certificate("kube-apiserver-kubelet-client", $.secrets.ca.issuer) + $.namespace {
      spec+: {
        usages_+: ["client auth"],
        subject+: {organizations: ["system:masters"]},
      },
    },

    pdb: kube.PodDisruptionBudget("apiserver") + $.namespace {
      target_pod: $.apiserver.deploy.spec.template,
      spec+: {minAvailable: 1},
    },

    //pdbInternal: kube.PodDisruptionBudget("apiserver-internal") + $.namespace {
    //  target_pod: $.apiserver.internalDeploy.spec.template,
    //  spec+: {minAvailable: 1},
    //},

    // FIXME: "the HPA was unable to compute the replica count: unable
    // to get metrics for resource cpu: unable to fetch metrics from
    // resource metrics API: the server could not find the requested
    // resource (get pods.metrics.k8s.io)"
    //hpa: kube.HorizontalPodAutoscaler("kube-apiserver") + $.namespace {
    //  target: $.apiserver.internalDeploy,
    //  spec+: {
    //    maxReplicas: 5,
    //  },
    //},

    commonDeploy:: {
      local this = self,
      spec+: {
        template+: utils.CriticalPodSpec {
          spec+: {
            // apiserver is really 'system-cluster-critical', but if we get
            // pre-empted we can end up in a place where the cluster
            // can't recover.  Really we want "don't preempt me."
            priorityClassName: "system-node-critical",

            securityContext+: {
              runAsNonRoot: true,
              runAsUser: 65534,
            },
            automountServiceAccountToken: false,
            tolerations+: bootstrapTolerations,
            volumes_+: {
              kubelet_client: kube.SecretVolume($.apiserver.kubeletClientCert.secret_),
              sa: kube.SecretVolume($.secrets.service_account),
              ca_bundle: kube.SecretVolume($.secrets.ca_bundle),
              fpc: kube.SecretVolume($.secrets.front_proxy_client.secret_),
              tls: kube.SecretVolume($.apiserver.servingCert.secret_),
              etcd_client: kube.SecretVolume($.apiserver.etcdClientCert.secret_),
              etcd_ca_bundle: kube.SecretVolume($.etcd.ca_bundle),

              cacerts: kube.HostPathVolume("/etc/ssl/certs", "DirectoryOrCreate"),
            },
            containers_+: {
              apiserver: kube.Container("apiserver") {
                image: "registry.k8s.io/kube-apiserver:%s" % [apiserverVersion],
                command: ["kube-apiserver"],
                args_+: {
                  feature_gates_:: {
                    DisableCloudProviders: true,
                  },
                  "feature-gates": std.join(",", ["%s=%s" % kv for kv in kube.objectItems(self.feature_gates_)]),
                  "endpoint-reconciler-type": "lease",
                  "enable-bootstrap-token-auth": "true",
                  "kubelet-preferred-address-types": "InternalIP,ExternalIP,Hostname",
                  "enable-admission-plugins": "NodeRestriction",
                  "anonymous-auth": "true", // needed for healthchecks. TODO: change healthchecks.
                  "profiling": "false",
                  "allow-privileged": "true",
                  "service-cluster-ip-range": serviceClusterCidr,
                  "secure-port": "6443",
                  "authorization-mode": "Node,RBAC",
                  "tls-min-version": "VersionTLS12",
                  "tls-cipher-suites": "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_RSA_WITH_AES_256_GCM_SHA384,TLS_RSA_WITH_AES_128_GCM_SHA256",

                  // This is arguably a bad idea, but solves one
                  // symptom with checkpointed apiserver pods
                  // fighting with regular pods.
                  "permit-address-sharing": "true",

                  "etcd-servers": std.join(",", [
                    "https://%s:2379" % etcdMembers[k] for k in std.objectFields(etcdMembers)
                    if !std.setMember(k, etcdLearners)
                  ]),

                  "advertise-address": "$(POD_IP)",
                  "external-hostname": externalHostname,

                  "etcd-healthcheck-timeout": "20s", // default 2s
                  "etcd-count-metric-poll-period": "10m", // default 1m
                  "request-timeout": "5m",
                  "shutdown-delay-duration": "%ds" % (this.spec.template.spec.terminationGracePeriodSeconds - 5),
                  "max-requests-inflight": "150", // ~15 per 25-30 pods, default 400

                  "kubelet-client-certificate": "/keys/apiserver-kubelet-client/tls.crt",
                  "kubelet-client-key": "/keys/apiserver-kubelet-client/tls.key",
                  "service-account-issuer": "https://%s:%s" % [self["external-hostname"], self["secure-port"]],
                  "service-account-key-file": "/keys/sa/key.pub",
                  "service-account-signing-key-file": "/keys/sa/key.key",
                  "client-ca-file": "/keys/ca-bundle/ca.crt",
                  "proxy-client-cert-file": "/keys/front-proxy-client/tls.crt",
                  "proxy-client-key-file": "/keys/front-proxy-client/tls.key",
                  "tls-cert-file": "/keys/apiserver/tls.crt",
                  "tls-private-key-file": "/keys/apiserver/tls.key",
                  "etcd-cafile": "/keys/etcd-ca/ca.crt",
                  "etcd-certfile": "/keys/etcd-apiserver-client/tls.crt",
                  "etcd-keyfile": "/keys/etcd-apiserver-client/tls.key",

                  "requestheader-extra-headers-prefix": "X-Remote-Extra-",
                  requestheader_allowed_names_:: [$.secrets.front_proxy_client.spec.commonName],
                  "requestheader-allowed-names": std.join(",", std.set(self.requestheader_allowed_names_)),
                  "requestheader-username-headers": "X-Remote-User",
                  "requestheader-group-headers": "X-Remote-Group",
                  "requestheader-client-ca-file": "/keys/front-proxy-client/ca.crt",

                  runtime_config_:: {
                    // Workaround old coreos update-operator code.
                    // https://github.com/coreos/container-linux-update-operator/issues/196
                    "extensions/v1beta1/daemonsets": true,
                    // Old rook-ceph version
                    "batch/v1beta1": true,
                    "policy/v1beta1": true,
                  },
                  "runtime-config": std.join(",", ["%s=%s" % kv for kv in kube.objectItems(self.runtime_config_)]),
                },
                env_+: {
                  POD_IP: kube.FieldRef("status.podIP"),
                  GOGC: "25",
                  GOMEMLIMIT: kube.ResourceFieldRef("requests.memory"),
                },
                ports_+: {
                  https: {containerPort: 6443, protocol: "TCP"},
                },
                livenessProbe: {
                  httpGet: {path: "/livez", port: 6443, scheme: "HTTPS"},
                  failureThreshold: 10,
                  periodSeconds: 30,
                  successThreshold: 1,
                  timeoutSeconds: 20,
                },
                startupProbe: self.livenessProbe {
                  failureThreshold: std.ceil(600 / self.periodSeconds),
                },
                readinessProbe: self.livenessProbe {
                  httpGet+: {path: "/readyz"},
                  failureThreshold: 2,
                  initialDelaySeconds: 120,
                  successThreshold: 3,
                },
                resources+: {
                  requests: {cpu: "800m", memory: "400Mi"},
                },
                volumeMounts_+: {
                  kubelet_client: {mountPath: "/keys/apiserver-kubelet-client", readOnly: true},
                  sa: {mountPath: "/keys/sa", readOnly: true},
                  ca_bundle: {mountPath: "/keys/ca-bundle", readOnly: true},
                  fpc: {mountPath: "/keys/front-proxy-client", readOnly: true},
                  tls: {mountPath: "/keys/apiserver", readOnly: true},
                  etcd_ca_bundle: {mountPath: "/keys/etcd-ca", readOnly: true},
                  etcd_client: {mountPath: "/keys/etcd-apiserver-client", readOnly: true},
                  cacerts: {mountPath: "/etc/ssl/certs", readOnly: true},
                },
              },
            },
          },
        },
      },
    },

    //internalDeploy: kube.Deployment("kube-apiserver-internal") + $.namespace + $.apiserver.commonDeploy {
    //  spec+: {
    //    replicas: 1,
    //  },
    //},

    deploy: kube.Deployment("kube-apiserver") + $.namespace + $.apiserver.commonDeploy {
      local this = self,
      spec+: {
        replicas: 2,
        template+: checkpoint {
          spec+: {
            hostNetwork: true,
            dnsPolicy: "ClusterFirstWithHostNet",
            // Moved to a nodeAffinity rule, to workaround a limitation
            // with pod-checkpointer (or arguably kubelet).
            //nodeSelector+: {"node-role.kubernetes.io/control-plane": ""},
            affinity+: {
              nodeAffinity+: {
                requiredDuringSchedulingIgnoredDuringExecution+: {
                  nodeSelectorTerms: andTerm(
                    super.nodeSelectorTerms,
                    if isolateMasters then
                      labelSelector({
                        "node-role.kubernetes.io/control-plane": "",
                      })
                    else
                      labelSelector({
                        "apiserver": "true",
                      })
                  ),
                },
              },
              podAntiAffinity+: {
                requiredDuringSchedulingIgnoredDuringExecution+: [{
                  labelSelector: labelSelector(this.spec.template.metadata.labels),
                  topologyKey: "kubernetes.io/hostname",
                }],
              },
            },
            tolerations+: utils.toleratesMaster + [{
              effect: "NoSchedule",
              key: "node.cloudprovider.kubernetes.io/uninitialized",
              value: "true",
            }],
          },
        },
      },
    },
  },

  controller_manager: {
    pdb: kube.PodDisruptionBudget("kube-controller-manager") + $.namespace {
      target_pod: $.controller_manager.deploy.spec.template,
      spec+: {minAvailable: 1},
    },

    // Already bound to system::leader-locking-kube-controller-manager
    sa: kube.ServiceAccount("kube-controller-manager") + $.namespace,

    // This duplicates bindings for user system:kube-controller-manager
    binding: kube.ClusterRoleBinding("kube-controller-manager") {
      roleRef: {
        apiGroup: "rbac.authorization.k8s.io",
        kind: "ClusterRole",
        name: "system:kube-controller-manager",
      },
      subjects_: [$.controller_manager.sa],
    },

    deploy: kube.Deployment("kube-controller-manager") + $.namespace {
      local this = self,
      spec+: {
        replicas: 2,
        template+: utils.CriticalPodSpec {
          spec+: {
            affinity+: {
              podAntiAffinity: {
                requiredDuringSchedulingIgnoredDuringExecution: [{
                  labelSelector: labelSelector(this.spec.template.metadata.labels),
                  topologyKey: "kubernetes.io/hostname",
                }],
              },
            },
            serviceAccountName: $.controller_manager.sa.metadata.name,
            [if isolateMasters then "nodeSelector"]+: {"node-role.kubernetes.io/control-plane": ""},
            tolerations+: utils.toleratesMaster + bootstrapTolerations,
            securityContext+: {
              runAsNonRoot: true,
              runAsUser: 65534,
            },
            volumes_+: {
              varrunkubernetes: kube.EmptyDirVolume(),
              cacerts: kube.HostPathVolume("/etc/ssl/certs", "DirectoryOrCreate"),
              flexvolume: kube.HostPathVolume("/var/lib/kubelet/volumeplugins", "DirectoryOrCreate"),
              ca: kube.SecretVolume($.secrets.ca.cert.secret_),
              ca_bundle: kube.SecretVolume($.secrets.ca_bundle),
              sa: kube.SecretVolume($.secrets.service_account),
            },
            containers_+: {
              cm: kube.Container("controller-manager") {
                image: "registry.k8s.io/kube-controller-manager:%s" % [version],
                command: ["kube-controller-manager"],
                args_+: {
                  "profiling": "false",
                  "use-service-account-credentials": "true",
                  "leader-elect": "true",
                  "leader-elect-resource-lock": "leases",

                  feature_gates_:: {
                    DisableCloudProviders: true,
                  },
                  "feature-gates": std.join(",", ["%s=%s" % kv for kv in kube.objectItems(self.feature_gates_)]),

                  "controllers": "*,bootstrapsigner,tokencleaner",
                  "allocate-node-cidrs": "true",
                  "node-cidr-mask-size-ipv4": 24,
                  "node-cidr-mask-size-ipv6": 80,
                  "cluster-cidr": clusterCidr,
                  "service-cluster-ip-range": serviceClusterCidr,
                  "terminated-pod-gc-threshold": "100", // default is massive 12500
                  //"cloud-provider"

                  // Reduce leader-elect load
                  "leader-elect-lease-duration": "300s", // default 15s
                  "leader-elect-renew-deadline": "270s", // default 10s
                  "leader-elect-retry-period": "20s", // default 2s

                  "root-ca-file": "/keys/ca_bundle/ca.crt",
                  "service-account-private-key-file": "/keys/sa/key.key",
                  // cluster-signing-cert-file must be a single key, unlike --root-ca-file
                  // TODO: should use an intermediate CA for this, to reduce CA key exposure
                  "cluster-signing-cert-file": "/keys/ca/tls.crt",
                  "cluster-signing-key-file": "/keys/ca/tls.key",
                },
                env_+: {
                  GOGC: "25",
                  GOMEMLIMIT: kube.ResourceFieldRef("requests.memory"),
                },
                livenessProbe: {
                  httpGet: {path: "/healthz", port: 10257, scheme: "HTTPS"},
                  timeoutSeconds: 20,
                  periodSeconds: 30,
                },
                startupProbe: self.livenessProbe {
                  failureThreshold: std.ceil(600 / self.periodSeconds),
                },
                readinessProbe: self.livenessProbe {
                  successThreshold: 3,
                },
                volumeMounts_+: {
                  ca: {mountPath: "/keys/ca", readOnly: true},
                  ca_bundle: {mountPath: "/keys/ca_bundle", readOnly: true},
                  sa: {mountPath: "/keys/sa", readOnly: true},
                  cacerts: {mountPath: "/etc/ssl/certs", readOnly: true},
                  flexvolume: {mountPath: "/usr/libexec/kubernetes/kubelet-plugins/volume/exec", readOnly: true},
                  varrunkubernetes: {mountPath: "/var/run/kubernetes"},
                },
                resources+: {
                  requests: {cpu: "50m", memory: "80Mi"},
                },
              },
            },
          },
        },
      },
    },
  },

  scheduler: {
    pdb: kube.PodDisruptionBudget("kube-scheduler") + $.namespace {
      target_pod: $.scheduler.deploy.spec.template,
      spec+: {minAvailable: 1},
    },

    // Already bound to system::leader-locking-kube-scheduler
    sa: kube.ServiceAccount("kube-scheduler") + $.namespace,

    // This duplicates bindings for user system:kube-scheduler
    binding: kube.ClusterRoleBinding("kube-scheduler") {
      roleRef: {
        apiGroup: "rbac.authorization.k8s.io",
        kind: "ClusterRole",
        name: "system:kube-scheduler",
      },
      subjects_: [$.scheduler.sa],
    },
    volumebinding: kube.ClusterRoleBinding("kube-volume-scheduler") {
      roleRef: {
        apiGroup: "rbac.authorization.k8s.io",
        kind: "ClusterRole",
        name: "system:volume-scheduler",
      },
      subjects_: [$.scheduler.sa],
    },
    authreader: kube.RoleBinding("extension-apiserver-authentication-reader") + $.namespace {
      roleRef: {
        apiGroup: "rbac.authorization.k8s.io",
        kind: "Role",
        name: "extension-apiserver-authentication-reader",
      },
      subjects_: [$.scheduler.sa, $.controller_manager.sa],
    },

    deploy: kube.Deployment("kube-scheduler") + $.namespace {
      local this = self,
      spec+: {
        replicas: 2,
        template+: utils.CriticalPodSpec {
          spec+: {
            affinity+: {
              podAntiAffinity: {
                requiredDuringSchedulingIgnoredDuringExecution: [{
                  labelSelector: labelSelector(this.spec.template.metadata.labels),
                  topologyKey: "kubernetes.io/hostname",
                }],
              },
            },
            tolerations+: utils.toleratesMaster + bootstrapTolerations,
            [if isolateMasters then "nodeSelector"]+: {"node-role.kubernetes.io/control-plane": ""},
            serviceAccountName: $.scheduler.sa.metadata.name,
            containers_+: {
              scheduler: kube.Container("scheduler") {
                image: "registry.k8s.io/kube-scheduler:%s" % [version],
                command: ["kube-scheduler"],
                args_+: {
                  "profiling": "false",

                  "leader-elect": "true",
                  "leader-elect-resource-lock": "leases",

                  // Reduce leader-elect load
                  "leader-elect-lease-duration": "300s", // default 15s
                  "leader-elect-renew-deadline": "270s", // default 10s
                  "leader-elect-retry-period": "20s", // default 2s
                },
                env_+: {
                  GOGC: "25",
                  GOMEMLIMIT: kube.ResourceFieldRef("requests.memory"),
                },
                livenessProbe: {
                  httpGet: {path: "/healthz", port: 10259, scheme: "HTTPS"},
                  timeoutSeconds: 20,
                  periodSeconds: 30,
                },
                startupProbe: self.livenessProbe {
                  failureThreshold: std.ceil(600 / self.periodSeconds),
                },
                readinessProbe: self.livenessProbe {
                  successThreshold: 3,
                },
                securityContext+: {
                  runAsNonRoot: true,
                  runAsUser: 65534,
                },
                resources+: {
                  requests: {cpu: "10m", memory: "40Mi"},
                },
              },
            },
          },
        },
      },
    },
  },

  checkpointer: {
    sa: kube.ServiceAccount("pod-checkpointer") + $.namespace,

    role: kube.Role("pod-checkpointer") + $.namespace {
      rules: [
        {
          apiGroups: [""],
          resources: ["pods"],
          verbs: ["get", "watch", "list"],
        },
        {
          apiGroups: [""],
          resources: ["secrets", "configmaps"],
          verbs: ["get"],
        },
      ],
    },

    rolebinding: kube.RoleBinding("pod-checkpointer") + $.namespace {
      roleRef_: $.checkpointer.role,
      subjects_+: [$.checkpointer.sa],
    },

    saToken: kube.Secret("pod-checkpointer-token") + $.namespace {
      metadata+: {
        annotations+: {
          "kubernetes.io/service-account.name": $.checkpointer.sa.metadata.name,
        },
      },
      type: "kubernetes.io/service-account-token",
    },

    deploy: kube.DaemonSet("pod-checkpointer") + $.namespace {
      spec+: {
        template+: checkpoint {
          spec+: {
            // Note: avoid using projected serviceaccount tokens -
            // pod-checkpointer does not know how to checkpoint them.
            // TODO: this pod should probably use kubelet
            // credentials, but last time I tried they were not
            // sufficient (?)
            automountServiceAccountToken: false,
            hostNetwork: true,
            tolerations+: utils.toleratesMaster + bootstrapTolerations,
            // Moved to a nodeAffinity rule, to workaround a limitation
            // with pod-checkpointer (or arguably kubelet).
            //nodeSelector+: {"node-role.kubernetes.io/control-plane": ""},
            affinity+: {
              // Harmless to run everywhere, but only necessary
              // wherever checkpointed (apiserver) jobs are running
              [if isolateMasters then "nodeAffinity"]+: {
                requiredDuringSchedulingIgnoredDuringExecution+: {
                  nodeSelectorTerms: andTerm(
                    super.nodeSelectorTerms,
                    labelSelector({
                      "node-role.kubernetes.io/control-plane": "",
                    })),
                },
              },
            },
            volumes_+: {
              etc_k8s: kube.HostPathVolume("/etc/kubernetes", "Directory"),
              kubeconfig: kube.ConfigMapVolume($.kubeconfig_in_cluster),
              token: kube.SecretVolume($.checkpointer.saToken),
              var_run: kube.HostPathVolume("/run", "Directory"), // TODO: expose only /run/containerd/containerd.sock and lock path
            },
            containers_+: {
              checkpointer: kube.Container("checkpointer") {
                image: "registry.gitlab.com/anguslees/docker-bootkube-checkpoint:v0-14-0", // renovate
                command: ["checkpoint"],
                args_+: {
                  "lock-file": "/var/run/lock/pod-checkpointer.lock",
                  kubeconfig: "/etc/checkpointer/kubeconfig.conf",
                  "checkpoint-grace-period": "5m",
                  "container-runtime-endpoint": "unix:///run/containerd/containerd.sock",
                },
                env_+: {
                  NODE_NAME: kube.FieldRef("spec.nodeName"),
                  POD_NAME: kube.FieldRef("metadata.name"),
                  POD_NAMESPACE: kube.FieldRef("metadata.namespace"),
                  GOGC: "25",
                  GOMEMLIMIT: kube.ResourceFieldRef("requests.memory"),
                },
                volumeMounts_+: {
                  kubeconfig: {
                    mountPath: "/etc/checkpointer",
                    readOnly: true,
                  },
                  token: {
                    mountPath: "/var/run/secrets/kubernetes.io/serviceaccount",
                    readOnly: true,
                  },
                  etc_k8s: {mountPath: "/etc/kubernetes"},
                  var_run: {mountPath: "/var/run"},
                },
              },
            },
          },
        },
      },
    },
  },

  coreDNS: {
    sa: kube.ServiceAccount("coredns") + $.namespace,

    role: kube.ClusterRole("system:coredns") {
      metadata+: {
        labels+: {"kubernetes.io/bootstrapping": "rbac-defaults"},
        annotations+: {"rbac.authorization.kubernetes.io/autoupdate": "true"},
      },
      rules: [
        {
          apiGroups: [""],
          resources: ["endpoints", "services", "pods", "namespaces"],
          verbs: ["list", "watch"],
        },
        {
          apiGroups: ["discovery.k8s.io"],
          resources: ["endpointslices"],
          verbs: ["list", "watch"],
        },
      ],
    },

    binding: kube.ClusterRoleBinding("system:coredns") {
      metadata+: {
        labels+: {"kubernetes.io/bootstrapping": "rbac-defaults"},
        annotations+: {"rbac.authorization.kubernetes.io/autoupdate": "true"},
      },
      roleRef_: $.coreDNS.role,
      subjects_+: [$.coreDNS.sa],
    },

    config: utils.HashedConfigMap("coredns") + $.namespace {
      data+: {
        Corefile: |||
          .:53 {
            errors
            health {
              lameduck 40s
            }
            ready
            log
            kubernetes %(dnsDomain)s in-addr.arpa ip6.arpa {
              fallthrough in-addr.arpa ip6.arpa
            }
            prometheus :9153
            forward . /etc/resolv.conf {
              max_concurrent 1000
            }
            cache 30
            loop
            loadbalance
            # Note no 'reload' since we use HashedConfigMap
          }
        ||| % {dnsDomain: dnsDomain},
      },
    },

    svc: kube.Service("coredns") + $.namespace {
      metadata+: {
        labels+: {
          "kubernetes.io/name": "CoreDNS",
          "kubernetes.io/cluster-service": "true",
        },
      },
      target_pod: $.coreDNS.deploy.spec.template,
      spec+: {
        clusterIP: dnsIP,
        ports: [
          {name: "dns", port: 53, protocol: "UDP"},
          {name: "dnstcp", port: 53, protocol: "TCP"},
        ],
      },
    },

    deploy: kube.Deployment("coredns") + $.namespace {
      spec+: {
        replicas: 2,
        template+: utils.PromScrape(9153) {
          metadata+: {
            annotations+: {
              //"seccomp.security.alpha.kubernetes.io/pod": "docker/default",
            },
          },
          spec+: {
            serviceAccountName: $.coreDNS.sa.metadata.name,
            tolerations+: utils.toleratesMaster,
            dnsPolicy: "Default",
            // NB: lameduck is set to 40s above.
            local p = self.containers_.coredns.livenessProbe,
            local lameduck = 40,
            assert p.periodSeconds * p.failureThreshold < lameduck,
            assert lameduck < self.terminationGracePeriodSeconds,
            terminationGracePeriodSeconds: 60,
            volumes_+: {
              config: kube.ConfigMapVolume($.coreDNS.config) {
                configMap+: {
                  items+: [{key: "Corefile", path: "Corefile"}],
                },
              },
            },
            containers_+: {
              coredns: kube.Container("coredns") {
                image: "registry.k8s.io/coredns:1.7.0", // renovate
                resources+: {
                  limits: {memory: "170Mi"},
                  requests: {cpu: "50m", memory: "30Mi"},
                },
                args_+: {
                  conf: "/etc/coredns/Corefile",
                },
                env_+: {
                  GOGC: "25",
                  GOMEMLIMIT: kube.ResourceFieldRef("requests.memory"),
                },
                volumeMounts_+: {
                  config: {mountPath: "/etc/coredns", readOnly: true},
                },
                ports_+: {
                  dns: {containerPort: 53, protocol: "UDP"},
                  dnstcp: {containerPort: 53, protocol: "TCP"},
                  metrics: {containerPort: 9153, protocol: "TCP"},
                },
                livenessProbe: {
                  httpGet: {path: "/health", port: 8080, scheme: "HTTP"},
                  initialDelaySeconds: 60,
                  timeoutSeconds: 5,
                  periodSeconds: 10,
                  successThreshold: 1,
                  failureThreshold: 3,
                },
                startupProbe: self.livenessProbe {
                  failureThreshold: std.ceil(300 / self.periodSeconds),
                },
                readinessProbe: self.livenessProbe {
                  httpGet: {path: "/ready", port: 8181, scheme: "HTTP"},
                  successThreshold: 1,
                },
                securityContext: {
                  allowPrivilegeEscalation: false,
                  capabilities: {
                    add+: ["NET_BIND_SERVICE"],
                    drop+: ["all"],
                  },
                  readOnlyRootFilesystem: true,
                },
              },
            },
          },
        },
      },
    },
  },

  // https://github.com/kubernetes-incubator/metrics-server
  metrics: {
    local arch = "amd64",

    serviceAccount: kube.ServiceAccount("metrics-server") + $.namespace,

    clusterRoleBinding: kube.ClusterRoleBinding("metrics-server:system:auth-delegator") {
      roleRef: {
        apiGroup: "rbac.authorization.k8s.io",
        kind: "ClusterRole",
        name: "system:auth-delegator",
      },
      subjects_+: [$.metrics.serviceAccount],
    },

    metricsReaderRole: kube.ClusterRole("system:aggregated-metrics-reader") {
      metadata+: {
        labels+: {
          "rbac.authorization.k8s.io/aggregate-to-view": "true",
          "rbac.authorization.k8s.io/aggregate-to-edit": "true",
          "rbac.authorization.k8s.io/aggregate-to-admin": "true",
        },
      },
      rules: [
        {
          apiGroups: ["metrics.k8s.io"],
          resources: ["pods", "nodes"],
          verbs: ["get", "list", "watch"],
        },
      ],
    },

    roleBinding: kube.RoleBinding("metrics-server-auth-reader") + $.namespace {
      roleRef: {
        apiGroup: "rbac.authorization.k8s.io",
        kind: "Role",
        name: "extension-apiserver-authentication-reader",
      },
      subjects_+: [$.metrics.serviceAccount],
    },

    metricsRole: kube.ClusterRole("system:metrics-server") {
      rules: [
        {
          apiGroups: [""],
          resources: ["pods", "nodes", "nodes/stats", "namespaces"],
          verbs: ["get", "list", "watch"],
        },
      ],
    },

    metricsRoleBinding: kube.ClusterRoleBinding("system:metrics-server") {
      roleRef_: $.metrics.metricsRole,
      subjects_+: [$.metrics.serviceAccount],
    },

    svc: kube.Service("metrics-server") + $.namespace {
      metadata+: {
        labels+: {"kubernetes.io/name": "Metrics-server"},
      },
      target_pod: $.metrics.deploy.spec.template,
      port: 443,
    },

    deploy: kube.Deployment("metrics-server") + $.namespace {
      spec+: {
        template+: {
          spec+: {
            nodeSelector+: utils.archSelector(arch),
            serviceAccountName: $.metrics.serviceAccount.metadata.name,
            volumes_+: {
              tmp: kube.EmptyDirVolume(),
              fp_ca: kube.SecretVolume($.secrets.front_proxy_client.secret_) {
                secret+: {
                  items: [
                    {key: "ca.crt", path: self.key}, // public cert only
                  ],
                },
              },
            },
            containers_+: {
              default: kube.Container("metrics-server") {
                image: "registry.k8s.io/metrics-server/metrics-server:v0.6.4", // renovate
                command: ["/metrics-server"],
                args_+: {
                  "logtostderr": "true",
                  "v": "1",
                  "secure-port": "8443",
                  "cert-dir": "/tmp/certificates",
                  "kubelet-preferred-address-types": "InternalIP",
                  "kubelet-insecure-tls": "true",  // FIXME
                  "requestheader-client-ca-file": "/keys/front-proxy-ca/ca.crt",
                  requestheader_allowed_names_:: [$.secrets.front_proxy_client.spec.commonName],
                  "requestheader-allowed-names": std.join(",", std.set(self.requestheader_allowed_names_)),
                },
                env_+: {
                  GOGC: "25",
                  GOMEMLIMIT: kube.ResourceFieldRef("requests.memory"),
                },
                ports_+: {
                  https: {containerPort: 8443, protocol: "TCP"},
                },
                securityContext+: {
                  runAsNonRoot: true,
                  runAsUser: 65534,
                  readOnlyRootFilesystem: true,
                  allowPrivilegeEscalation: false,
                },
                resources: {
                  requests: {cpu: "10m", memory: "25Mi"},
                },
                livenessProbe: {
                  httpGet: {path: "/livez", port: 8443, scheme: "HTTPS"},
                  failureThreshold: 10,
                  periodSeconds: 30,
                  successThreshold: 1,
                  timeoutSeconds: 20,
                },
                startupProbe: self.livenessProbe {
                  failureThreshold: std.ceil(120 / self.periodSeconds),
                },
                readinessProbe: self.livenessProbe {
                  httpGet+: {path: "/readyz"},
                  failureThreshold: 2,
                  successThreshold: 3,
                },
                volumeMounts_+: {
                  tmp: {mountPath: "/tmp"},
                  fp_ca: {mountPath: "/keys/front-proxy-ca", readOnly: true},
                },
              },
            },
          },
        },
      },
    },

    apiSvc: kube._Object("apiregistration.k8s.io/v1", "APIService", "v1beta1.metrics.k8s.io") {
      spec+: {
        service: {
          name: $.metrics.svc.metadata.name,
          namespace: $.metrics.svc.metadata.namespace,
        },
        group: "metrics.k8s.io",
        version: "v1beta1",
        insecureSkipTLSVerify: true,  // FIXME
        groupPriorityMinimum: 100,
        versionPriority: 100,
      },
    },
  },

  // Not actually deployed through this file (see
  // coreos-pxe-install.jsonnet), but it makes sense to define the
  // 'base' config here.
  kubelet: {
    local vs = std.split(std.lstripChars(version, "v"), "."),
    local v = vs[0] + "." + vs[1],
    config: kube.ConfigMap("kubelet-config-" + v) + $.namespace {
      metadata+: {
        annotations+: {
          // Don't garbage collect these configmaps
          "kubecfg.ksonnet.io/garbage-collect-strategy": "ignore",
        },
      },
      data: {
        "config.yaml": kubecfg.manifestYaml(self.config),
        config:: {
          // See https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
          apiVersion: "kubelet.config.k8s.io/v1beta1",
          kind: "KubeletConfiguration",

          // No kubelet config var for this?
          // "cert-dir": "/var/lib/kubelet/pki",

          // Kind of needs to be set in a drop-in:
            //"hostname-override": "%m",
          //"kubeconfig": "/etc/kubernetes/kubelet.conf",
          //"bootstrap-kubeconfig": "/etc/kubernetes/bootstrap-kubelet.conf",

          staticPodPath: "/etc/kubernetes/manifests",
          syncFrequency: "5m",

          logging: {format: "text"},
          enableSystemLogHandler: false,
          enableProfilingHandler: false,
          enableDebugFlagsHandler: false,

          shutdownGracePeriod: "90s",

          tlsCipherSuites: std.set([
            "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256",
            "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
            "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305",
            "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
            "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305",
            "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
            "TLS_RSA_WITH_AES_256_GCM_SHA384",
            "TLS_RSA_WITH_AES_128_GCM_SHA256",
          ]),
          tlsMinVersion: "VersionTLS12",

          rotateCertificates: true,
          serverTLSBootstrap: true,
          authentication: {
            anonymous: {enabled: false},
            webhook: {
              enabled: true, // FIXME: bearer tokens for kubelet are not good.
              cacheTTL: "5m",
            },
            x509: {
              clientCAFile: "/var/lib/kubelet/pki/kube-ca/ca.crt",
            },
          },
          authorization: {
            mode: "Webhook",
            webhook: {
              cacheAuthorizedTTL: "5m",
              cacheUnauthorizedTTL: "1m",
            },
          },
          // Defaults, I should actually use this in coreos-pxe-install daemonset
          //healthzBindAddress: "127.0.0.1",
          //healthzPort: 10248,

          clusterDomain: dnsDomain,
          clusterDNS: [dnsIP],

          runtimeRequestTimeout: "10m", // default: 2m

          podPidsLimit: 10000,

          serializeImagePulls: false,

          eviction_:: {
            "nodefs.available": {
              hard: "1Gi", // default 10%
              soft: "2Gi",
              minimum_reclaim: "500Mi",
              soft_grace_period: "2m",
            },
            "imagefs.available": {
              hard: "2Gi", // default 15%
              soft: "3Gi",
              minimum_reclaim: "1Gi",
              soft_grace_period: "2m",
            },
            "nodefs.inodesFree": {
              hard: "5%",
            },
            "memory.available": {
              hard: "0%", // default 100Mi
            },
          },
          local manifestEviction(key) = {
            [kv[0]]: kv[1][key] for kv in kube.objectItems(self.eviction_)
            if std.objectHas(kv[1], key)
          },
          evictionHard: manifestEviction("hard"),
          evictionSoft: manifestEviction("soft"),
          evictionSoftGracePeriod: manifestEviction("soft_grace_period"),
          evictionMinimumReclaim: manifestEviction("minimum_reclaim"),
          evictionPressureTransitionPeriod: "5m",

          featureGates: {
            NodeSwap: true,
            DisableCloudProviders: true,
          },

          failSwapOn: false,
          memorySwap: {swapBehavior: "UnlimitedSwap"},

          cgroupRoot: "/",
          cgroupDriver: "systemd",

          kernelMemcgNotification: true,
          kubeReservedCgroup: "/podruntime.slice",
          kubeReserved: { // NB: not enforced
            cpu: "100m",
            memory: "256Mi",
            "ephemeral-storage": "256Mi",
            pid: "100",
          },
          systemReservedCgroup: "/system.slice",
          systemReserved: {  // NB: not enforced
            cpu: "10m",
            memory: "100Mi",
            "ephemeral-storage": "500Mi",
            pid: "1000",
          },

          allowedUnsafeSysctls: ["net.core.rmem_*"],

          volumePluginDir: "/var/lib/kubelet/volumeplugins",
        },
      },
    },
  },

  defaultPrioClass: kube._Object("scheduling.k8s.io/v1", "PriorityClass", "default") {
    value: 1000,
    globalDefault: true,
    description: "Default priority class",
  },

  hiPrioClass: kube._Object("scheduling.k8s.io/v1", "PriorityClass", "high") {
    value: 10000,
    globalDefault: false,
    description: "Priority class for pods that 'should' run, but are not cluster-critical",
  },

  batchPrioClass: kube._Object("scheduling.k8s.io/v1", "PriorityClass", "batch") {
    value: 900,
    preemptionPolicy: "Never",
    globalDefault: false,
    description: "Non-preempting priority class - for tasks that can wait",
  },
}
