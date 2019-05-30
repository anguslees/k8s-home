// kubeadm is dead to me :(
// (not true: I use kubeadm to join nodes, but from there it's self-hosted via this file)
//
// https://github.com/kubernetes/kubeadm/issues/413
// https://github.com/kubernetes/enhancements/issues/415#issuecomment-409989216
//

local kube = import "kube.libsonnet";
local kubecfg = import "kubecfg.libsonnet";
local utils = import "utils.libsonnet";

local version = "v1.11.10";

local externalHostname = "kube.lan";
local apiServer = "https://%s:6443" % [externalHostname];
local clusterCidr = "10.244.0.0/16";
local serviceClusterCidr = "10.96.0.0/12";
local dnsIP = "10.96.0.10";

local labelSelector(labels) = {
  matchExpressions: [
    {key: kv[0], operator: "In", values: [kv[1]]}
    for kv in kube.objectItems(labels)
  ],
};

// Inspiration:
//  https://github.com/kubernetes/kubeadm/blob/master/docs/design/design_v1.10.md
//  https://github.com/kubernetes-incubator/bootkube/blob/master/pkg/asset/internal/templates.go

{
  namespace:: {
    metadata+: { namespace: "kube-system" },
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
                  "proxy-mode": "iptables", // todo: migrate to ipvs
                  "cluster-cidr": clusterCidr,
                  "hostname-override": "$(NODE_NAME)",
                  // https://github.com/kubernetes/kubernetes/issues/53754
                  // Fixed in k8s v1.14
                  //"metrics-bind-address": "$(POD_IP)",
                  //"metrics-port": "10249",
                  "healthz-bind-address": "$(POD_IP)",
                  "healthz-port": "10256",
                },
                env_+: {
                  NODE_NAME: kube.FieldRef("spec.nodeName"),
                  POD_IP: kube.FieldRef("status.podIP"),
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

    deploy: kube.DaemonSet("kube-apiserver") + $.namespace {
      local this = self,
      spec+: {
        template+: utils.CriticalPodSpec {
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
                  nodeSelectorTerms: [
                    labelSelector({
                      "node-role.kubernetes.io/master": "",
                    })
                  ],
                },
              },
            },
            securityContext+: {
              runAsNonRoot: true,
              runAsUser: 65534,
            },
            automountServiceAccountToken: false,
            tolerations+: utils.toleratesMaster,
            volumes_+: {
              certs: kube.HostPathVolume("/etc/kubernetes/pki", "DirectoryOrCreate"),
              cacerts: kube.HostPathVolume("/etc/ssl/certs", "DirectoryOrCreate"),
            },
            containers_+: {
              apiserver: kube.Container("apiserver") {
                image: "k8s.gcr.io/kube-apiserver:%s" % [version],
                command: ["kube-apiserver"],
                args_+: {
                  "endpoint-reconciler-type": "lease",
                  "enable-bootstrap-token-auth": "true",
                  "kubelet-preferred-address-types": "InternalIP,ExternalIP,Hostname",
                  "enable-admission-plugins": "NodeRestriction",
                  //"anonymous-auth": "false", bootkube has this, but not kubeadm
                  "allow-privileged": "true",
                  "service-cluster-ip-range": serviceClusterCidr,
                  // Flag --insecure-port has been deprecated, This flag will be removed in a future version.
                  "insecure-port": "0",
                  "secure-port": "6443",
                  "authorization-mode": "Node,RBAC",
                  "etcd-servers": "http://127.0.0.1:2379",
                  "advertise-address": "$(POD_IP)",
                  "external-hostname": externalHostname,

                  "watch-cache": "false",  // disable to conserve precious ram
                  //"default-watch-cache-size": "0", // default 100
                  "request-timeout": "5m",
                  "max-requests-inflight": "150", // ~15 per 25-30 pods, default 400
                  "target-ram-mb": "300", // ~60MB per 20-30 pods

                  "kubelet-client-certificate": "/etc/kubernetes/pki/apiserver-kubelet-client.crt",
                  "kubelet-client-key": "/etc/kubernetes/pki/apiserver-kubelet-client.key",
                  "service-account-key-file": "/etc/kubernetes/pki/sa.pub",
                  "client-ca-file": "/etc/kubernetes/pki/ca.crt",
                  "proxy-client-cert-file": "/etc/kubernetes/pki/front-proxy-client.crt",
                  "proxy-client-key-file": "/etc/kubernetes/pki/front-proxy-client.key",
                  "tls-cert-file": "/etc/kubernetes/pki/apiserver.crt",
                  "tls-private-key-file": "/etc/kubernetes/pki/apiserver.key",
                  "etcd-cafile": "/etc/kubernetes/pki/etcd-ca.pem",
                  "etcd-certfile": "/etc/kubernetes/pki/etcd-apiserver-client.pem",
                  "etcd-keyfile": "/etc/kubernetes/pki/etcd-apiserver-client-key.pem",

                  "requestheader-extra-headers-prefix": "X-Remote-Extra-",
                  "requestheader-allowed-names": "front-proxy-client",
                  "requestheader-username-headers": "X-Remote-User",
                  "requestheader-group-headers": "X-Remote-Group",
                  "requestheader-client-ca-file": "/etc/kubernetes/pki/front-proxy-ca.crt",
                },
                env_+: {
                  POD_IP: kube.FieldRef("status.podIP"),
                },
                livenessProbe:: {  // FIXME: disabled for now
                  httpGet: {path: "/healthz", port: 6443, scheme: "HTTPS"},
                  failureThreshold: 10,
                  initialDelaySeconds: 300,
                  periodSeconds: 30,
                  successThreshold: 1,
                  timeoutSeconds: 20,
                },
                readinessProbe: self.livenessProbe {
                  failureThreshold: 2,
                  initialDelaySeconds: 120,
                  successThreshold: 3,
                },
                resources+: {
                  requests: {cpu: "250m"},
                },
                volumeMounts_+: {
                  certs: {mountPath: "/etc/kubernetes/pki", readOnly: true},
                  cacerts: {mountPath: "/etc/ssl/certs", readOnly: true},
                },
              },
            },
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
                preferredDuringSchedulingIgnoredDuringExecution: [{
                  weight: 100,
                  podAffinityTerm: {
                    labelSelector: labelSelector(this.spec.template.metadata.labels),
                    topologyKey: "kubernetes.io/hostname",
                  },
                }],
              },
            },
            serviceAccountName: $.controller_manager.sa.metadata.name,
            nodeSelector+: {"node-role.kubernetes.io/master": ""},
            tolerations+: utils.toleratesMaster,
            securityContext+: {
              runAsNonRoot: true,
              runAsUser: 65534,
            },
            volumes_+: {
              varrunkubernetes: kube.EmptyDirVolume(),
              certs: kube.HostPathVolume("/etc/kubernetes/pki", "DirectoryOrCreate"),
              cacerts: kube.HostPathVolume("/etc/ssl/certs", "DirectoryOrCreate"),
              flexvolume: kube.HostPathVolume("/var/lib/kubelet/volumeplugins", "DirectoryOrCreate"),
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
                  //"cloud-provider"

                  // Reduce leader-elect load
                  "leader-elect-lease-duration": "300s", // default 15s
                  "leader-elect-renew-deadline": "270s", // default 10s
                  "leader-elect-retry-period": "20s", // default 2s

                  "root-ca-file": "/etc/kubernetes/pki/ca.crt",
                  "service-account-private-key-file": "/etc/kubernetes/pki/sa.key",
                  // cluster-signing-cert-file must be a single key, unlike ca.crt
                  "cluster-signing-cert-file": "/etc/kubernetes/pki/ca-primary.crt",
                  "cluster-signing-key-file": "/etc/kubernetes/pki/ca.key",
                },
                livenessProbe:: { // FIXME: disabled for now
                  httpGet: {path: "/healthz", port: 10252, scheme: "HTTP"},
                  initialDelaySeconds: 180,
                  timeoutSeconds: 20,
                },
                readinessProbe: self.livenessProbe {
                  successThreshold: 3,
                },
                volumeMounts_+: {
                  certs: {mountPath: "/etc/kubernetes/pki", readOnly: true},
                  cacerts: {mountPath: "/etc/ssl/certs", readOnly: true},
                  flexvolume: {mountPath: "/usr/libexec/kubernetes/kubelet-plugins/volume/exec"},
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
        template+: utils.CriticalPodSpec + {
          spec+: {
            affinity+: {
              podAntiAffinity: {
                preferredDuringSchedulingIgnoredDuringExecution: [{
                  weight: 100,
                  podAffinityTerm: {
                    labelSelector: labelSelector(this.spec.template.metadata.labels),
                    topologyKey: "kubernetes.io/hostname",
                  },
                }],
              },
            },
            nodeSelector+: {"node-role.kubernetes.io/master": ""},
            tolerations+: utils.toleratesMaster,
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
                livenessProbe:: { // FIXME: disabled for now :/
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
            // Moved to a nodeAffinity rule, to workaround a limitation
            // with pod-checkpointer (or arguably kubelet).
            //nodeSelector+: {"node-role.kubernetes.io/master": ""},
            tolerations+: utils.toleratesMaster,
            volumes_+: {
              kubeconfig: kube.ConfigMapVolume($.kubeconfig_in_cluster),
              etc_k8s: kube.HostPathVolume("/etc/kubernetes"),
              var_run: kube.HostPathVolume("/var/run"),
            },
            affinity+: {
              nodeAffinity+: {
                requiredDuringSchedulingIgnoredDuringExecution+: {
                  nodeSelectorTerms: [
                    labelSelector({
                      "node-role.kubernetes.io/master": "",
                    })
                  ],
                },
              },
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
            kubernetes cluster.local %s {
              pods insecure
              upstream
              fallthrough in-addr.arpa ip6.arpa
            }
            prometheus :9153
            proxy . /etc/resolv.conf
            cache 30
            loop
            loadbalance
            # Note no 'reload' since we use HashedConfigMap
          }
        ||| % serviceClusterCidr,
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
                image: "k8s.gcr.io/coredns:1.3.1",
                resources+: {
                  limits: {memory: "170Mi"},
                  requests: {cpu: "100m", memory: "70Mi"},
                },
                args_+: {
                  conf: "/etc/coredns/Corefile",
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
}
