local kube = import "kube.libsonnet";

local email = "guslees+lego@gmail.com";

{
  namespace:: {metadata+: {namespace: "cert-manager"}},

  ns: kube.Namespace($.namespace.metadata.namespace),

  Issuer(name):: kube._Object("certmanager.k8s.io/v1alpha1", "Issuer", name),

  ClusterIssuer(name):: kube._Object("certmanager.k8s.io/v1alpha1", "ClusterIssuer", name),

  certCRD: kube.CustomResourceDefinition("certmanager.k8s.io", "v1alpha1", "Certificate") {
    spec+: {names+: {shortNames+: ["cert", "certs"]}},
  },

  issuerCRD: kube.CustomResourceDefinition("certmanager.k8s.io", "v1alpha1", "Issuer"),

  clusterissuerCRD: kube.CustomResourceDefinition("certmanager.k8s.io", "v1alpha1", "ClusterIssuer") {
    spec+: {
      scope: "Cluster",
    },
  },

  sa: kube.ServiceAccount("cert-manager") + $.namespace,

  clusterRole: kube.ClusterRole("cert-manager") {
    rules: [
      {
        apiGroups: ["certmanager.k8s.io"],
        resources: ["certificates", "issuers", "clusterissuers"],
        // FIXME: audit - the helm chart just has "*"
        verbs: ["get", "list", "watch", "create", "patch", "update", "delete"],
      },
      {
        apiGroups: [""],
        resources: ["secrets", "configmaps", "services", "pods"],
        // FIXME: audit - the helm chart just has "*"
        verbs: ["get", "list", "watch", "create", "patch", "update", "delete"],
      },
      {
        apiGroups: ["extensions"],
        resources: ["ingresses"],
        // FIXME: audit - the helm chart just has "*"
        verbs: ["get", "list", "watch", "create", "patch", "update", "delete"],
      },
      {
        apiGroups: [""],
        resources: ["events"],
        verbs: ["create", "patch", "update"],
      },
    ],
  },

  clusterRoleBinding: kube.ClusterRoleBinding("cert-manager") {
    roleRef_: $.clusterRole,
    subjects_+: [$.sa],
  },

  deploy: kube.Deployment("cert-manager") + $.namespace {
    spec+: {
      template+: {
        metadata+: {
          annotations+: {
            "prometheus.io/scrape": "true",
            "prometheus.io/port": "9402",
            "prometheus.io/path": "/metrics",
          },
        },
        spec+: {
          serviceAccountName: $.sa.metadata.name,
          containers_+: {
            default: kube.Container("cert-manager") {
              image: "quay.io/jetstack/cert-manager-controller:v0.4.1",
              args_+: {
                "cluster-resource-namespace": "$(POD_NAMESPACE)",
                "leader-election-namespace": "$(POD_NAMESPACE)",
                default_issuer:: $.letsencryptProd,
                "default-issuer-name": self.default_issuer.metadata.name,
                "default-issuer-kind": self.default_issuer.kind,
              },
              env_+: {
                POD_NAMESPACE: kube.FieldRef("metadata.namespace"),
              },
              ports_+: {
                prometheus: {containerPort: 9402},
              },
              resources: {
                requests: {cpu: "10m", memory: "32Mi"},
              },
            },
          },
        },
      },
    },
  },

  letsencryptStaging: $.ClusterIssuer("letsencrypt-staging") {
    local this = self,
    spec+: {
      acme+: {
        server: "https://acme-staging-v02.api.letsencrypt.org/directory",
        email: email,
        privateKeySecretRef: {name: this.metadata.name},
        http01: {},
      },
    },
  },

  letsencryptProd: $.letsencryptStaging {
    metadata+: {name: "letsencrypt-prod"},
    spec+: {
      acme+: {
        server: "https://acme-v02.api.letsencrypt.org/directory",
      },
    },
  },
}
