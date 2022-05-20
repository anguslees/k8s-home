local kube = import "kube.libsonnet";
local kubecfg = import "kubecfg.libsonnet";
local utils = import "utils.libsonnet";

// Needs at least 1.3.8 to avoid chart syntax error
// -> https://github.com/rook/rook/pull/5660

// renovate: depName=rook-ceph registryUrls=https://charts.rook.io/release
local chartData = importbin "https://charts.rook.io/release/rook-ceph-v1.6.11.tgz";

{
  namespace:: {metadata+: {namespace: "rook-ceph"}},

  chart: kubecfg.parseHelmChart(
    chartData,
    "rook-ceph",
    $.namespace.metadata.namespace,
    {
      resources: {
        requests: {cpu: "100m", memory: "128Mi"},
      },
      mon: {
        healthCheckInterval: "45s",
        monOutTimeout: "20m", // default 10m
      },
      discover: {nodeAffinity: "kubernetes.io/arch=amd64"},
      enableFlexDriver: true,
      enableDiscoveryDaemon: true,
      agent: {
        flexVolumeDirPath: "/var/lib/kubelet/volumeplugins",
        mountSecurityMode: "Any",
      },
      enableSelinuxRelabeling: false,
      pluginPriorityClassName: "system-node-critical",
      provisionerPriorityClassName: "high",
    },
  ) + {
    "rook-ceph/templates/deployment.yaml": [o + {
      spec+: {
        template+: {
          spec+: {
            containers: [
              if c.name == "rook-ceph-operator" then c + {
                env+: [
                  {name: "ROOK_ENABLE_FSGROUP", value: "false"},
                ]
              } else c,
              for c in super.containers
            ],
          },
        },
      },
    } for o in super["rook-ceph/templates/deployment.yaml"]],
  } + {
    "rook-ceph/templates/resources.yaml": [o + {
      spec+: {
        // https://github.com/rook/rook/issues/7659
        preserveUnknownFields: false,
      },
    } for o in super["rook-ceph/templates/resources.yaml"]],
  },

  local crds = {[c.spec.names.kind]: c for c in $.chart["rook-ceph/templates/resources.yaml"] if c != null},
  CephCluster:: utils.crdNew(crds.CephCluster, "v1"),
  CephFilesystem:: utils.crdNew(crds.CephFilesystem, "v1"),
  CephObjectStore:: utils.crdNew(crds.CephObjectStore, "v1"),
  CephObjectStoreUser:: utils.crdNew(crds.CephObjectStoreUser, "v1"),
  CephBlockPool:: utils.crdNew(crds.CephBlockPool, "v1"),
  Volume:: utils.crdNew(crds.Volume, "v1alpha2"),
  CephNFS:: utils.crdNew(crds.CephNFS, "v1"),
  ObjectBucket:: utils.crdNew(crds.ObjectBucket, "v1alpha1"),
  ObjectBucketClaims:: utils.crdNew(crds.ObjectBucketClaims, "v1alpha1"),
}
