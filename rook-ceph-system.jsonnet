local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";

// https://hub.docker.com/r/rook/ceph/tags
local version = "v1.0.1";

{
  namespace:: {metadata+: {namespace: "rook-ceph-system"}},
  ns: kube.Namespace($.namespace.metadata.namespace),

  cephClusterCRD: kube.CustomResourceDefinition("ceph.rook.io", "v1", "CephCluster") {
    spec+: {
      validation: {
        openAPIV3Schema: {
          properties: {
            spec: {
              properties: {
                cephVersion: {
                  properties: {
                    allowUnsupported: {type: "boolean"},
                    image: {type: "string"},
                    name: {
                      pattern: @"^(luminous|mimic|nautilus)$",
                      type: "string",
                    },
                  },
                },
                dashboard: {
                  properties: {
                    enabled: {type: "boolean"},
                    urlPrefix: {type: "string"},
                  },
                },
                dataDirHostPath: {
                  pattern: @"^/(\S+)",
                  type: "string",
                },
                mon: {
                  properties: {
                    allowMultiplePerNode: {type: "boolean"},
                    // kubecfg/apimachinery conversion bug:
                    // INFO  Updating customresourcedefinitions cephclusters.ceph.rook.io
                    // WARNING failed to parse CustomResourceDefinition: cannot convert int64 to float64
                    //count: {maximum: 9, minimum: 1, type: "integer"},
                    count: {type: "integer"},
                  },
                  required: ["count"],
                },
                network: {
                  properties: {
                    hostNetwork: {type: "boolean"},
                  },
                },
                storage: {
                  properties: {
                    nodes: {type: "array", items: {}},
                    useAllDevices: {},
                    useAllNodes: {type: "boolean"},
                  },
                },
              },
              required: ["mon"],
            },
          },
        },
      },
      additionalPrinterColumns: [
        {
          name: "DataDirHostPath",
          type: "string",
          description: "Directory used on the K8s nodes",
          JSONPath: ".spec.dataDirHostPath",
        },
        {
          name: "MonCount",
          type: "string",
          description: "Number of MONs",
          JSONPath: ".spec.mon.count",
        },
        {
          name: "Age",
          type: "date",
          JSONPath: ".metadata.creationTimestamp",
        },
        {
          name: "State",
          type: "string",
          description: "Current State",
          JSONPath: ".status.state",
        },
      ],
    },
  },

  CephCluster(name):: kube._Object("ceph.rook.io/v1", "CephCluster", name),

  cephFilesystemCRD: kube.CustomResourceDefinition("ceph.rook.io", "v1", "CephFilesystem") {
    spec+: {
      additionalPrinterColumns: [
        {
          name: "MdsCount",
          type: "string",
          description: "Number of MDSs",
          JSONPath: ".spec.metadataServer.activeCount",
        },
        {
          name: "Age",
          type: "date",
          JSONPath: ".metadata.creationTimestamp",
        },
      ],
    },
  },

  CephFilesystem(name):: kube._Object("ceph.rook.io/v1", "CephFilesystem", name),

  cephObjectStoreCRD: kube.CustomResourceDefinition("ceph.rook.io", "v1", "CephObjectStore") {
  },

  CephObjectStore(name):: kube._Object("ceph.rook.io/v1", "CephObjectStore", name),

  cephObjectStoreUserCRD: kube.CustomResourceDefinition("ceph.rook.io", "v1", "CephObjectStoreUser") {
  },

  CephObjectStoreUser(name):: kube._Object("ceph.rook.io/v1", "CephObjectStoreUser", name),

  cephBlockPoolCRD: kube.CustomResourceDefinition("ceph.rook.io", "v1", "CephBlockPool") {
  },

  CephBlockPool(name):: kube._Object("ceph.rook.io/v1", "CephBlockPool", name),

  volumeCRD: kube.CustomResourceDefinition("rook.io", "v1alpha2", "Volume") {
    spec+: {
      names+: {shortNames: ["rv"]},
    },
  },

  nfsCRD: kube.CustomResourceDefinition("ceph.rook.io", "v1", "CephNFS") {
    spec+: {
      names+: {
        plural: "cephnfses",
        shortNames+: ["nfs"],
      },
    },
  },

  sa: kube.ServiceAccount("rook-ceph-system") + $.namespace {
    metadata+: {
      labels+: {operator: "rook", "storage-backend": "ceph"},
    },
  },

  cephClusterMgmt: kube.ClusterRole("rook-ceph-cluster-mgmt") {
    metadata+: {
      labels+: {operator: "rook", "storage-backend": "ceph"},
    },
    rules: [
      {
        apiGroups: [""],
        resources: ["secrets", "pods", "pods/log", "services", "configmaps"],
        verbs: ["get", "list", "watch", "patch", "create", "update", "delete"],
      },
      {
        apiGroups: ["extensions", "apps"],
        resources: ["deployments", "daemonsets"],
        verbs: ["get", "list", "watch", "create", "update", "delete"],
      },
    ],
  },

  cephSystem: kube.Role("rook-ceph-system") + $.namespace {
    metadata+: {
      labels+: {operator: "rook", "storage-backend": "ceph"},
    },
    rules: [
      {
        apiGroups: [""],
        resources: ["pods", "configmaps", "services"],
        verbs: ["get", "list", "watch", "patch", "create", "update", "delete"],
      },
      {
        apiGroups: ["extensions", "apps"],
        resources: ["daemonsets", "statefulsets"],
        verbs: ["get", "list", "watch", "create", "update", "delete"],
      },
    ],
  },

  cephGlobal: kube.ClusterRole("rook-ceph-global") {
    metadata+: {
      labels+: {operator: "rook", "storage-backend": "ceph"},
    },
    rules: [
      {
        apiGroups: [""],
        resources: ["pods", "nodes", "nodes/proxy"],
        verbs: ["get", "list", "watch"],
      },
      {
        apiGroups: [""],
        resources: ["events", "persistentvolumes", "persistentvolumeclaims", "endpoints"],
        verbs: ["get", "list", "watch", "patch", "create", "update", "delete"],
      },
      {
        apiGroups: ["storage.k8s.io"],
        resources: ["storageclasses"],
        verbs: ["get", "list", "watch"],
      },
      {
        apiGroups: ["batch"],
        resources: ["jobs"],
        verbs: ["get", "list", "watch", "create", "update", "delete"],
      },
      {
        apiGroups: ["ceph.rook.io", "rook.io"],
        resources: ["*"],
        verbs: ["*"],
      },
    ],
  },

  mgrSystemRole: kube.ClusterRole("rook-ceph-mgr-system") {
    rules: [
      {
        apiGroups: [""],
        resources: ["configmaps"],
        verbs: ["get", "list", "watch"],
      },
    ],
  },

  cephSystemBinding: kube.RoleBinding("rook-ceph-system") + $.namespace {
    metadata+: {
      labels+: {operator: "rook", "storage-backend": "ceph"},
    },
    roleRef_: $.cephSystem,
    subjects_+: [$.sa],
  },

  cephGlobalBinding: kube.ClusterRoleBinding("rook-ceph-global") {
    metadata+: {
      labels+: {operator: "rook", "storage-backend": "ceph"},
    },
    roleRef_: $.cephGlobal,
    subjects_+: [$.sa],
  },

  deploy: kube.Deployment("rook-ceph-operator") + $.namespace {
    metadata+: {
      labels+: {operator: "rook", "storage-backend": "ceph"},
    },
    spec+: {
      template+: {
        spec+: {
          serviceAccountName: $.sa.metadata.name,
          volumes_+: {
            config: kube.EmptyDirVolume(),
            configdir: kube.EmptyDirVolume(),
          },
          nodeSelector+: utils.archSelector("amd64"),
          containers_+: {
            operator: kube.Container("operator") {
              image: "rook/ceph:" + version,
              args: ["ceph", "operator"],
              volumeMounts_+: {
                config: {mountPath: "/var/lib/rook"},
                configdir: {mountPath: "/etc/ceph"},
              },
              env_+: {
                FLEXVOLUME_DIR_PATH: "/var/lib/kubelet/volumeplugins",
                ROOK_ALLOW_MULTIPLE_FILESYSTEMS: "false",
                ROOK_LOG_LEVEL: "INFO",
                ROOK_MON_HEALTHCHECK_INTERVAL: "45s",
                ROOK_MON_OUT_TIMEOUT: "600s",
                ROOK_HOSTPATH_REQUIRES_PRIVILEGED: "false",
                ROOK_ENABLE_SELINUX_RELABELING: "false",
                ROOK_ENABLE_FSGROUP: "true",
                NODE_NAME: kube.FieldRef("spec.nodeName"),
                POD_NAME: kube.FieldRef("metadata.name"),
                POD_NAMESPACE: kube.FieldRef("metadata.namespace"),
              },
            },
          },
        },
      },
    },
  },
}
