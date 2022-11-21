// https://docs.projectcalico.org/manifests/calico.yaml

local kube = import "kube.libsonnet";
local kubecfg = import "kubecfg.libsonnet";

local mtu = 1440;
local calico_backend = "bird";

// Needs to fall within kube-proxy/k-c-m --cluster-cidr
local clusterCidr = "10.244.0.0/16";
//local clusterCidr6 = "fd20::/112";
// My local IPv6 subnet - you'll want to change this:
local clusterCidr6 = "2406:3400:249:1703::/112";

// renovate: depName=projectcalico/calico datasource=github-releases versioning=semver
local manifest = importstr "https://raw.githubusercontent.com/projectcalico/calico/v3.24.5/manifests/calico.yaml";
local upstream = kubecfg.fold(kubecfg.layouts.gvkName, kubecfg.parseYaml(manifest), {});

local BGPConfiguration(name) =
  kube._Object("crd.projectcalico.org/v1", "BGPConfiguration", name);

upstream + {
  "v1.ConfigMap"+: {
    "calico-config"+: {
      data+: {
        veth_mtu: std.toString(mtu),

        cni_network_config_:: {
          name: "k8s-pod-network",
          cniVersion: "0.3.1",
          plugins: [
            {
              type: "calico",
              log_level: "info",
              log_file_path: "/var/log/calico/cni/cni.log",
              datastore_type: "kubernetes",
              nodename: "__KUBERNETES_NODE_NAME__",
              mtu: mtu, // __CNI_MTU__ (no quotes, which makes it invalid json)
              ipam: {
                type: "calico-ipam",
                assign_ipv4: "true",
                assign_ipv6: "true",
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
  },

  "apps/v1.Deployment"+: {
    "calico-kube-controllers"+: {
      spec+: {
        template+: {
          spec+: {
          },
        },
      },
    },
  },

  "apps/v1.DaemonSet"+: {
    "calico-node"+: {
      spec+: {
        template+: {
          spec+: {
            containers: kube.mapToNamedList(self.containers_),
            containers_:: {[c.name]: c for c in super.containers} + {
              "calico-node"+: {
                env: kube.Container(error "unused").envList(self.env_),
                env_:: {
                  [e.name]: if std.objectHas(e, "valueFrom") then e.valueFrom else e.value
                  for e in super.env
                } + {
                  USE_POD_CIDR: false,
                  IP_AUTODETECTION_METHOD: "can-reach=www.google.com",
                  CALICO_IPV4POOL_IPIP: "CrossSubnet",
                  CALICO_IPV4POOL_CIDR: clusterCidr,
                  CALICO_IPV6POOL_CIDR: clusterCidr6,
                  FELIX_IPV6SUPPORT: true,
                  IP6: "autodetect",
                  IP6_AUTODETECTION_METHOD: "can-reach=www.google.com",
                  FELIX_LOGSEVERITYSCREEN: "INFO",
                  CALICO_MANAGE_CNI: true,
                },
                resources+: {
                  requests+: {cpu: "100m", memory: "200Mi"},
                },
              },
            },
          },
        },
      },
    },
  },

  /*
  bgpconf: BGPConfiguration("node.50bea5a2341c40588d32c8103dea6e71") {
    spec+: {
      logSeverityScreen: "DEBUG",
    },
  },
  */
}
