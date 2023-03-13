// See https://github.com/kubernetes-incubator/external-storage

local kube = import "kube.libsonnet";
local kubecfg = import "kubecfg.libsonnet";

{
  namespace:: {metadata+: {namespace: "kube-system"}},

  storageClasses: {
    [kv[0]]: kube.StorageClass(kv[0]) {
      provisioner: "kubernetes.io/no-provisioner",
      volumeBindingMode: "WaitForFirstConsumer",
      reclaimPolicy: "Delete",
    }
    for kv in kube.objectItems($.provisioner.config.data_.storageClassMap)
  },

  provisioner: {
    serviceAccount: kube.ServiceAccount("local-storage-admin") + $.namespace,

    config: kube.ConfigMap("local-volume-config") + $.namespace {
      data_:: {
        nodeLabelsForPV_:: [
          "topology.kubernetes.io/zone",
          "topology.kubernetes.io/region",
        ],
        nodeLabelsForPV: std.set(self.nodeLabelsForPV_),
        labelsForPV: {},
        setPVOwnerRef: true,
        useJobForCleaning: false,
        useNodeNameOnly: false,
        //minResyncPeriod: "5m0s"
        storageClassMap: {
          "local-disk": {
            hostDir: "/mnt/disks",
            mountDir: self.hostDir,
            volumeMode: "Block",
            fsType: "ext4",
            namePattern: "*",
            //blockCleanerCommand: ["/scripts/shred.sh", "2"],
            blockCleanerCommand: ["/scripts/blkdiscard.sh"],
          },
        },
      },
      data: {[kv[0]]: kubecfg.manifestYaml(kv[1]) for kv in kube.objectItems(self.data_)},
    },

    role: kube.ClusterRole("local-storage-provisioner-node-clusterrole") + $.namespace {
      rules: [{
        apiGroups: [""],
        resources: ["nodes"],
        verbs: ["get"],
      }],
    },

    roleBinding: kube.ClusterRoleBinding("local-storage-provisioner-node-clusterrole") + $.namespace {
      subjects_: [$.provisioner.serviceAccount],
      roleRef_: $.provisioner.role,
    },

    pvBinding: kube.ClusterRoleBinding("local-storage-provisioner-pv-binding") + $.namespace {
      subjects_: [$.provisioner.serviceAccount],
      roleRef: {
        kind: "ClusterRole",
        apiGroup: "rbac.authorization.k8s.io",
        name: "system:persistent-volume-provisioner",
      },
    },

    deploy: kube.DaemonSet("local-volume-provisioner") + $.namespace {
      spec+: {
        template+: {
          spec+: {
            serviceAccount: $.provisioner.serviceAccount.metadata.name,
            containers_+: {
              default: kube.Container("provisioner") {
                local c = self,
                //image: "registry.k8s.io/sig-storage/local-volume-provisioner:v2.5.0", // renovate
                image: "gcr.io/k8s-staging-sig-storage/local-volume-provisioner@sha256:fed54722dc95a568756f46db8d4603c053cfaa3467b89c1c0c1f13ef6fdf4c58", // Workaround broken arm64 image in :v2.4.0
                securityContext: {privileged: true},
                volumeMounts_+: {
                  dev: {mountPath: "/dev"},
                  config: {mountPath: "/etc/provisioner/config", readOnly: true},
                } + {
                  ["vol-"+kv[0]]: {mountPath: kv[1].mountDir, mountPropagation: "HostToContainer"}
                  for kv in kube.objectItems($.provisioner.config.data_.storageClassMap)
                },
                env_+: {
                  MY_NODE_NAME: kube.FieldRef("spec.nodeName"),
                  MY_NAMESPACE: kube.FieldRef("metadata.namespace"),
                  JOB_CONTAINER_IMAGE: c.image,
                },
                ports_+: {
                  metrics: {containerPort: 8080},
                },
              },
            },
            volumes_+: {
              dev: kube.HostPathVolume("/dev"),
              config: kube.ConfigMapVolume($.provisioner.config),
            } + {
              ["vol-"+kv[0]]: kube.HostPathVolume(kv[1].hostDir, "DirectoryOrCreate")
              for kv in kube.objectItems($.provisioner.config.data_.storageClassMap)
            },
          },
        },
      },
    },
  },
}
