local kube = import "kube.libsonnet";

{
  namespace:: {metadata+: {namespace: "rook-ceph-system"}},
  ns: kube.Namespace($.namespace.metadata.namespace),

  clusterCRD: kube.CustomResourceDefinition("ceph.rook.io", "v1beta1", "Cluster") {
    spec+: {
      names+: {
        shortNames: ["rcc"],
      },
    },
  },

  Cluster(name):: kube._Object("ceph.rook.io/v1beta1", "Cluster", name),

  filesystemCRD: kube.CustomResourceDefinition("ceph.rook.io", "v1beta1", "Filesystem") {
    spec+: {
      names+: {
        shortNames: ["rcfs"],
      },
    },
  },

  Filesystem(name):: kube._Object("ceph.rook.io/v1beta1", "Filesystem", name),

  objectstoreCRD: kube.CustomResourceDefinition("ceph.rook.io", "v1beta1", "ObjectStore") {
    spec+: {
      names+: {
        shortNames: ["rco"],
      },
    },
  },

  ObjectStore(name):: kube._Object("ceph.rook.io/v1beta1", "ObjectStore", name),

  poolCRD: kube.CustomResourceDefinition("ceph.rook.io", "v1beta1", "Pool") {
    spec+: {
      names+: {
        shortNames: ["rcp"],
      },
    },
  },

  Pool(name):: kube._Object("ceph.rook.io/v1beta1", "Pool", name),

  volumeCRD: kube.CustomResourceDefinition("rook.io", "v1alpha2", "Volume") {
    spec+: {
      names+: {
        shortNames: ["rv"],
      },
    },
  },

  Volume(name):: kube._Object("ceph.rook.io/v1beta1", "Volume", name),

  cephClusterMgmt: kube.ClusterRole("rook-ceph-cluster-mgmt") {
    metadata+: {
      labels+: {operator: "rook", "storage-backend": "ceph"},
    },
    rules: [
      {
        apiGroups: [""],
        resources: ["secrets", "pods", "services", "configmaps"],
        verbs: ["get", "list", "watch", "patch", "create", "update", "delete"],
      },
      {
        apiGroups: ["extensions", "apps"],
        resources: ["deployments", "daemonsets", "replicasets"],
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
        resources: ["pods", "configmaps"],
        verbs: ["get", "list", "watch", "patch", "create", "update", "delete"],
      },
      {
        apiGroups: ["extensions", "apps"],
        resources: ["daemonsets"],
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
        resources: ["events", "persistentvolumes", "persistentvolumeclaims"],
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
        apiGroups: ["ceph.rook.io"],
        resources: ["*"],
        verbs: ["*"],
      },
      {
        // NB: This is not in upstream.  Possibly workaround for:
          //  failed to run operator. failed to list legacy volume attachments: volumeattachments.rook.io is forbidden: User "system:serviceaccount:rook-ceph-system:rook-ceph-system" cannot list volumeattachments.rook.io in the namespace "rook-ceph-system"
        // and
        //    op-cluster: failed finalizer for cluster. failed to get volume attachments for operator namespace rook-ceph-system: volumes.rook.io is forbidden: User "system:serviceaccount:rook-ceph-system:rook-ceph-system" cannot list volumes.rook.io in the namespace "rook-ceph-system"
        // and
        //    MountVolume.SetUp failed for volume "pvc-84d2422b-a758-11e8-99a2-02030782ac80" : mount command failed, status: Failure, reason: Rook: Mount volume failed: failed to create volume CRD pvc-84d2422b-a758-11e8-99a2-02030782ac80. volumes.rook.io is forbidden: User "system:serviceaccount:rook-ceph-system:rook-ceph-system" cannot create volumes.rook.io in the namespace "rook-ceph-system"
        apiGroups: ["rook.io"],
        resources: ["volumeattachments", "volumes"],
        verbs: ["get", "list", "watch", "patch", "create", "update", "delete"],
      },
    ],
  },

  sa: kube.ServiceAccount("rook-ceph-system") + $.namespace {
    metadata+: {
      labels+: {operator: "rook", "storage-backend": "ceph"},
    },
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
          containers_+: {
            operator: kube.Container("operator") {
              image: "rook/ceph:v0.8.3",
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
                ROOK_MON_OUT_TIMEOUT: "300s",
                ROOK_HOSTPATH_REQUIRES_PRIVILEGED: "false",
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
