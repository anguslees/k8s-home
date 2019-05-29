local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";
local rookCephSystem = import "rook-ceph-system.jsonnet";

local arch = "amd64";

// https://hub.docker.com/r/ceph/ceph/tags
local cephVersion = "v13.2.5-20190410";

{
  namespace:: {metadata+: {namespace: "rook-ceph"}},
  ns: kube.Namespace($.namespace.metadata.namespace),

  mgrSa: kube.ServiceAccount("rook-ceph-mgr") + $.namespace,

  osdRole: kube.Role("rook-ceph-osd") + $.namespace {
    rules: [
      {
        apiGroups: [""],
        resources: ["configmaps"],
        verbs: ["get", "list", "watch", "create", "update", "delete"],
      },
    ],
  },

  osdSa: kube.ServiceAccount("rook-ceph-osd") + $.namespace,

  osdRoleBinding: kube.RoleBinding("rook-ceph-osd") + $.namespace {
    roleRef_: $.osdRole,
    subjects_+: [$.osdSa],
  },

  mgrRole: kube.Role("rook-ceph-mgr") + $.namespace {
    rules: [
      {
        apiGroups: [""],
        resources: ["pods", "services"],
        verbs: ["get", "list", "watch"],
      },
      {
        apiGroups: ["batch"],
        resources: ["jobs"],
        verbs: ["get", "list", "watch", "create", "update", "delete"],
      },
      {
        apiGroups: ["ceph.rook.io"],
        resources: ["*"],
        verbs: ["*"],
      },
    ],
  },

  mgrClusterRole: kube.ClusterRole("rook-ceph-mgr-cluster") {
    metadata+: {
      labels+: {operator: "rook", "storage-backend": "ceph"},
    },
    rules: [
      {
        apiGroups: [""],
        resources: ["configmaps", "nodes", "nodes/proxy"],
        verbs: ["get", "list", "watch"],
      },
    ],
  },

  mgrSystemBinding: kube.RoleBinding("rook-ceph-mgr-system") + $.namespace {
    roleRef_: rookCephSystem.mgrSystemRole,
    subjects_+: [$.mgrSa],
  },

  mgrClusterRoleBinding: kube.ClusterRoleBinding("rook-ceph-mgr-cluster") {
    roleRef_: $.mgrClusterRole,
    subjects_+: [$.mgrSa],
  },

  mgrBinding: kube.RoleBinding("rook-ceph-mgr") + $.namespace {
    roleRef_: $.mgrRole,
    subjects_+: [$.mgrSa],
  },

  // Allow operator to create resources in this namespace too.
  cephClusterMgmtBinding: kube.RoleBinding("rook-ceph-cluster-mgmt") + $.namespace {
    roleRef_: rookCephSystem.cephClusterMgmt,
    subjects_+: [rookCephSystem.sa],
  },

  cluster: rookCephSystem.CephCluster("rook-ceph") + $.namespace {
    spec+: {
      // NB: Delete contents of this dir if recreating Cluster
      dataDirHostPath: "/var/lib/rook",
      cephVersion: {
        image: "ceph/ceph:" + cephVersion,
      },
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
    metadata+: {
      annotations+: {
        "nginx.ingress.kubernetes.io/backend-protocol": "HTTPS",
        "nginx.ingress.kubernetes.io/server-snippet": |||
          proxy_ssl_verify off;
        |||,
      },
    },
    spec+: {
      rules: [{
        host: "ceph.k.lan",
        http: {
          paths: [{
            path: "/",
            backend: {
              serviceName: "rook-ceph-mgr-dashboard",
              servicePort: 8443,
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
  replicapool: rookCephSystem.CephBlockPool("replicapool") + $.namespace {
    spec+: {
      failureDomain: "host",
      replicated: {size: 2},
    },
  },

  block: kube.StorageClass("ceph-block") {
    provisioner: "ceph.rook.io/block",
    parameters: {
      pool: $.replicapool.metadata.name,
      clusterNamespace: $.cluster.metadata.namespace,
      fstype: "ext4",
    },
  },

  // NB: Still needs provisioner + storageclass support in rook
  filesystem: rookCephSystem.CephFilesystem("ceph-filesystem") + $.namespace {
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
