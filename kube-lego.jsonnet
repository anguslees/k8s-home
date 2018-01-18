local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";

{
  namespace:: {metadata+: {namespace: "kube-lego"}},

  ns: kube.Namespace($.namespace.metadata.namespace),

  serviceAccount: kube.ServiceAccount("kube-lego") + $.namespace,

  legoClusterRole: kube.ClusterRole("kube-lego") {
    rules: [
      {
        apiGroups: [""],
        resources: ["services"],
        verbs: ["create", "get", "delete", "update"],
      },
      {
        apiGroups: ["extensions"],
        resources: ["ingresses"],
        verbs: ["get", "list", "watch", "update", "create", "patch", "delete"],
      },
      {
        apiGroups: [""],
        resources: ["endpoints", "secrets"],
        verbs: ["get", "create", "update"],
      },
    ],
  },

  legoClusterRoleBinding: kube.ClusterRoleBinding("kube-lego") {
    roleRef_: $.legoClusterRole,
    subjects_: [$.serviceAccount],
  },

  config: kube.ConfigMap("kube-lego") + $.namespace {
    data+: {
      "lego.email": "guslees+lego@gmail.com",

      // If you change the LEGO_URL, it is required that you delete
      // the existing secret kube-lego-account and all certificates
      // you want to request from the new URL.
      //"lego.url": "https://acme-staging.api.letsencrypt.org/directory",
      "lego.url": "https://acme-v01.api.letsencrypt.org/directory",
    },
  },

  deploy: kube.Deployment("kube-lego") + $.namespace {
    metadata+: {
      // Required for generated kube-lego-nginx Service selector
      labels+: {app: "kube-lego"},
    },
    spec+: {
      template+: {
        spec+: {
          serviceAccountName: $.serviceAccount.metadata.name,
          nodeSelector+: utils.archSelector("amd64"),
          containers_+: {
            default: kube.Container("kube-lego") {
              image: "jetstack/kube-lego:0.1.5",
              ports_+: {
                http: {containerPort: 8080},
              },
              env_+: {
                LEGO_EMAIL: kube.ConfigMapRef($.config, "lego.email"),
                LEGO_URL: kube.ConfigMapRef($.config, "lego.url"),
                LEGO_NAMESPACE: kube.FieldRef("metadata.namespace"),
                LEGO_POD_IP: kube.FieldRef("status.podIP"),
                LEGO_SUPPORTED_INGRESS_CLASS: "nginx,nginx-internal",
                LEGO_DEFAULT_INGRESS_PROVIDER: "nginx",
              },
              readinessProbe: {
                httpGet: {path: "/healthz", port: 8080},
                initialDelaySeconds: 5,
                timeoutSeconds: 1,
              },
            },
          },
        },
      },
    },
  },
}
