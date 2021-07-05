local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";

local arch = "arm";

{
  namespace:: {metadata+: {namespace: "kured"}},
  ns: kube.Namespace($.namespace.metadata.namespace),

  prometheus_svc:: error "this file assumes prometheus",

  sa: kube.ServiceAccount("kured") + $.namespace,

  clusterRole: kube.ClusterRole("kured") {
    // Allow kured to read spec.unschedulable
    // Allow kubectl to drain/uncordon
    rules: [
      {
        apiGroups: [""],
        resources: ["nodes"],
        verbs: ["get", "patch"],
      },
      {
        apiGroups: [""],
        resources: ["pods"],
        verbs: ["list", "delete", "get"],
      },
      {
        apiGroups: ["extensions", "apps"],
        resources: ["daemonsets"],
        verbs: ["get"],
      },
      {
        apiGroups: [""],
        resources: ["pods/eviction"],
        verbs: ["create"],
      },
    ],
  },

  role: kube.Role("kured") + $.namespace {
    // Allow kured to lock/unlock itself
    rules: [
      {
        apiGroups: ["extensions", "apps"],
        resources: ["daemonsets"],
        resourceNames: [$.deploy.metadata.name],
        verbs: ["update"],
      },
    ],
  },

  clusterRoleBinding: kube.ClusterRoleBinding("kured") {
    roleRef_: $.clusterRole,
    subjects_+: [$.sa],
  },

  roleBinding: kube.RoleBinding("kured") + $.namespace {
    roleRef_: $.role,
    subjects_+: [$.sa],
  },

  deploy: kube.DaemonSet("kured") + $.namespace {
    spec+: {
      template+: {
        metadata+: {
          annotations+: {
            "prometheus.io/scrape": "true",
            "prometheus.io/port": "8080",
            "prometheus.io/path": "/metrics",
          },
        },
        spec+: {
          nodeSelector+: utils.archSelector(arch),
	  tolerations+: utils.toleratesMaster,
          serviceAccountName: $.sa.metadata.name,
          volumes_+: {
            hostrun: kube.HostPathVolume("/var/run", type="Directory"),
          },
          containers_: {
            kured: kube.Container("kured") {
              //image: "quay.io/weaveworks/kured",
              // renovate: depName=quay.io/anguslees/kured-amd64
              local version = "1.0-20180606-2",
              image: "quay.io/anguslees/kured-%s:%s" % [arch, version],
              command: ["/usr/bin/kured"],
              args_+: {
                "alert-filter-regexp": "^RebootRequired$",
                "ds-name": "$(MY_DS_NAME)",
                "ds-namespace": "$(MY_NAMESPACE)",
                period: "1h",
                "prometheus-url": $.prometheus_svc.http_url,
                "reboot-sentinel": "/var/run/reboot-required",
              },
              env_+: {
                KURED_NODE_ID: kube.FieldRef("spec.nodeName"),
                MY_NAMESPACE: kube.FieldRef("metadata.namespace"),
                MY_DS_NAME: $.deploy.metadata.name,
              },
              volumeMounts_+: {
                // NB: Checks for reboot-required, and write to
                // dbus/system_bus_socket to cause reboot.
                // TODO: move reboot-required flag, and restrict to
                // just these two paths.
                hostrun: {mountPath: "/var/run"},
              },
              ports_+: {
                metrics: {containerPort: 8080},
              },
              readinessProbe+: {
                httpGet: {path: "/metrics", port: "metrics"},
                timeoutSeconds: 5,
                periodSeconds: 60,
              },
              livenessProbe: self.readinessProbe,
            },
          },
        },
      },
    },
  },
}
