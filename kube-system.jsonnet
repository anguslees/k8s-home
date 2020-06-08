// kubeadm is dead to me :(
// (not true: I use kubeadm to join nodes, but from there it's self-hosted via this file)
//
// https://github.com/kubernetes/kubeadm/issues/413
// https://github.com/kubernetes/enhancements/issues/415#issuecomment-409989216
//

local kube = import "kube.libsonnet";
local kubecfg = import "kubecfg.libsonnet";
local utils = import "utils.libsonnet";

// NB: Kubernetes (minor semver) upgrade order is:
// 1. apiserver first
// 2. rest of control plane
// 3. kubelets (see coreos-pxe-install.jsonnet:coreos_kubelet_tag)
local apiserverVersion = "v1.18.3";
local version = "v1.18.3";

local externalHostname = "kube.lan";
local apiServer = "https://%s:6443" % [externalHostname];
local clusterCidr = "10.244.0.0/16";
local serviceClusterCidr = "10.96.0.0/12";
local dnsIP = "10.96.0.10";
local dnsDomain = "cluster.local";

// NB: these IPs are also burnt into the peer/server certificates,
// because of the golang TLS verification wars.
local etcdMembers = {
  "e5b2509083d942b5909c7b32e0460c54": "192.168.0.102",
  "fc4698cdc1184810a2c3447a7ee66689": "192.168.0.129",
  "0b5642a6cc18493d81a606483d9cbb7b": "192.168.0.132",
};

local isolateMasters = false;

local labelSelector(labels) = {
  matchExpressions: [
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

// Inspiration:
//  https://github.com/kubernetes/kubeadm/blob/master/docs/design/design_v1.10.md
//  https://github.com/kubernetes-incubator/bootkube/blob/master/pkg/asset/internal/templates.go

{
  namespace:: {
    metadata+: { namespace: "kube-system" },
  },

  etcd: {
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
        replicas: 3,
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
        template+: utils.CriticalPodSpec + utils.PromScrape(2381) {
          metadata+: {
            annotations+: {
              "checkpointer.alpha.coreos.com/checkpoint": "true",
            },
          },
          spec+: {
            hostNetwork: true,
            dnsPolicy: "ClusterFirstWithHostNet",
            tolerations+: utils.toleratesMaster + bootstrapTolerations,
            automountServiceAccountToken: false,
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
              etcd_ca: kube.SecretVolume($.secrets.etcd_ca),
              etcd_server: kube.SecretVolume($.secrets.etcdServerKey),
              etcd_peer: kube.SecretVolume($.secrets.etcdPeerKey),
              etcd_client: kube.SecretVolume($.secrets.etcdMonitorKey),
            },
            affinity+: {
              nodeAffinity: {
                requiredDuringSchedulingIgnoredDuringExecution+: {
                  nodeSelectorTerms: [
                    labelSelector(utils.archSelector("amd64")) + {
                      matchExpressions+: [
                        {
                          key: "kubernetes.io/hostname",
                          operator: "In",
                          values: std.objectFields(etcdMembers),
                        },
                      ],
                    },
                  ],
                },
              },
              podAntiAffinity: {
                requiredDuringSchedulingIgnoredDuringExecution: [{
                  labelSelector: labelSelector(this.spec.template.metadata.labels),
                  topologyKey: "kubernetes.io/hostname",
                }],
              },
            },
            containers_+: {
              etcd: kube.Container("etcd") {
                image: "gcr.io/etcd-development/etcd:v3.4.7",
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
                  "peer-client-cert-auth": true,
                  "peer-cert-allowed-cn": "etcd.local",
                  "peer-trusted-ca-file": "/keys/etcd-ca/ca.crt",
                  "listen-peer-urls": "https://$(POD_IP):2380",
                  "client-cert-auth": true,
                  "trusted-ca-file": "/keys/etcd-ca/ca.crt",
                  "election-timeout": "10000",
                  "heartbeat-interval": "1000",
                  "listen-metrics-urls": "http://0.0.0.0:2381",
                },
                env_+: {
                  ETCD_NAME: kube.FieldRef("spec.nodeName"),
                  POD_IP: kube.FieldRef("status.podIP"),
                  ETCDCTL_API: "3",
                  ETCDCTL_CACERT: "/keys/etcd-ca/ca.crt",
                  ETCDCTL_CERT: "/keys/etcd-client/tls.crt",
                  ETCDCTL_KEY: "/keys/etcd-client/tls.key",
                  GOGC: "25",
                },
                livenessProbe: {
                  local probe = self,
                  // Looks like /health fails if endpoint is out of quorum :(
                  //httpGet: {path: "/health", port: 2381, scheme: "HTTP"},
                  exec: {
                    etcdctl_args:: ["endpoint", "status"],
                    command: [
                      "etcdctl",
                      "--dial-timeout=5s",
                      "--command-timeout=%ds" % probe.timeoutSeconds,
                      "--endpoints=https://127.0.0.1:2379",
                      // "certificate is valid for 192.168.0.129, not 127.0.0.1"
                      // We don't care, since we trust 127.0.0.1.
                      "--insecure-skip-tls-verify",
                    ] + self.etcdctl_args,
                  },
                  failureThreshold: 8,
                  initialDelaySeconds: 180,
                  timeoutSeconds: 15,
                  periodSeconds: 30,
                },
                readinessProbe: self.livenessProbe {
                  exec+: {
                    etcdctl_args: ["endpoint", "health"],
                  },
                  failureThreshold: 3,
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
                  requests: self.limits {memory: "400Mi"},
                },
                // lifecycle+: {
                //   local etcdctl = [
                //     "etcdctl",
                //     "--endpoints=https://etcd:2379",
                //     "--cacert=/keys/etcd-ca.pem",
                //     "--cert=/keys/etcd-$(ETCD_NAME)-server.pem",
                //     "--key=/keys/etcd-$(ETCD_NAME)-server-key.pem",
                //   ],
                //   postStart: {`
                //     exec: {
                //       command: etcdctl + [
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

  secrets: {
    local tlsType = "kubernetes.io/tls",

    // Public CA bundle (ca.crt - possibly contains multiple certificates)
    // Same as /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    // kubeadm (incorrectly) uses /etc/kubernetes/pki/ca.crt
    ca_bundle: utils.HashedSecret("kube-ca-bundle") + $.namespace {
      data_: {
        "ca.crt": importstr "pki/ca.crt",
      },
    },

    // Private CA key and matching (single) certificate
    // kubeadm uses /etc/kubernetes/pki/ca.{crt,key}
    ca: utils.HashedSecret("kube-ca") + $.namespace {
      type: tlsType,
      data_: {
        "tls.crt": importstr "pki/ca-primary.crt",
        "tls.key": importstr "pki/ca.key",
      },
    },

    // kubeadm uses /etc/kubernetes/pki/etcd-ca.crt
    etcd_ca: utils.HashedSecret("kube-etcd-ca") + $.namespace {
      data_: {
        "ca.crt": importstr "pki/etcd-ca.pem",
      },
    },

    etcdServerKey: utils.HashedSecret("etcd-server") + $.namespace {
      data_: {
        "tls.crt": importstr "pki/etcd-etcd.local-server.pem",
        "tls.key": importstr "pki/etcd-etcd.local-server-key.pem",
      },
    },

    etcdPeerKey: utils.HashedSecret("etcd-peer") + $.namespace {
      data_: {
        "tls.crt": importstr "pki/etcd-etcd.local-peer.pem",
        "tls.key": importstr "pki/etcd-etcd.local-peer-key.pem",
      },
    },

    etcdMonitorKey: utils.HashedSecret("etcd-monitor") + $.namespace {
      data_: {
        "tls.crt": importstr "pki/etcd-monitor-client.pem",
        "tls.key": importstr "pki/etcd-monitor-client-key.pem",
      },
    },

    // kubeadm uses /etc/kubernetes/pki/etcd-apiserver-client.{crt,key}
    etcd_apiserver_client: utils.HashedSecret("kube-etcd-apiserver-client") + $.namespace {
      type: tlsType,
      data_: {
        "tls.crt": importstr "pki/etcd-apiserver-client.pem",
        "tls.key": importstr "pki/etcd-apiserver-client-key.pem",
      },
    },

    // kubeadm uses /etc/kubernetes/pki/apiserver.{crt,key}
    apiserver: utils.HashedSecret("kube-apiserver") + $.namespace {
      type: tlsType,
      data_: {
        "tls.crt": importstr "pki/apiserver.crt",
        "tls.key": importstr "pki/apiserver.key",
      },
    },

    // kubeadm uses /etc/kubernetes/pki/apiserver-kubelet-client.{crt,key}
    apiserver_kubelet_client: utils.HashedSecret("kube-apiserver-kubelet-client") + $.namespace {
      type: tlsType,
      data_: {
        "tls.crt": importstr "pki/apiserver-kubelet-client.crt",
        "tls.key": importstr "pki/apiserver-kubelet-client.key",
      },
    },

    // kubeadm uses /etc/kubernetes/pki/sa.{pub,key}
    service_account: utils.HashedSecret("kube-service-account") + $.namespace {
      data_: {
        "key.pub": importstr "pki/sa.pub",
        "key.key": importstr "pki/sa.key",
      },
    },

    // CA bundle (ca.crt)
    // kubeadm uses /etc/kubernetes/pki/front-proxy-ca.{crt,key}
    // TODO: I suspect this should be a CA bundle, not a crt/key pair??
    front_proxy_ca: utils.HashedSecret("kube-front-proxy-ca") + $.namespace {
      data_: {
        "tls.crt": importstr "pki/front-proxy-ca.crt",
        "tls.key": importstr "pki/front-proxy-ca.key",
      },
    },

    // kubeadm uses /etc/kubernetes/pki/front-proxy-client.{crt,key}
    front_proxy_client: utils.HashedSecret("kube-front-proxy-client") + $.namespace {
      type: tlsType,
      data_: {
        "tls.crt": importstr "pki/front-proxy-client.crt",
        "tls.key": importstr "pki/front-proxy-client.key",
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
                image: "k8s.gcr.io/kube-proxy:%s" % [version],
                command: ["kube-proxy"],
                args_+: {
                  "kubeconfig": "/etc/kubernetes/kubeconfig.conf",
                  "proxy-mode": "ipvs",
                  "cluster-cidr": clusterCidr,
                  "hostname-override": "$(NODE_NAME)",
                  "metrics-bind-address": "$(POD_IP):10249",
                  "healthz-bind-address": "$(POD_IP):10256",
                },
                env_+: {
                  NODE_NAME: kube.FieldRef("spec.nodeName"),
                  POD_IP: kube.FieldRef("status.podIP"),
                  GOGC: "25",
                },
                ports_+: {
                  metrics: {containerPort: 10249},
                },
                securityContext: {
                  privileged: true,
                },
                volumeMounts_+: {
                  kubeconfig: {mountPath: "/etc/kubernetes", readOnly: true},
                  xtables_lock: {mountPath: "/run/xtables.lock"},
                  lib_modules: {mountPath: "/lib/modules", readOnly: true},
                },
                livenessProbe: {
                  httpGet: {path: "/healthz", port: 10256, scheme: "HTTP"},
                  initialDelaySeconds: 30,
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
            securityContext+: {
              runAsNonRoot: true,
              runAsUser: 65534,
            },
            automountServiceAccountToken: false,
            tolerations+: bootstrapTolerations,
            volumes_+: {
              kubelet_client: kube.SecretVolume($.secrets.apiserver_kubelet_client),
              sa: kube.SecretVolume($.secrets.service_account) {
                secret+: {
                  // restrict to public key only
                  items: [{key: "key.pub", path: self.key}],
                },
              },
              ca_bundle: kube.SecretVolume($.secrets.ca_bundle),
              fpc: kube.SecretVolume($.secrets.front_proxy_client),
              fp_ca: kube.SecretVolume($.secrets.front_proxy_ca),
              tls: kube.SecretVolume($.secrets.apiserver),
              etcd_ca: kube.SecretVolume($.secrets.etcd_ca),
              etcd_client: kube.SecretVolume($.secrets.etcd_apiserver_client),

              cacerts: kube.HostPathVolume("/etc/ssl/certs", "DirectoryOrCreate"),
            },
            containers_+: {
              apiserver: kube.Container("apiserver") {
                image: "k8s.gcr.io/kube-apiserver:%s" % [apiserverVersion],
                command: ["kube-apiserver"],
                args_+: {
                  "endpoint-reconciler-type": "lease",
                  "enable-bootstrap-token-auth": "true",
                  "kubelet-preferred-address-types": "InternalIP,ExternalIP,Hostname",
                  "enable-admission-plugins": "NodeRestriction",
                  //"anonymous-auth": "false", bootkube has this, but not kubeadm
                  "profiling": "false",
                  "allow-privileged": "true",
                  "service-cluster-ip-range": serviceClusterCidr,
                  // Flag --insecure-port has been deprecated, This flag will be removed in a future version.
                  "insecure-port": "0",
                  "secure-port": "6443",
                  "authorization-mode": "Node,RBAC",
                  "tls-min-version": "VersionTLS12",
                  "tls-cipher-suites": "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_RSA_WITH_AES_256_GCM_SHA384,TLS_RSA_WITH_AES_128_GCM_SHA256",

                  "etcd-servers": std.join(",", [
                    "https://%s:2379" % v for v in kube.objectValues(etcdMembers)
                  ]),

                  "advertise-address": "$(POD_IP)",
                  "external-hostname": externalHostname,

                  "etcd-count-metric-poll-period": "10m", // default 1m
                  "watch-cache": "false",  // disable to conserve precious ram
                  //"default-watch-cache-size": "0", // default 100
                  "request-timeout": "5m",
                  "shutdown-delay-duration": "%ds" % (this.spec.template.spec.terminationGracePeriodSeconds - 5),
                  "max-requests-inflight": "150", // ~15 per 25-30 pods, default 400
                  "target-ram-mb": "500", // ~60MB per 20-30 pods

                  "kubelet-client-certificate": "/keys/apiserver-kubelet-client/tls.crt",
                  "kubelet-client-key": "/keys/apiserver-kubelet-client/tls.key",
                  "service-account-key-file": "/keys/sa/key.pub",
                  "client-ca-file": "/keys/ca-bundle/ca.crt",
                  "proxy-client-cert-file": "/keys/front-proxy-client/tls.crt",
                  "proxy-client-key-file": "/keys/front-proxy-client/tls.key",
                  "tls-cert-file": "/keys/apiserver/tls.crt",
                  "tls-private-key-file": "/keys/apiserver/tls.key",
                  "etcd-cafile": "/keys/etcd-ca/ca.crt",
                  "etcd-certfile": "/keys/etcd-apiserver-client/tls.crt",
                  "etcd-keyfile": "/keys/etcd-apiserver-client/tls.key",

                  "requestheader-extra-headers-prefix": "X-Remote-Extra-",
                  "requestheader-allowed-names": "front-proxy-client",
                  "requestheader-username-headers": "X-Remote-User",
                  "requestheader-group-headers": "X-Remote-Group",
                  "requestheader-client-ca-file": "/keys/front-proxy-ca/tls.crt",

                  // Workaround old coreos update-operator code.
                  // https://github.com/coreos/container-linux-update-operator/issues/196
                  "runtime-config": "extensions/v1beta1/daemonsets=true",
                },
                env_+: {
                  POD_IP: kube.FieldRef("status.podIP"),
                  GOGC: "25",
                },
                ports_+: {
                  https: {containerPort: 6443, protocol: "TCP"},
                },
                livenessProbe: {
                  httpGet: {path: "/healthz", port: 6443, scheme: "HTTPS"},
                  failureThreshold: 10,
                  initialDelaySeconds: 300,
                  periodSeconds: 30,
                  successThreshold: 1,
                  timeoutSeconds: 20,
                },
                readinessProbe: self.livenessProbe {
                  httpGet+: {path: "/readyz"},
                  failureThreshold: 2,
                  initialDelaySeconds: 120,
                  successThreshold: 3,
                },
                resources+: {
                  requests: {cpu: "250m", memory: "550Mi"},
                },
                volumeMounts_+: {
                  kubelet_client: {mountPath: "/keys/apiserver-kubelet-client", readOnly: true},
                  sa: {mountPath: "/keys/sa", readOnly: true},
                  ca_bundle: {mountPath: "/keys/ca-bundle", readOnly: true},
                  fpc: {mountPath: "/keys/front-proxy-client", readOnly: true},
                  fp_ca: {mountPath: "/keys/front-proxy-ca", readOnly: true},
                  tls: {mountPath: "/keys/apiserver", readOnly: true},
                  etcd_ca: {mountPath: "/keys/etcd-ca", readOnly: true},
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
        template+: {
          metadata+: {
            annotations+: {
              "checkpointer.alpha.coreos.com/checkpoint": "true",
            },
          },
          spec+: {
            hostNetwork: true,
            dnsPolicy: "ClusterFirstWithHostNet",
            // Moved to a nodeAffinity rule, to workaround a limitation
            // with pod-checkpointer (or arguably kubelet).
            //nodeSelector+: {"node-role.kubernetes.io/master": ""},
            affinity+: {
              nodeAffinity+: {
                requiredDuringSchedulingIgnoredDuringExecution+: {
                  nodeSelectorTerms: if isolateMasters then [
                    labelSelector({
                      "node-role.kubernetes.io/master": "",
                    }),
                  ] else [
                    labelSelector({
                      "apiserver": "true",
                    }),
                  ],
                },
              },
              podAntiAffinity: {
                requiredDuringSchedulingIgnoredDuringExecution: [{
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
            [if isolateMasters then "nodeSelector"]+: {"node-role.kubernetes.io/master": ""},
            tolerations+: utils.toleratesMaster + bootstrapTolerations,
            securityContext+: {
              runAsNonRoot: true,
              runAsUser: 65534,
            },
            volumes_+: {
              varrunkubernetes: kube.EmptyDirVolume(),
              cacerts: kube.HostPathVolume("/etc/ssl/certs", "DirectoryOrCreate"),
              flexvolume: kube.HostPathVolume("/var/lib/kubelet/volumeplugins", "DirectoryOrCreate"),
              ca: kube.SecretVolume($.secrets.ca),
              ca_bundle: kube.SecretVolume($.secrets.ca_bundle),
              sa: kube.SecretVolume($.secrets.service_account),
            },
            containers_+: {
              cm: kube.Container("controller-manager") {
                image: "k8s.gcr.io/kube-controller-manager:%s" % [version],
                command: ["kube-controller-manager"],
                args_+: {
                  "use-service-account-credentials": "true",
                  "leader-elect": "true",
                  "leader-elect-resource-lock": "configmaps",
                  "controllers": "*,bootstrapsigner,tokencleaner",
                  "allocate-node-cidrs": "true",
                  "cluster-cidr": clusterCidr,
                  "service-cluster-ip-range": serviceClusterCidr,
                  "node-cidr-mask-size": "24",
                  "terminated-pod-gc-threshold": "100", // default is massive 12500
                  //"cloud-provider"

                  // Reduce leader-elect load
                  "leader-elect-lease-duration": "300s", // default 15s
                  "leader-elect-renew-deadline": "270s", // default 10s
                  "leader-elect-retry-period": "20s", // default 2s

                  "root-ca-file": "/keys/ca_bundle/ca.crt",
                  "service-account-private-key-file": "/keys/sa/key.key",
                  // cluster-signing-cert-file must be a single key, unlike --root-ca-file
                  "cluster-signing-cert-file": "/keys/ca/tls.crt",
                  "cluster-signing-key-file": "/keys/ca/tls.key",
                },
                env_+: {
                  GOGC: "25",
                },
                livenessProbe: {
                  httpGet: {path: "/healthz", port: 10252, scheme: "HTTP"},
                  initialDelaySeconds: 180,
                  timeoutSeconds: 20,
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
                  requests: {cpu: "200m"},
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
            [if isolateMasters then "nodeSelector"]+: {"node-role.kubernetes.io/master": ""},
            serviceAccountName: $.scheduler.sa.metadata.name,
            containers_+: {
              scheduler: kube.Container("scheduler") {
                image: "k8s.gcr.io/kube-scheduler:%s" % [version],
                command: ["kube-scheduler"],
                args_+: {
                  "leader-elect": "true",
                  "leader-elect-resource-lock": "configmaps",

                  // Reduce leader-elect load
                  "leader-elect-lease-duration": "300s", // default 15s
                  "leader-elect-renew-deadline": "270s", // default 10s
                  "leader-elect-retry-period": "20s", // default 2s
                },
                env_+: {
                  GOGC: "25",
                },
                livenessProbe: {
                  httpGet: {path: "/healthz", port: 10251, scheme: "HTTP"},
                  initialDelaySeconds: 180,
                  timeoutSeconds: 20,
                },
                readinessProbe: self.livenessProbe {
                  successThreshold: 3,
                },
                securityContext+: {
                  runAsNonRoot: true,
                  runAsUser: 65534,
                },
                resources+: {
                  requests: {cpu: "100m"},
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

    deploy: kube.DaemonSet("pod-checkpointer") + $.namespace {
      spec+: {
        template+: {
          metadata+: {
            annotations+: {
              "checkpointer.alpha.coreos.com/checkpoint": "true",
            },
          },
          spec+: {
            serviceAccountName: $.checkpointer.sa.metadata.name,
            hostNetwork: true,
            tolerations+: utils.toleratesMaster + bootstrapTolerations,
            // Moved to a nodeAffinity rule, to workaround a limitation
            // with pod-checkpointer (or arguably kubelet).
            //nodeSelector+: {"node-role.kubernetes.io/master": ""},
            affinity+: {
              // Harmless to run everywhere, but only necessary
              // wherever checkpointed (apiserver) jobs are running
              [if isolateMasters then "nodeAffinity"]+: {
                requiredDuringSchedulingIgnoredDuringExecution+: {
                  nodeSelectorTerms: [
                    labelSelector({
                      "node-role.kubernetes.io/master": "",
                    })
                  ],
                },
              },
            },
            volumes_+: {
              kubeconfig: kube.ConfigMapVolume($.kubeconfig_in_cluster),
              etc_k8s: kube.HostPathVolume("/etc/kubernetes"),
              var_run: kube.HostPathVolume("/var/run"),
            },
            containers_+: {
              checkpointer: kube.Container("checkpointer") {
                image: "registry.gitlab.com/anguslees/docker-bootkube-checkpoint:v0-14-0",
                command: ["checkpoint"],
                args_+: {
                  "lock-file": "/var/run/lock/pod-checkpointer.lock",
                  kubeconfig: "/etc/checkpointer/kubeconfig.conf",
                  "checkpoint-grace-period": "5m",
                },
                env_+: {
                  NODE_NAME: kube.FieldRef("spec.nodeName"),
                  POD_NAME: kube.FieldRef("metadata.name"),
                  POD_NAMESPACE: kube.FieldRef("metadata.namespace"),
                  GOGC: "25",
                },
                volumeMounts_+: {
                  kubeconfig: {mountPath: "/etc/checkpointer"},
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
          apiGroups: [""],
          resources: ["nodes"],
          verbs: ["get"],
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
            log
            kubernetes %(dnsDomain)s in-addr.arpa ip6.arpa {
              pods insecure
              upstream
              fallthrough in-addr.arpa ip6.arpa
            }
            prometheus :9153
            forward . /etc/resolv.conf
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
              "seccomp.security.alpha.kubernetes.io/pod": "docker/default",
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
              tmp: kube.EmptyDirVolume(),
            },
            containers_+: {
              coredns: kube.Container("coredns") {
                image: "k8s.gcr.io/coredns:1.6.2",
                resources+: {
                  limits: {memory: "170Mi"},
                  requests: {cpu: "100m", memory: "70Mi"},
                },
                args_+: {
                  conf: "/etc/coredns/Corefile",
                },
                env_+: {
                  GOGC: "25",
                },
                volumeMounts_+: {
                  config: {mountPath: "/etc/coredns", readOnly: true},
                  // Workaround https://github.com/coredns/deployment/pull/138
                  // Remove on coredns >=1.4.0
                  tmp: {mountPath: "/tmp"},
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
                readinessProbe: self.livenessProbe {
                  // TODO: enable "ready" plugin when released.
                  //httpGet: {path: "/ready", port: 8181, scheme: "HTTP"},
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
              fp_ca: kube.SecretVolume($.secrets.front_proxy_ca) {
                secret+: {
                  items: [
                    {key: "tls.crt", path: self.key}, // public cert only
                  ],
                },
              },
            },
            containers_+: {
              default: kube.Container("metrics-server") {
                image: "k8s.gcr.io/metrics-server:v0.3.6",
                command: ["/metrics-server"],
                args_+: {
                  "logtostderr": "true",
                  "v": "1",
                  "secure-port": "8443",
                  "cert-dir": "/tmp/certificates",
                  "kubelet-preferred-address-types": "InternalIP",
                  "kubelet-insecure-tls": "true",
                  "requestheader-client-ca-file": "/keys/front-proxy-ca/tls.crt",
                  "requestheader-allowed-names": "front-proxy-client",
                },
                env_+: {
                  GOGC: "25",
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
                livenessProbe: {
                  httpGet: {path: "/healthz", port: 8443, scheme: "HTTPS"},
                  initialDelaySeconds: 60,
                  failureThreshold: 10,
                  periodSeconds: 30,
                  successThreshold: 1,
                  timeoutSeconds: 20,
                },
                readinessProbe: self.livenessProbe {
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

    apiSvc: kube._Object("apiregistration.k8s.io/v1beta1", "APIService", "v1beta1.metrics.k8s.io") {
      spec+: {
        service: {
          name: $.metrics.svc.metadata.name,
          namespace: $.metrics.svc.metadata.namespace,
        },
        group: "metrics.k8s.io",
        version: "v1beta1",
        insecureSkipTLSVerify: true,
        groupPriorityMinimum: 100,
        versionPriority: 100,
      },
    },
  },
}
