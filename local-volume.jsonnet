// See https://github.com/kubernetes-incubator/external-storage

local kube = import "kube.libsonnet";
local kubecfg = import "kubecfg.libsonnet";

{
  namespace:: {metadata+: {namespace: "kube-system"}},

  storageClass: kube.StorageClass("local-storage") {
    provisioner: "kubernetes.io/no-provisioner",
    volumeBindingMode: "WaitForFirstConsumer",
  },

  local escape(str) = kubecfg.regexSubst("[^a-z0-9]+", str, "-"),

  local mypv(id, host) = kube.PersistentVolume("local-pv-%s-%s" % [host, id]) {
    spec+: {
      capacity: {storage: "100Gi"},
      accessModes: ["ReadWriteOnce"],
      persistentVolumeReclaimPolicy: "Retain", // assume precious
      storageClassName: $.storageClass.metadata.name,
      volumeMode: "Filesystem",
      "local": {path: "/var/lib/local-data/%s" % id},
      nodeAffinity: {
        required: {
          nodeSelectorTerms: [{
            matchExpressions: [{
              key: "kubernetes.io/hostname",
              operator: "In",
              values: [host],
            }],
          }],
        },
      },
    },
  },

  volumes: {
    //etcd0: mypv("001", "fc4698cdc1184810a2c3447a7ee66689"),
    //etcd1: mypv("001", "e5b2509083d942b5909c7b32e0460c54"),
    //etcd2: mypv("001", "0b5642a6cc18493d81a606483d9cbb7b"),
  },

  // Disabled for now. Config needs updating too.
  provisioner:: {
    serviceAccount: kube.ServiceAccount("local-storage-admin") + $.namespace,

    config: kube.ConfigMap("local-volume-config") + $.namespace {
      data: {
        nodeLabelsForPv_:: [
          "failure-domain.beta.kubernetes.io/zone",
          "failure-domain.beta.kubernetes.io/region",
        ],
        nodeLabelsForPv: kubecfg.manifestYaml(self.nodeLabelsForPv_),
      },
    },

    provisionerPvBinding: kube.ClusterRoleBinding("local-storage-provisioner-pv-binding") + $.namespace {
      subjects_: [$.provisioner.serviceAccount],
      roleRef: {
        kind: "ClusterRole",
        apiGroup: "rbac.authorization.k8s.io",
        name: "system:persistent-volume-provisioner",
      },
    },

    provisionerNodeBinding: kube.ClusterRoleBinding("local-storage-provisioner-node-binding") + $.namespace {
      subjects_: [$.provisioner.serviceAccount],
      roleRef: {
        kind: "ClusterRole",
        apiGroup: "rbac.authorization.k8s.io",
        name: "system:node",
      },
    },

    provisioner: kube.DaemonSet("local-volume-provisioner") + $.namespace {
      spec+: {
        template+: {
          spec+: {
            serviceAccount: $.provisioner.serviceAccount.metadata.name,
            containers_+: {
              default: kube.Container("provisioner") {
                image: "quay.io/external_storage/local-volume-provisioner:v1.0.1", // renovate
                securityContext: {privileged: true},
                volumeMounts_+: {
                  discovery: {mountPath: "/local-disks"},
                },
                env_+: {
                  MY_NODE_NAME: kube.FieldRef("spec.nodeName"),
                },
              },
            },
            volumes_+: {
              discovery: kube.HostPathVolume("/mnt/disks"),
            },
          },
        },
      },
    },
  },
}
