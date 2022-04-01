local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";

local arch = "amd64";
local image = "quay.io/bitnami/sealed-secrets-controller:v0.5.1"; // renovate

{
  namespace:: {metadata+: {namespace: "kube-system"}},

  crd: kube.CustomResourceDefinition("bitnami.com", "v1alpha1", "SealedSecret") {
    spec+: {
      versions_+: {
        v1alpha1+: {
          schema: {
            openAPIV3Schema: {
              "$schema": "http://json-schema.org/draft-04/schema#",
              type: "object",
              description: "A sealed (encrypted) Secret",
              properties: {
                spec: {
                  type: "object",
                  properties: {
                    data: {
                      type: "string",
                      pattern: "^[A-Za-z0-9+/=]*$", // base64
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

  serviceAccount: kube.ServiceAccount("sealed-secrets-controller") + $.namespace,

  unsealerRole: kube.ClusterRole("secrets-unsealer") {
    rules: [
      {
        apiGroups: ["bitnami.com"],
        resources: ["sealedsecrets"],
        verbs: ["get", "list", "watch"],
      },
      {
        apiGroups: [""],
        resources: ["secrets"],
        verbs: ["create", "update", "delete"], // don't need get
      },
    ],
  },

  sealKeyRole: kube.Role("sealed-secrets-key-admin") + $.namespace {
    rules: [
      {
        apiGroups: [""],
        resources: ["secrets"],
        resourceNames: ["sealed-secrets-key"],
        verbs: ["get"],
      },
      {
        apiGroups: [""],
        resources: ["secrets"],
        // Can't limit create by resourceName, because there's no
        // resource yet
        verbs: ["create"],
      },
    ],
  },

  unsealerBinding: kube.ClusterRoleBinding("sealed-secrets-controller") {
    roleRef_: $.unsealerRole,
    subjects_+: [$.serviceAccount],
  },

  sealKeyBinding: kube.RoleBinding("sealed-secrets-controller") + $.namespace {
    roleRef_: $.sealKeyRole,
    subjects_+: [$.serviceAccount],
  },

  svc: kube.Service("sealed-secrets-controller") + $.namespace {
    target_pod: $.controller.spec.template,
  },

  controller: kube.Deployment("sealed-secrets-controller") + $.namespace {
    spec+: {
      template+: {
        spec+: {
          nodeSelector: utils.archSelector(arch),
          serviceAccountName: $.serviceAccount.metadata.name,
          containers_+: {
            default: kube.Container("controller") {
              image: image,
              command: ["controller"],
              ports_+: {
                http: {containerPort: 8080},
              },
              livenessProbe: {
                httpGet: {path: "/healthz", port: 8080},
              },
              readinessProbe: self.livenessProbe,
              securityContext: {
                readOnlyRootFilesystem: true,
                runAsNonRoot: true,
                runAsUser: 1001,
              },
            },
          },
        },
      },
    },
  },
}
