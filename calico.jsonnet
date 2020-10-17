// https://docs.projectcalico.org/manifests/calico.yaml

local kube = import "kube.libsonnet";
local kubecfg = import "kubecfg.libsonnet";
local utils = import "utils.libsonnet";

local version = "v3.15.3";

local mtu = 1440;
local calico_backend = "bird";

// Needs to fall within kube-proxy/k-c-m --cluster-cidr
local clusterCidr = "10.244.0.0/16";
//local clusterCidr6 = "fd20::/112";
// My local IPv6 subnet - you'll want to change this:
local clusterCidr6 = "2406:3400:249:1703::/112";

{
  namespace:: {metadata+: {namespace: "kube-system"}},

  config: utils.HashedConfigMap("calico-config") + $.namespace {
    data+: {
      cni_network_config_:: {
        name: "k8s-pod-network",
        cniVersion: "0.3.1",
        plugins: [
          {
            type: "calico",
            log_level: "info",
            datastore_type: "kubernetes",
            nodename: "__KUBERNETES_NODE_NAME__",
            mtu: mtu,
            ipam: {
              type: "calico-ipam"
              //type: "host-local",
              //ranges: [[{subnet: "usePodCidr"}]],
              // Clear out ipam state on reboot.  Pods are restarted
              // anyway on k8s after reboot, and this helps clean up
              // leaks.
              //dataDir: "/var/run/cni/networks",
            },
            policy: {type: "k8s"},
            kubernetes: {
              kubeconfig: "__KUBECONFIG_FILEPATH__",
              // dockerd used to work with calico's default 10.96.0.1,
              // but containerd/cri can't reach that and needs to use kube.lan?
              // FIXME: understand why.  This might be
              // https://github.com/projectcalico/calico/issues/3689
              k8s_api_root: "https://kube.lan:6443",
            },
          },
          {
            type: "portmap",
            snat: true,
            capabilities: {portMappings: true},
          },
          {
            type: "bandwidth",
            capabilities: {bandwidth: true},
          },
        ],
      },
      cni_network_config: kubecfg.manifestJson(self.cni_network_config_),
    },
  },

  bgpconfCRD: kube.CustomResourceDefinition("crd.projectcalico.org", "v1", "BGPConfiguration") {
    spec+: {scope: "Cluster"},
  },
  BGPConfiguration:: self.bgpconfCRD.new,

  bgppeersCRD: kube.CustomResourceDefinition("crd.projectcalico.org", "v1", "BGPPeer") {
    spec+: {scope: "Cluster"},
  },
  BGPPeer:: self.bgppeersCRD.new,

  blockaffinitiesCRD: kube.CustomResourceDefinition("crd.projectcalico.org", "v1", "BlockAffinity") {
    spec+: {
      scope: "Cluster",
      names+: {plural: "blockaffinities"},
    },
  },
  BlockAffinity:: self.blockaffinitiesCRD.new,

  clusterinfoCRD: kube.CustomResourceDefinition("crd.projectcalico.org", "v1", "ClusterInformation") {
    spec+: {scope: "Cluster"},
  },
  ClusterInformation:: self.clusterinfoCRD.new,

  felixconfigCRD: kube.CustomResourceDefinition("crd.projectcalico.org", "v1", "FelixConfiguration") {
    spec+: {scope: "Cluster"},
  },
  FelixConfiguration:: self.felixconfigCRD.new,

  globalnetpolicyCRD: kube.CustomResourceDefinition("crd.projectcalico.org", "v1", "GlobalNetworkPolicy") {
    spec+: {scope: "Cluster"},
  },
  GlobalNetworkPolicy:: self.globalnetpolicyCRD.new,

  globalnetsetCRD: kube.CustomResourceDefinition("crd.projectcalico.org", "v1", "GlobalNetworkSet") {
    spec+: {scope: "Cluster"},
  },
  GlobalNetworkSet:: self.globalnetsetCRD.new,

  hostendpointsCRD: kube.CustomResourceDefinition("crd.projectcalico.org", "v1", "HostEndpoint") {
    spec+: {scope: "Cluster"},
  },
  HostEndpoint:: self.hostendpointsCRD.new,

  ipamblocksCRD: kube.CustomResourceDefinition("crd.projectcalico.org", "v1", "IPAMBlock") {
    spec+: {scope: "Cluster"},
  },
  IPAMBlock:: self.ipamblocksCRD.new,

  ipamconfigsCRD: kube.CustomResourceDefinition("crd.projectcalico.org", "v1", "IPAMConfig") {
    spec+: {scope: "Cluster"},
  },
  IPAMConfig:: self.ipamconfigsCRD.new,

  ipamhandlesCRD: kube.CustomResourceDefinition("crd.projectcalico.org", "v1", "IPAMHandle") {
    spec+: {scope: "Cluster"},
  },
  IPAMHandle:: self.ipamhandlesCRD.new,

  ippoolsCRD: kube.CustomResourceDefinition("crd.projectcalico.org", "v1", "IPPool") {
    spec+: {scope: "Cluster"},
  },
  IPPool:: self.ippoolsCRD.new,

  kubecontrollersCRD: kube.CustomResourceDefinition("crd.projectcalico.org", "v1", "KubeControllersConfiguration") {
    spec+: {scope: "Cluster"},
  },
  KubeControllersConfiguration:: self.kubecontrollersCRD.new,

  netpoliciesCRD: kube.CustomResourceDefinition("crd.projectcalico.org", "v1", "NetworkPolicy") {
    spec+: {names+: {plural: "networkpolicies"}},
  },
  NetworkPolicy:: self.netpoliciesCRD.new,

  netsetsCRD: kube.CustomResourceDefinition("crd.projectcalico.org", "v1", "NetworkSet"),
  NetworkSet:: self.netsetsCRD.new,

  controllers: {
    clusterRole: kube.ClusterRole("calico-kube-controllers") {
      rules: [
        {
          apiGroups: [""],
          resources: ["nodes"],
          verbs: ["watch", "list", "get"],
        },
        {
          apiGroups: [""],
          resources: ["pods"],
          verbs: ["get"],
        },
        {
          apiGroups: ["crd.projectcalico.org"],
          resources: ["ippools"],
          verbs: ["list"],
        },
        {
          apiGroups: ["crd.projectcalico.org"],
          resources: ["blockaffinities", "ipamblocks", "ipamhandles"],
          verbs: ["get", "list", "create", "update", "delete"],
        },
        {
          apiGroups: ["crd.projectcalico.org"],
          resources: ["hostendpoints"],
          verbs: ["get", "list", "create", "update", "delete"],
        },
        {
          apiGroups: ["crd.projectcalico.org"],
          resources: ["clusterinformations"],
          verbs: ["get", "create", "update"],
        },
        {
          apiGroups: ["crd.projectcalico.org"],
          resources: ["kubecontrollersconfigurations"],
          verbs: ["get", "create", "update", "watch"],
        },
      ],
    },

    clusterRoleBinding: kube.ClusterRoleBinding("calico-kube-controllers") {
      roleRef_: $.controllers.clusterRole,
      subjects_+: [$.controllers.sa],
    },

    sa: kube.ServiceAccount("calico-kube-controllers") + $.namespace,

    deploy: kube.Deployment("calico-kube-controllers") + $.namespace {
      spec+: {
        template+: utils.CriticalPodSpec + {
          spec+: {
            nodeSelector+: {"kubernetes.io/os": "linux"},
            tolerations+: utils.toleratesMaster,
            serviceAccountName: $.controllers.sa.metadata.name,
            containers_+: {
              controllers: kube.Container("calico-kube-controllers") {
                image: "calico/kube-controllers:" + version,
                env_+: {
                  ENABLED_CONTROLLERS: "node",
                  DATASTORE_TYPE: "kubernetes",
                },
                readinessProbe: {
                  exec: {command: ["/usr/bin/check-status", "-r"]},
                },
              },
            },
          },
        },
      },
    },
  },

  node: {
    clusterRole: kube.ClusterRole("calico-node") {
      rules: [
        {
          apiGroups: [""],
          resources: ["pods", "nodes", "namespaces"],
          verbs: ["get"],
        },
        {
          apiGroups: [""],
          resources: ["endpoints", "services"],
          verbs: ["watch", "list", "get"],
        },
        {
          apiGroups: [""],
          resources: ["configmaps"],
          verbs: ["get"],
        },
        {
          apiGroups: [""],
          resources: ["nodes/status"],
          verbs: ["patch", "update"],
        },
        {
          apiGroups: ["networking.k8s.io"],
          resources: ["networkpolicies"],
          verbs: ["watch", "list"],
        },
        {
          apiGroups: [""],
          resources: ["pods", "namespaces", "serviceaccounts"],
          verbs: ["list", "watch"],
        },
        {
          apiGroups: [""],
          resources: ["pods/status"],
          verbs: ["patch"],
        },
        {
          apiGroups: ["crd.projectcalico.org"],
          resources: [
            "globalfelixconfigs",
            "felixconfigurations",
            "bgppeers",
            "globalbgpconfigs",
            "bgpconfigurations",
            "ippools",
            "ipamblocks",
            "globalnetworkpolicies",
            "globalnetworksets",
            "networkpolicies",
            "networksets",
            "clusterinformations",
            "hostendpoints",
            "blockaffinities",
          ],
          verbs: ["get", "list", "watch"],
        },
        {
          apiGroups: ["crd.projectcalico.org"],
          resources: ["ippools", "felixconfigurations", "clusterinformations"],
          verbs: ["create", "update"],
        },
        {
          apiGroups: [""],
          resources: ["nodes"],
          verbs: ["get", "list", "watch"],
        },
        {
          apiGroups: ["crd.projectcalico.org"],
          resources: ["bgpconfigurations", "bgppeers"],
          verbs: ["create", "update"],
        },
        {
          apiGroups: ["crd.projectcalico.org"],
          resources: ["blockaffinities", "ipamblocks", "ipamhandles"],
          verbs: ["get", "list", "create", "update", "delete"],
        },
        {
          apiGroups: ["crd.projectcalico.org"],
          resources: ["ipamconfigs"],
          verbs: ["get"],
        },
        {
          apiGroups: ["crd.projectcalico.org"],
          resources: ["blockaffinities"],
          verbs: ["watch"],
        },
        // daemonsets/get not needed in new installations
      ],
    },

    clusterRoleBinding: kube.ClusterRoleBinding("calico-node") {
      roleRef_: $.node.clusterRole,
      subjects_+: [$.node.sa],
    },

    sa: kube.ServiceAccount("calico-node") + $.namespace,

    deploy: kube.DaemonSet("calico-node") + $.namespace {
      spec+: {
        template+: utils.CriticalPodSpec + {
          spec+: {
            nodeSelector+: {
              "kubernetes.io/os": "linux",
            },
            hostNetwork: true,
            tolerations+: utils.toleratesMaster + [
              {effect: "NoSchedule", operator: "Exists"},
              {effect: "NoExecute", operator: "Exists"},
            ],
            priorityClassName: "system-node-critical",
            serviceAccountName: $.node.sa.metadata.name,
            terminationGracePeriodSeconds: 0,

            volumes_+: {
              modules: kube.HostPathVolume("/lib/modules"),
              varrun: kube.HostPathVolume("/var/run/calico"),
              varlib: kube.HostPathVolume("/var/lib/calico"),
              xtables_lock: kube.HostPathVolume("/run/xtables.lock", "FileOrCreate"),
              cnibin: kube.HostPathVolume("/opt/cni/bin"),
              cnietc: kube.HostPathVolume("/etc/cni/net.d"),
              policysync: kube.HostPathVolume("/var/run/nodeagent", "DirectoryOrCreate"),
              flexvol: kube.HostPathVolume("/var/lib/kubelet/volumeplugins/nodeagent~uds", "DirectoryOrCreate"),
            },

            initContainers_+: {
              // upgrade-ipam not needed for fresh installs
              install: kube.Container("install-cni") {
                image: "calico/cni:" + version,
                command: ["/install-cni.sh"],
                env_+: {
                  CNI_CONF_NAME: "10-calico.conflist",
                  CNI_NETWORK_CONFIG: kube.ConfigMapRef($.config, "cni_network_config"),
                  KUBERNETES_NODE_NAME: kube.FieldRef("spec.nodeName"),
                  CNI_MTU: mtu,
                  SLEEP: "false",
                },
                volumeMounts_+: {
                  cnibin: {mountPath: "/host/opt/cni/bin"},
                  cnietc: {mountPath: "/host/etc/cni/net.d"},
                },
              },
              flexvol: kube.Container("flexvol-driver") {
                image: "calico/pod2daemon-flexvol:" + version,
                volumeMounts_+: {
                  flexvol: {mountPath: "/host/driver"},
                },
              },
            },

            containers_+: {
              node: kube.Container("calico-node") {
                image: "calico/node:" + version,
                env_+: {
                  DATASTORE_TYPE: "kubernetes",
                  WAIT_FOR_DATASTORE: true,
                  NODENAME: kube.FieldRef("spec.nodeName"),
                  CALICO_NETWORKING_BACKEND: calico_backend,
                  CLUSTER_TYPE: "k8s,bgp",
                  USE_POD_CIDR: false,
                  IP: "autodetect",
                  IP_AUTODETECTION_METHOD: "can-reach=8.8.8.8",
                  IP6: "autodetect",
                  IP6_AUTODETECTION_METHOD: "can-reach=2001:4860:4860::8888",
                  CALICO_IPV4POOL_CIDR: clusterCidr,
                  CALICO_IPV4POOL_IPIP: "CrossSubnet",
                  CALICO_IPV6POOL_CIDR: clusterCidr6,
                  FELIX_IPINIPMTU: mtu,
                  CALICO_DISABLE_FILE_LOGGING: true,
                  FELIX_DEFAULTENDPOINTTOHOSTACTION: "ACCEPT",
                  FELIX_IPV6SUPPORT: true,
                  FELIX_LOGSEVERITYSCREEN: "info",
                  FELIX_HEALTHENABLED: true,
                  CALICO_MANAGE_CNI: true,
                },
                securityContext: {
                  privileged: true,
                  capabilities: {add: ["NET_ADMIN"]},
                },
                resources: {
                  requests: {memory: "40Mi", cpu: "200m"},
                },
                readinessProbe: {
                  exec: {
                    command: ["/bin/calico-node", "-felix-live", "-bird-live"],
                  },
                  periodSeconds: 30,
                },
                livenessProbe: self.readinessProbe {
                  initialDelaySeconds: 10,
                  failureThreshold: 6,
                },
                volumeMounts_+: {
                  modules: {mountPath: "/lib/modules", readOnly: true},
                  xtables_lock: {mountPath: "/run/xtables.lock"},
                  varrun: {mountPath: "/var/run/calico"},
                  varlib: {mountPath: "/var/lib/calico"},
                  policysync: {mountPath: "/var/run/nodeagent"},
                },
              },
            },
          },
        },
      },
    },
  },

}
