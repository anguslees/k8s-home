local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";

local arch = "amd64";

{
  namespace:: {
    metadata+: { namespace: "kube-system" },
  },

  sa: kube.ServiceAccount("kubelet-rubber-stamp") + $.namespace,

  role: kube.ClusterRole("kubelet-rubber-stamp") {
    rules: [
      {
        apiGroups: ["certificates.k8s.io"],
        resources: ["signers"],
        resourceNames: [
          //"kubernetes.io/legacy-unknown", // pre k8s-1.18
          "kubernetes.io/kubelet-serving",
        ],
        verbs: ["approve"],
      },
      {
        apiGroups: ["certificates.k8s.io"],
        resources: ["certificatesigningrequests"],
        verbs: ["get", "list", "watch"],
      },
      {
        apiGroups: ["certificates.k8s.io"],
        resources: ["certificatesigningrequests/approval"],
        verbs: ["create", "update"],
      },
      {
        apiGroups: ["authorization.k8s.io"],
        resources: ["subjectaccessreviews"],
        verbs: ["create"],
      },
    ],
  },

  roleBinding: kube.ClusterRoleBinding("kubelet-rubber-stamp") {
    subjects_+: [$.sa],
    roleRef_: $.role,
  },

  deploy: kube.Deployment("kubelet-rubber-stamp") + $.namespace {
    spec+: {
      template+: {
        spec+: {
          serviceAccountName: $.sa.metadata.name,
          priorityClassName: "system-cluster-critical",
          nodeSelector+: utils.archSelector(arch),
          containers_+: {
            stamp: kube.Container("kubelet-rubber-stamp") {
              // renovate: depName=quay.io/kontena/kubelet-rubber-stamp-amd64
              local version = "0.3.1",
              image: "quay.io/kontena/kubelet-rubber-stamp-%s:%s" % [arch, version],
              args_: {
                v: 2,
              },
              env_: {
                WATCH_NAMESPACE: "",
                OPERATOR_NAME: $.deploy.metadata.name,
                POD_NAME: kube.FieldRef("metadata.name"),
              },
            },
          },
        },
      },
    },
  },
}
