local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";

local arch = "amd64";
local version = "v1.8.3";

{
  namespace:: {
    metadata+: { namespace: "kube-system" },
  },

  serviceAccount: kube.ServiceAccount("kubernetes-dashboard") + $.namespace,

  ing: utils.Ingress("kubernetes-dashboard") + $.namespace {
    host: "dashboard.k.lan",
    target_svc: $.service,
  },

  dashboardRole: kube.Role("kubernetes-dashboard-minimal") + $.namespace {
    rules: [
      {
        apiGroups: [""],
        resources: ["secrets"],
        verbs: ["create"],
      },
      {
        apiGroups: [""],
        resources: ["secrets"],
        resourceNames: ["kubernetes-dashboard-key-holder", $.certs.metadata.name],
        verbs: ["get", "update", "delete"],
      },
      {
        apiGroups: [""],
        resources: ["configmaps"],
        verbs: ["create"],
      },
      {
        apiGroups: [""],
        resources: ["configmaps"],
        resourceNames: [$.config.metadata.name],
        verbs: ["get", "update"],
      },
      {
        apiGroups: [""],
        resources: ["services"],
        resourceNames: ["heapster"],
        verbs: ["proxy"],
      },
      {
        apiGroups: [""],
        resources: ["services/proxy"],
        resourceNames: ["heapster", "http:heapster:", "https:heapster:"],
        verbs: ["get"],
      },
    ],
  },

  dashboardRoleBinding: kube.RoleBinding("kubernetes-dashboard-minimal") + $.namespace {
    roleRef_: $.dashboardRole,
    subjects_+: [$.serviceAccount],
  },

  config: kube.ConfigMap("kubernetes-dashboard-settings") + $.namespace {
    data+: {},
  },

  certs: kube.Secret("kubernetes-dashboard-certs") + $.namespace {
  },

  service: kube.Service("kubernetes-dashboard") + $.namespace {
    metadata+: {
      labels+: {
        "kubernetes.io/cluster-service": "true",
        "kubernetes.io/name": "Dashboard",
      },
    },
    target_pod: $.deployment.spec.template,
    spec+: {
      ports: [{port: 443, targetPort: 8443}],
    },
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
	  nodeSelector+: utils.archSelector(arch),
          volumes_+: {
            certs: kube.SecretVolume($.certs),
            tmp: kube.EmptyDirVolume(),
          },
          containers_+: {
            default: kube.Container("kubernetes-dashboard") {
              image: "gcr.io/google_containers/kubernetes-dashboard-%s:%s" % [arch, version],
              args_+: {
                "auto-generate-certificates": true,
              },
              ports_+: {
                default: {containerPort: 8443, protocol: "TCP"},
              },
              resources+: {
                limits: {cpu: "200m", memory: "500Mi"},
                requests: {cpu: "50m", memory: "200Mi"},
              },
              readinessProbe: {
                httpGet: {path: "/", port: 8443, scheme: "HTTPS"},
                periodSeconds: 20,
                timeoutSeconds: 30,
              },
              livenessProbe: self.readinessProbe {
                initialDelaySeconds: 30,
              },
              volumeMounts_+: {
                certs: {mountPath: "/certs"},
                tmp: {mountPath: "/tmp"},
              },
            },
          },
        },
      },
    },
  },
}
