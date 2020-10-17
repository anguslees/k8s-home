local kube = import "kube.libsonnet";
local kubecfg = import "kubecfg.libsonnet";

local version = "v0.9.3";

{
  namespace:: {metadata+: {namespace: "metallb"}},
  ns: kube.Namespace($.namespace.metadata.namespace),

  config: kube.ConfigMap("config") + $.namespace {
    data+: {
      config_:: {
        "address-pools": [{
          name: "lan",
          protocol: "layer2",
          addresses: [
            "192.168.0.50-192.168.0.100",
          ],
        }],
      },
      config: kubecfg.manifestJson(self.config_),
    },
  },

  controllerRole: kube.ClusterRole("controller") {
    rules: [
      {
        apiGroups: [""],
        resources: ["services"],
        verbs: ["get", "list", "watch", "update"],
      },
      {
        apiGroups: [""],
        resources: ["services/status"],
        verbs: ["update"],
      },
      {
        apiGroups: [""],
        resources: ["events"],
        verbs: ["create"],
      },
    ],
  },

  controlleRoleBinding: kube.ClusterRoleBinding("controller") {
    roleRef_: $.controllerRole,
    subjects_+: [$.controller.sa],
  },

  speakerRole: kube.ClusterRole("speaker") {
    rules: [
      {
        apiGroups: [""],
        resources: ["services", "endpoints", "nodes"],
        verbs: ["get", "list", "watch"],
      },
      {
        apiGroups: [""],
        resources: ["events"],
        verbs: ["create", "patch"],
      },
    ],
  },

  speakerRoleBinding: kube.ClusterRoleBinding("speaker") {
    roleRef_: $.speakerRole,
    subjects_+: [$.speaker.sa],
  },

  configWatcher: kube.Role("config-watcher") + $.namespace {
    rules: [
      {
        apiGroups: [""],
        resources: ["configmaps"],
        verbs: ["get", "list", "watch"],
      },
    ],
  },

  configWatcherBinding: kube.RoleBinding("config-watcher") + $.namespace {
    roleRef_: $.configWatcher,
    subjects_+: [$.controller.sa, $.speaker.sa],
  },

  controller: {
    sa: kube.ServiceAccount("controller") + $.namespace,

    deploy: kube.Deployment("controller") + $.namespace {
      spec+: {
        template+: {
          metadata+: {
            annotations+: {
              "prometheus.io/scrape": "true",
            "prometheus.io/port": "7472",
            },
          },
          spec+: {
            serviceAccountName: $.controller.sa.metadata.name,
            terminationGracePeriodSeconds: 0,
            securityContext+: {
              runAsNonRoot: true,
              runAsUser: 65534, // nobody
            },
            containers_+: {
              controller: kube.Container("controller") {
                image: "metallb/controller:" + version,
                args_+: {
                  port: "7472",
                },
                ports_+: {
                  monitoring: {containerPort: 7472},
                },
                resources+: {
                  requests: {cpu: "10m", memory: "40Mi"},
                  limits: {cpu: "100m", memory: "100Mi"},
                },
                securityContext+: {
                  allowPrivilegeEscalation: false,
                  capabilities+: {
                    drop: ["all"],
                  },
                  readOnlyRootFilesystem: true,
                },
              },
            },
          },
        },
      },
    },
  },

  speaker: {
    sa: kube.ServiceAccount("speaker") + $.namespace,

    deploy: kube.Deployment("speaker") + $.namespace {
      local this = self,
      spec+: {
        replicas: 2,
        strategy: {
          type: "RollingUpdate",
          rollingUpdate: {
            maxSurge: 1,
            maxUnavailable: this.spec.replicas - 1, // One must be available
          },
        },

        template+: {
          metadata+: {
            annotations+: {
              "prometheus.io/scrape": "true",
              "prometheus.io/port": "7472",
            },
          },
          spec+: {
            serviceAccountName: $.speaker.sa.metadata.name,
            terminationGracePeriodSeconds: 0,
            hostNetwork: true,
            affinity+: {
              podAntiAffinity+: {
                requiredDuringSchedulingIgnoredDuringExecution+: [{
                  labelSelector: this.spec.selector,
                  topologyKey: "kubernetes.io/hostname",
                }],
              },
            },
            containers_+: {
              speaker: kube.Container("speaker") {
                image: "metallb/speaker:" + version,
                args_+: {
                  port: "7472",
                },
                env_+: {
                  METALLB_NODE_IP: kube.FieldRef("status.hostIP"),
                  METALLB_NODE_NAME: kube.FieldRef("spec.nodeName"),
                },
                ports_+: {
                  monitoring: {containerPort: 7472},
                },
                resources+: {
                  requests: {cpu: "10m", memory: "40Mi"},
                  limits: {cpu: "100m", memory: "100Mi"},
                },
                securityContext+: {
                  allowPrivilegeEscalation: false,
                  readOnlyRootFilesystem: true,
                  capabilities+: {
                    drop: ["all"],
                    add: ["net_raw"],
                  },
                },
              },
            },
          },
        },
      },
    },
  },
}
