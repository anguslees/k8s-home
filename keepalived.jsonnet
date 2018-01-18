local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";

local arch = "amd64";
local image = "gcr.io/google_containers/kube-keepalived-vip:0.11";

// FIXME: ideally, this would be automatically calculated based on
// presence of type=LoadBalancer and dynamic allocations from a
// configured prefix.
local vipmap = {
  // NB: 192.168.0.50-100 is available for VIPs
  "kube-system/nginx-ingress": "192.168.0.50",
  //"default/kubernetes":  "192.168.0.51",  // doesn't work?
  //"coreos-pxe-install/coreos-pxe-httpd":  "192.168.0.52", moved to nodeport
  "kube-system/nginx-ingress-internal": "192.168.0.53",

  // This might be desirable someday, but for now assert uniqueness.
  assert std.length(std.set([self[k] for k in std.objectFields(self)])) ==
    std.length(self) : "VIP clash?",
};

{
  namespace:: { metadata+: { namespace: "kube-system" }},

  vip(svc):: vipmap["%s/%s" % [svc.metadata.namespace, svc.metadata.name]],

  serviceAccount: kube.ServiceAccount("kube-keepalived-vip") + $.namespace,

  clusterRole: kube.ClusterRole("kube-keepalived-vip") {
    rules: [
      {
        apiGroups: [""],
        resources: ["pods", "nodes", "endpoints", "services", "configmaps"],
        verbs: ["get", "list", "watch"],
      },
    ],
  },

  clusterRoleBinding: kube.ClusterRoleBinding("kube-keepalived-vip") {
    roleRef_: $.clusterRole,
    subjects_+: [$.serviceAccount],
  },

  config: kube.ConfigMap("vip-configmap") + $.namespace {
    data: {
      [vipmap[k]]: k
      for k in std.objectFields(vipmap)
    },
  },

  disruption: kube.PodDisruptionBudget("kube-keepalived-vip") + $.namespace {
    target_pod: $.keepalived.spec.template,
  },

  keepalived: kube.Deployment("kube-keepalived-vip") + $.namespace {
    local this = self,
    spec+: {
      replicas: 2,
      strategy: {
        type: "RollingUpdate",
        rollingUpdate: {
          maxSurge: 1,
          maxUnavailable: this.spec.replicas - 1,  // One must be available
        },
      },
      template+: {
        spec+: {
          hostNetwork: true,
          serviceAccountName: $.serviceAccount.metadata.name,
	  nodeSelector+: utils.archSelector(arch),
          podAntiAffinity+: {
            requiredDuringSchedulingIgnoredDuringExecution+: [{
                labelSelector: {matchLabels: this.spec.selector},
                topologyKey: "kubernetes.io/hostname",
            }],
          },
          containers_+: {
            default: kube.Container("keepalived") {
              image: image,
              securityContext+: {privileged: true},
              args_+: {
                "services-configmap": "$(POD_NAMESPACE)/" + $.config.metadata.name,
                "logtostderr": true,
                "watch-all-namespaces": true,
                //vrid: unique u8 per keepalived set
              },
              env_+: {
                POD_NAME: kube.FieldRef("metadata.name"),
                POD_NAMESPACE: kube.FieldRef("metadata.namespace"),
              },
              volumeMounts_+: {
                dev: {mountPath: "/dev"},
                modules: {mountPath: "/lib/modules", readOnly: true},
              },
            },
          },
          volumes_+: {
            dev: kube.HostPathVolume("/dev"),
            modules: kube.HostPathVolume("/lib/modules"),
          },
        },
      },
    },
  },
}
