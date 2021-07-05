local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";

local nfs_server = "192.168.0.10"; // hostname fails to resolve (?)
local nfs_path = "/home/kube";

// FIXME: add nfs client modules to arm image
local arch = "amd64";
// renovate: depName=quay.io/external_storage/nfs-client-provisioner
local version = "v2.0.1";
local provisioner_image = "quay.io/external_storage/nfs-client-provisioner%s:%s" % [(if arch == "amd64" then "" else "-"+arch), version];

// Example use:
// kube.PersistentVolumeClaim("myclaim") {
//   storageClass: "managed-nfs-storage",
//   storage: "1Gi",
//   spec+: {
//     accessModes: ["ReadWriteMany"],
//   },
// }

{
  namespace:: {metadata+: {namespace: "kube-system"}},

  storageClass: kube.StorageClass("managed-nfs-storage") {
    provisioner: "fuseim.pri/ifs",
  },

  serviceAccount: kube.ServiceAccount("nfs-client-provisioner") + $.namespace,

  clusterRole: kube.ClusterRole("nfs-client-provisioner-runner") {
    rules: [
      {
        apiGroups: [""],
        resources: ["persistentvolumes"],
        verbs: ["get", "list", "watch", "create", "delete"],
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
        apiGroups: [""],
        resources: ["events"],
        verbs: ["list", "watch", "create", "update", "patch"],
      },
    ],
  },

  clusterRoleBinding: kube.ClusterRoleBinding("nfs-client-provisioner-runner") {
    subjects_+: [$.serviceAccount],
    roleRef_: $.clusterRole,
  },

  provisioner: kube.Deployment("nfs-client-provisioner") + $.namespace {
    spec+: {
      template+: {
        spec+: {
          local spec = self,
          serviceAccountName: $.serviceAccount.metadata.name,
	  nodeSelector+: utils.archSelector(arch),
          containers_+: {
            default: kube.Container("nfs-client-provisioner") {
              image: provisioner_image,
              volumeMounts_+: {
                root: { mountPath: "/persistentvolumes" },
              },
              env_+: {
                PROVISIONER_NAME: $.storageClass.provisioner,
                NFS_SERVER: spec.volumes_.root.nfs.server,
                NFS_PATH: spec.volumes_.root.nfs.path,
              },
            },
          },
          volumes_+: {
            root: {nfs: {server: nfs_server, path: nfs_path}},
          },
        },
      },
    },
  },
}
