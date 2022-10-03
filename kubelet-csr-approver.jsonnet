local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";

local arch = "amd64";

{
  namespace:: {
    metadata+: { namespace: "kube-system" },
  },

  sa: kube.ServiceAccount("kubelet-csr-approver") + $.namespace,

  role: kube.ClusterRole("kubelet-csr-approver") {
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
        verbs: ["update"],
      },
    ],
  },

  roleBinding: kube.ClusterRoleBinding("kubelet-csr-approver") {
    subjects_+: [$.sa],
    roleRef_: $.role,
  },

  deploy: kube.Deployment("kubelet-csr-approver") + $.namespace {
    spec+: {
      template+: utils.PromScrape(8080) + {
        spec+: {
          serviceAccountName: $.sa.metadata.name,
          priorityClassName: "system-cluster-critical",
          tolerations+: utils.toleratesMaster,
          containers_+: {
            approver: kube.Container("kubelet-csr-approver") {
              image: "postfinance/kubelet-csr-approver:v0.2.4", // renovate
              args_: {
                "metrics-bind-address": ":8080",
                "health-probe-bind-address": ":8081",
                "bypass-dns-resolution": true,
                "max-expiration-sec": 367 * 86400, // 367 days
                "provider-regex": "^[0-9a-f]{32}$",
              },
              env_+: {
                GOGC: "25",
              },
              livenessProbe: {
                httpGet: {path: "/healthz", port: 8081},
                timeoutSeconds: 30,
                periodSeconds: 30,
              },
              startupProbe: self.livenessProbe {
                local timeoutSeconds = 5 * 60,
                failureThreshold: std.ceil(timeoutSeconds / self.periodSeconds),
              },
              readinessProbe: self.livenessProbe {
                failureThreshold: 3,
              },
              resources+: {
                requests: {memory: "40Mi", cpu: "10m"},
              },
            },
          },
        },
      },
    },
  },
}
