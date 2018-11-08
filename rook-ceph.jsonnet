local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";
local rookCephSystem = import "rook-ceph-system.jsonnet";

local arch = "amd64";

{
  namespace:: {metadata+: {namespace: "rook-ceph"}},
  ns: kube.Namespace($.namespace.metadata.namespace),

  sa: kube.ServiceAccount("rook-ceph-cluster") + $.namespace,

  cephCluster: kube.Role("rook-ceph-cluster") + $.namespace {
    rules: [
      {
        apiGroups: [""],
        resources: ["configmaps"],
        verbs: ["get", "list", "watch", "create", "update", "delete"],
      },
    ],
  },

  cephClusterBinding: kube.RoleBinding("rook-ceph-cluster") + $.namespace {
    roleRef_: $.cephCluster,
    subjects_+: [$.sa],
  },

  // Allow operator to create resources in this namespace too.
  cephClusterMgmtBinding: kube.RoleBinding("rook-ceph-cluster-mgmt") + $.namespace {
    roleRef_: rookCephSystem.cephClusterMgmt,
    subjects_+: [rookCephSystem.sa],
  },

  cluster: rookCephSystem.Cluster("rook-ceph") + $.namespace {
    spec+: {
      // NB: Delete contents of this dir if recreating Cluster
      dataDirHostPath: "/var/lib/rook",
      serviceAccount: $.sa.metadata.name,
      mon: {
        count: 3,
        allowMultiplePerNode: false,
      },
      dashboard: {
        enabled: true,
      },
      network: {
        hostNetwork: false,
      },
      placement: {
        all: {
          nodeAffinity: {
            requiredDuringSchedulingIgnoredDuringExecution: {
              nodeSelectorTerms+: [{
                matchExpressions: [
                  {key: kv[0], operator: "In", values: [kv[1]]}
                  for kv in kube.objectItems(utils.archSelector(arch))
                ],
              }],
            },
          },
        },
      },
      storage: {
        useAllNodes: true,
        useAllDevices: false,
        //deviceFilter: {},
        //location: {},
        //config: {},
      },
    },
  },

  // Expose rook-ceph-mgr-dashboard outside cluster
  ing: utils.Ingress("ceph-dashboard") + $.namespace {
    spec+: {
      rules: [{
        host: "ceph.k.lan",
        http: {
          paths: [{
            path: "/",
            backend: {
              serviceName: "rook-ceph-mgr-dashboard",
              servicePort: 7000,
            },
          }],
        },
      }],
    },
  },

  // These are not defined upstream, but should be (imo).
  // https://github.com/rook/rook/issues/2128
  monDisruptionBudget: kube.PodDisruptionBudget("rook-ceph-mon") + $.namespace {
    spec+: {
      minAvailable:: null,
      maxUnavailable: 1,
      selector: {matchLabels: {app: "rook-ceph-mon"}},
    },
  },
  mdsDisruptionBudget: kube.PodDisruptionBudget("rook-ceph-mds") + $.namespace {
    spec+: {
      minAvailable: 1,
      selector: {matchLabels: {app: "rook-ceph-mds"}},
    },
  },
  osdDisruptionBudget: kube.PodDisruptionBudget("rook-ceph-osd") + $.namespace {
    spec+: {
      minAvailable:: null,
      maxUnavailable: 1,  // not true _after_ re-replication has taken place..
      selector: {matchLabels: {app: "rook-ceph-osd"}},
    },
  },

  // Define storage pools / classes
  replicapool: rookCephSystem.Pool("replicapool") + $.namespace {
    spec+: {
      failureDomain: "host",
      replicated: {size: 2},
    },
  },

  block: kube.StorageClass("ceph-block") {
    provisioner: "ceph.rook.io/block",
    parameters: {
      pool: $.replicapool.metadata.name,
      clusterNamespace: $.cephCluster.metadata.namespace,
      fstype: "ext4",
    },
  },

  // NB: Still needs provisioner + storageclass support in rook
  filesystem: rookCephSystem.Filesystem("ceph-filesystem") + $.namespace {
    spec+: {
      metadataPool: {replicated: {size: 3}},
      dataPools: [{replicated: {size: 2}}],
      metadataServer: {
        activeCount: 1,
        activeStandby: true,
      },
    },
  },
}
