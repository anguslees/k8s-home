local kube = import "kube.libsonnet";

local arch = "arm";
local version = "v1.7.1";

{
  namespace:: {
    metadata+: { namespace: "kube-system" },
  },

  serviceAccount: kube.ServiceAccount("kubernetes-dashboard") + $.namespace,

  clusterRoleBinding: kube.ClusterRoleBinding("kubernetes-dashboard") {
    roleRef: {
      apiGroup: "rbac.authorization.k8s.io",
      kind: "ClusterRole",
      name: "cluster-admin",
    },
    subjects_: [$.serviceAccount],
  },

  service: kube.Service("kubernetes-dashboard") + $.namespace {
    metadata+: {
      labels+: {
        "kubernetes.io/cluster-service": "true",
        "kubernetes.io/name": "Dashboard",
      },
    },
    target_pod: $.deployment.spec.template,
    port: 80,
  },

  deployment: kube.Deployment("kubernetes-dashboard") + $.namespace {
    spec+: {
      template+: {
        spec+: {
          serviceAccountName: $.serviceAccount.metadata.name,
          /*
          tolerations+: [{
            key: "node-role.kubernetes.io/master",
            operator: "Exists",
            effect: "NoSchedule",
          }],
          */
	  nodeSelector: {
	    "beta.kubernetes.io/arch": arch,
	  },
          containers_+: {
            default: kube.Container("kubernetes-dashboard") {
              image: "gcr.io/google_containers/kubernetes-dashboard-%s:%s" % [arch, version],
              ports_+: {
                default: { containerPort: 9090 },
              },
              resources+: {
                limits: { cpu: "100m", memory: "300Mi" },
              },
              livenessProbe: {
                httpGet: { path: "/", port: 9090 },
                initialDelaySeconds: 30,
                timeoutSeconds: 30,
              },
            },
          },
        },
      },
    },
  },
}
