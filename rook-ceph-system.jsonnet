local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";

// https://hub.docker.com/r/rook/ceph/tags
local version = "v1.1.9";

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
                annotations: {},
                cephVersion: {
                  properties: {
                    allowUnsupported: {type: "boolean"},
                    image: {type: "string"},
                  },
                },
                dashboard: {
                  properties: {
                    enabled: {type: "boolean"},
                    urlPrefix: {type: "string"},
                    port: {
                      type: "integer",
                      // WARNING failed to parse CustomResourceDefinition: cannot convert int64 to float64
                      //minimum: 0.0, maximum: 65535.0,
                    },
                    ssl: {type: "boolean"},
                  },
                },
                dataDirHostPath: {
                  pattern: @"^/(\S+)",
                  type: "string",
                },
                skipUpgradeChecks: {type: "boolean"},
                mon: {
                  properties: {
                    allowMultiplePerNode: {type: "boolean"},
                    // kubecfg/apimachinery conversion bug:
                    // INFO  Updating customresourcedefinitions cephclusters.ceph.rook.io
                    // WARNING failed to parse CustomResourceDefinition: cannot convert int64 to float64
                    //count: {maximum: 9, minimum: 0, type: "integer"},
                    count: {type: "integer"},
                  },
                },
                mgr: {
                  properties: {
                    modules: {
                      type: "array",
                      items: {
                        properties: {
                          name: {type: "string"},
                          enabled: {type: "boolean"},
                        },
                      },
                    },
                  },
                },
                network: {
                  properties: {
                    hostNetwork: {type: "boolean"},
                  },
                },
                storage: {
                  properties: {
                    disruptionManagement: {
                      properties: {
                        managePodBudgets: {type: "boolean"},
                        osdMaintenanceTimeout: {type: "integer"},
                        manageMachineDisruptionBudgets: {type: "boolean"},
                      },
                    },
                    useAllNodes: {type: "boolean"},
                    nodes: {
                      type: "array",
                      items: {
                        properties: {
                          name: {type: "string"},
                          config: {
                            properties: {
                              metadataDevice: {type: "string"},
                              storeType: {type: "string", pattern: @"^(filestore|bluestore)$"},
                              databaseSizeMB: {type: "string"},
                              walSizeMB: {type: "string"},
                              journalSizeMB: {type: "string"},
                              osdsPerDevice: {type: "string"},
                              encryptedDevice: {type: "string", pattern: @"^(true|false)$"},
                            },
                          },
                          useAllDevices: {type: "boolean"},
                          deviceFilter: {},
                          directories: {
                            type: "array",
                            items: {
                              properties: {
                                path: {type: "string"},
                              },
                            },
                          },
                          devices: {
                            type: "array",
                            items: {
                              properties: {
                                name: {type: "string"},
                                config: {},
                              },
                            },
                          },
                          location: {},
                          resources: {},
                        },
                      },
                    },
                    useAllDevices: {type: "boolean"},
                    deviceFilter: {},
                    location: {},
                    directories: {
                      type: "array",
                      items: {
                        properties: {
                          path: {type: "string"},
                        },
                      },
                    },
                    config: {},
                    topologyAware: {type: "boolean"},
                  },
                },
                monitoring: {
                  properties: {
                    enabled: {type: "boolean"},
                    rulesNamespace: {type: "string"},
                  },
                },
                rbdMirroring: {
                  properties: {
                    workers: {type: "integer"},
                  },
                },
                placement: {},
                resources: {},
              },
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
        {
          name: "Health",
          type: "string",
          description: "Ceph Health",
          JSONPath: ".status.ceph.health",
        },
      ],
    },
  },

  CephCluster(name):: kube._Object("ceph.rook.io/v1", "CephCluster", name),

  cephFilesystemCRD: kube.CustomResourceDefinition("ceph.rook.io", "v1", "CephFilesystem") {
    spec+: {
      validation: {
        openAPIV3Schema: {
          properties: {
            spec: {
              properties: {
                metadataServer: {
                  properties: {
                    activeCount: {type: "integer"},
                    activeStandby: {type: "boolean"},
                    annotations: {},
                    placement: {},
                    resources: {},
                  },
                },
                metadataPool: {
                  properties: {
                    failureDomain: {type: "string"},
                    replicated: {
                      properties: {
                        size: {type: "integer"},
                      },
                    },
                    erasureCoded: {
                      properties: {
                        dataChunks: {type: "integer"},
                        codingChunks: {type: "integer"},
                      },
                    },
                  },
                },
                dataPools: {
                  type: "array",
                  items: {
                    properties: {
                      failureDomain: {type: "string"},
                      replicated: {
                        properties: {
                          size: {type: "integer"},
                        },
                      },
                      erasureCoded: {
                        properties: {
                          dataChunks: {type: "integer"},
                          codingChunks: {type: "integer"},
                        },
                      },
                    },
                  },
                },
              },
            },
          },
        },
      },
      additionalPrinterColumns: [
        {
          name: "ActiveMDS",
          type: "string",
          description: "Number of desired active MDS daemons",
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

  objectBucketCRD: kube.CustomResourceDefinition("objectbucket.io", "v1alpha1", "ObjectBucket") {
    spec+: {
      scope: "Cluster",
      names+: {
        shortNames+: ["ob", "obs"],
      },
      subresources: {status: {}},
    },
  },

  objectBucketClaimsCRD: kube.CustomResourceDefinition("objectbucket.io", "v1alpha1", "ObjectBucketClaim") {
    spec+: {
      names+: {
        shortNames+: ["obc", "obcs"],
      },
      subresources: {status: {}},
    },
  },

  sa: kube.ServiceAccount("rook-ceph-system") + $.namespace {
    metadata+: {
      labels+: {operator: "rook", "storage-backend": "ceph"},
    },
  },

  objectBucketRole: kube.ClusterRole("rook-ceph-object-bucket") {
    metadata+: {
      labels+: {
        operator: "rook",
        "storage-backend": "ceph",
        "rbac.ceph.rook.io/aggregate-to-rook-ceph-mgr-cluster": "true",
      },
    },
    rules: [
      {
        apiGroups: [""],
        resources: ["secrets", "configmaps"],
        verbs: ["get", "list", "watch", "create", "update", "delete"],
      },
      {
        apiGroups: ["storage.k8s.io"],
        resources: ["storageclasses"],
        verbs: ["get", "list", "watch"],
      },
      {
        apiGroups: ["objectbucket.io"],
        resources: ["*"],
        verbs: ["*"],
      },
    ],
  },

  objectBucketBinding: kube.ClusterRoleBinding("rook-ceph-object-bucket") {
    roleRef_: $.objectBucketRole,
    subjects_+: [$.sa],
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
        resources: ["daemonsets", "statefulsets", "deployments"],
        verbs: ["get", "list", "watch", "create", "update", "delete"],
      },
    ],
  },

  cephGlobal: kube.ClusterRole("rook-ceph-global") {
    aggregationRule: {
      clusterRoleSelectors: [{
        matchLabels: {
          "rbac.ceph.rook.io/aggregate-to-rook-ceph-global": "true",
        },
      }],
    },
    rules:: null, // filled by aggregation controller
  },

  cephGlobalRules: kube.ClusterRole("rook-ceph-global-rules") {
    metadata+: {
      labels+: {
        operator: "rook",
        "storage-backend": "ceph",
        "rbac.ceph.rook.io/aggregate-to-rook-ceph-global": "true",
      },
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
      {
        apiGroups: ["policy"],
        resources: ["poddisruptionbudgets"],
        verbs: ["get", "list", "watch", "create", "update", "delete"],
      },
      {
        apiGroups: ["apps"],
        resources: ["deployments"],
        verbs: ["get", "list", "watch", "delete"],
      },
      {
        apiGroups: ["healthchecking.openshift.io"],
        resources: ["machinedisruptionbudgets"],
        verbs: ["get", "list", "watch", "create", "update", "delete"],
      },
      {
        apiGroups: ["machine.openshift.io"],
        resources: ["machines"],
        verbs: ["get", "list", "watch", "create", "update", "delete"],
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

  csiSa: kube.ServiceAccount("rook-csi-cephfs-plugin-sa") + $.namespace,
  csiProvisionerSa: kube.ServiceAccount("rook-csi-cephfs-provisioner-sa") + $.namespace,

  extProvisionerCfg: kube.Role("cephfs-external-provisioner-cfg") + $.namespace {
    rules: [
      {
        apiGroups: [""],
        resources: ["endpoints"],
        verbs: ["get", "watch", "list", "delete", "update", "create"],
      },
      {
        apiGroups: [""],
        resources: ["configmaps"],
        verbs: ["get", "list", "create", "delete"],
      },
      {
        apiGroups: ["coordination.k8s.io"],
        resources: ["leases"],
        verbs: ["get", "watch", "list", "delete", "update", "create"],
      },
    ],
  },

  extProvisionerCfgBinding: kube.RoleBinding("cephfs-csi-provisioner-role-cfg") + $.namespace {
    roleRef_: $.extProvisionerCfg,
    subjects_+: [$.csiProvisionerSa],
  },

  csiNodepluginRole: kube.ClusterRole("cephfs-csi-nodeplugin") {
    aggregationRule: {
      clusterRoleSelectors: [{
        matchLabels: {
          "rbac.ceph.rook.io/aggregate-to-cephfs-csi-nodeplugin": "true",
        },
      }],
    },
    rules:: null, // filled by aggregation controller
  },

  csiNodepluginRules: kube.ClusterRole("cephfs-csi-nodeplugin-rules") {
    metadata+: {
      labels+: {
        "rbac.ceph.rook.io/aggregate-to-cephfs-csi-nodeplugin": "true",
      },
    },
    rules: [
      {
        apiGroups: [""],
        resources: ["nodes"],
        verbs: ["get", "list", "update"],
      },
      {
        apiGroups: [""],
        resources: ["namespaces"],
        verbs: ["get", "list"],
      },
      {
        apiGroups: [""],
        resources: ["persistentvolumes"],
        verbs: ["get", "list", "watch", "update"],
      },
      {
        apiGroups: ["storage.k8s.io"],
        resources: ["volumeattachments"],
        verbs: ["get", "list", "watch", "update"],
      },
      {
        apiGroups: [""],
        resources: ["configmaps"],
        verbs: ["get", "list"],
      },
    ],
  },

  provisionerRole: kube.ClusterRole("cephfs-external-provisioner-runner") {
    aggregationRule: {
      clusterRoleSelectors: [{
        matchLabels: {
          "rbac.ceph.rook.io/aggregate-to-cephfs-external-provisioner-runner": "true",
        },
      }],
    },
    rules:: null, // filled by aggregation controller
  },

  provisionerRoleRules: kube.ClusterRole("cephfs-external-provisioner-runner-rules") {
    metadata+: {
      labels+: {
        "rbac.ceph.rook.io/aggregate-to-cephfs-external-provisioner-runner": "true",
      },
    },
    rules: [
      {
        apiGroups: [""],
        resources: ["secrets"],
        verbs: ["get", "list"],
      },
      {
        apiGroups: [""],
        resources: ["persistentvolumes"],
        verbs: ["get", "list", "watch", "create", "delete", "update"],
      },
      {
        apiGroups: [""],
        resources: ["persistentvolumeclaims"],
        verbs: ["get", "list", "watch", "update"],
      },
      {
        apiGroups: ["storage.k8s.io"],
        resources: ["storageclasses"],
        verbs: ["get", "list", "watch"],
      },
      {
        apiGroups: ["storage.k8s.io"],
        resources: ["volumeattachments"],
        verbs: ["get", "list", "watch", "update"],
      },
      {
        apiGroups: [""],
        resources: ["events"],
        verbs: ["get", "list", "watch", "update", "create", "patch"],
      },
      {
        apiGroups: [""],
        resources: ["nodes"],
        verbs: ["get", "list", "watch"],
      },
    ],
  },

  csiNodepluginBinding: kube.ClusterRoleBinding("cephfs-csi-nodeplugin") {
    roleRef_: $.csiNodepluginRole,
    subjects_+: [$.csiSa],
  },

  csiProvisionerBinding: kube.ClusterRoleBinding("cephfs-csi-provisioner-role") {
    roleRef_: $.provisionerRole,
    subjects_+: [$.csiProvisionerSa],
  },

  csiRbdSa: kube.ServiceAccount("rook-csi-rbd-plugin-sa") + $.namespace,
  csiRbdProvisionerSa: kube.ServiceAccount("rook-csi-rbd-provisioner-sa") + $.namespace,

  rbdExtProvisionerCfg: kube.Role("rbd-external-provisioner-cfg") + $.namespace {
    rules: [
      {
        apiGroups: [""],
        resources: ["endpoints"],
        verbs: ["get", "watch", "list", "delete", "update", "create"],
      },
      {
        apiGroups: [""],
        resources: ["configmaps"],
        verbs: ["get", "list", "watch", "create", "delete"],
      },
      {
        apiGroups: ["coordination.k8s.io"],
        resources: ["leases"],
        verbs: ["get", "watch", "list", "delete", "update", "create"],
      },
    ],
  },

  rbdExtProvisionerCfgBinding: kube.RoleBinding("rbd-csi-provisioner-role-cfg") + $.namespace {
    roleRef_: $.rbdExtProvisionerCfg,
    subjects_+: [$.csiRbdProvisionerSa],
  },

  rbdNodepluginRole: kube.ClusterRole("rbd-csi-nodeplugin") {
    aggregationRule: {
      clusterRoleSelectors: [{
        matchLabels: {
          "rbac.ceph.rook.io/aggregate-to-rbd-csi-nodeplugin": "true",
        },
      }],
    },
    rules:: null, // filled by aggregation controller
  },

  rbdNodepluginRoleRules: kube.ClusterRole("rbd-csi-nodeplugin-rules") {
    metadata+: {
      labels+: {
        "rbac.ceph.rook.io/aggregate-to-rbd-csi-nodeplugin": "true",
      },
    },
    rules: [
      {
        apiGroups: [""],
        resources: ["secrets"],
        verbs: ["get", "list"],
      },
      {
        apiGroups: [""],
        resources: ["nodes"],
        verbs: ["get", "list", "update"],
      },
      {
        apiGroups: [""],
        resources: ["namespaces"],
        verbs: ["get", "list"],
      },
      {
        apiGroups: [""],
        resources: ["persistentvolumes"],
        verbs: ["get", "list", "watch", "update"],
      },
      {
        apiGroups: ["storage.k8s.io"],
        resources: ["volumeattachments"],
        verbs: ["get", "list", "watch", "update"],
      },
      {
        apiGroups: [""],
        resources: ["configmaps"],
        verbs: ["get", "list"],
      },
    ],
  },

  rbdExtProvisionerRole: kube.ClusterRole("rbd-external-provisioner-runner") {
    aggregationRule: {
      clusterRoleSelectors: [{
        matchLabels: {
          "rbac.ceph.rook.io/aggregate-to-rbd-external-provisioner-runner": "true",
        },
      }],
    },
    rules:: null, // filled by aggregation controller
  },

  rbdExtProvisionerRoleRules: kube.ClusterRole("rbd-external-provisioner-runner-rules") {
    metadata+: {
      labels+: {
        "rbac.ceph.rook.io/aggregate-to-rbd-external-provisioner-runner": "true",
      },
    },
    rules: [
      {
        apiGroups: [""],
        resources: ["secrets"],
        verbs: ["get", "list"],
      },
      {
        apiGroups: [""],
        resources: ["persistentvolumes"],
        verbs: ["get", "list", "watch", "create", "delete", "update"],
      },
      {
        apiGroups: [""],
        resources: ["persistentvolumeclaims"],
        verbs: ["get", "list", "watch", "update"],
      },
      {
        apiGroups: ["storage.k8s.io"],
        resources: ["volumeattachments"],
        verbs: ["get", "list", "watch", "update"],
      },
      {
        apiGroups: [""],
        resources: ["nodes"],
        verbs: ["get", "list", "watch"],
      },
      {
        apiGroups: ["storage.k8s.io"],
        resources: ["storageclasses"],
        verbs: ["get", "list", "watch"],
      },
      {
        apiGroups: [""],
        resources: ["events"],
        verbs: ["list", "watch", "create", "update", "patch"],
      },
      {
        apiGroups: ["snapshot.storage.k8s.io"],
        resources: ["volumesnapshots"],
        verbs: ["get", "list", "watch", "update"],
      },
      {
        apiGroups: ["snapshot.storage.k8s.io"],
        resources: ["volumesnapshotcontents"],
        verbs: ["create", "get", "list", "watch", "update", "delete"],
      },
      {
        apiGroups: ["snapshot.storage.k8s.io"],
        resources: ["volumesnapshotclasses"],
        verbs: ["get", "list", "watch"],
      },
      {
        apiGroups: ["apiextensions.k8s.io"],
        resources: ["customresourcedefinitions"],
        verbs: ["create", "list", "watch", "delete", "get", "update"],
      },
      {
        apiGroups: ["snapshot.storage.k8s.io"],
        resources: ["volumesnapshots/status"],
        verbs: ["update"],
      },
    ],
  },

  rbdNodepluginBinding: kube.ClusterRoleBinding("rbd-csi-nodeplugin") {
    roleRef_: $.rbdNodepluginRole,
    subjects_+: [$.csiRbdSa],
  },

  rbdExtProvisionerBinding: kube.ClusterRoleBinding("rbd-csi-provisioner-role") {
    roleRef_: $.rbdExtProvisionerRole,
    subjects_+: [$.csiRbdProvisionerSa],
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
          priorityClassName: "high",
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
                ROOK_MON_OUT_TIMEOUT: "20m", // Default 10m
                ROOK_HOSTPATH_REQUIRES_PRIVILEGED: "false",
                ROOK_ENABLE_SELINUX_RELABELING: "false",
                ROOK_ENABLE_FSGROUP: "true",
                NODE_NAME: kube.FieldRef("spec.nodeName"),
                POD_NAME: kube.FieldRef("metadata.name"),
                POD_NAMESPACE: kube.FieldRef("metadata.namespace"),
              },
              resources+: {
                requests: {cpu: "100m", memory: "150Mi"},
              },
            },
          },
        },
      },
    },
  },
}
