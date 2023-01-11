local kube = import "kube.libsonnet";
local kubecfg = import "kubecfg.libsonnet";
local utils = import "utils.libsonnet";

local stripLeading(c, str) = if std.startsWith(str, c) then
  stripLeading(c, std.substr(str, 1, std.length(str)-1)) else str;

local isalpha(c) = std.codepoint(c) >= std.codepoint("a") && std.codepoint(c) <= std.codepoint("z");

local coreosNodeSelector = utils.archSelector("amd64");

{
  namespace:: {
    metadata+: { namespace: "coreos-pxe-install" },
  },

  update_agent: {
    sa: kube.ServiceAccount("update-agent") + $.namespace,

    clusterrole: kube.ClusterRole("flatcar-update-agent") {
      rules: [
        {
          apiGroups: [""],
          resources: ["nodes"],
          verbs: ["get", "watch", "list", "update"],
        },
        {
          apiGroups: [""],
          resources: ["pods"],
          verbs: ["get", "list", "delete"],
        },
        {
          apiGroups: [""],
          resources: ["pods/eviction"],
          verbs: ["create"],
        },
        {
          apiGroups: ["extensions", "apps"],
          resources: ["daemonsets"],
          verbs: ["get"],
        },
      ],
    },

    clusterbinding: kube.ClusterRoleBinding("flatcar-update-agent") {
      subjects_: [$.update_agent.sa],
      roleRef_: $.update_agent.clusterrole,
    },

    deploy: kube.DaemonSet("update-agent") + $.namespace {
      spec+: {
        template+: {
          local hostPaths = ["/var/run/dbus", "/etc/flatcar", "/usr/share/flatcar", "/etc/os-release"],
          local name(path) = stripLeading("-", std.join("", [if isalpha(c) then c else "-" for c in std.stringChars(path)])),

          spec+: {
            serviceAccountName: $.update_agent.sa.metadata.name,
            nodeSelector+: coreosNodeSelector,
            containers_+: {
              update_agent: kube.Container("update-agent") {
                image: "ghcr.io/flatcar/flatcar-linux-update-operator:v0.9.0", // renovate
                command: ["/bin/update-agent"],
                volumeMounts+: [
                  {
                    name: name(p),
                    mountPath: p,
                    readOnly: p != "/var/run/dbus",
                  }
                  for p in hostPaths
                ],
                env_+: {
                  // Read by update-agent as the node name to manage reboots for
                  UPDATE_AGENT_NODE: kube.FieldRef("spec.nodeName"),
                  POD_NAMESPACE: kube.FieldRef("metadata.namespace"),
                },
                securityContext: {runAsUser: 0},
              },
            },
            tolerations+: utils.toleratesMaster,
            volumes+: [kube.HostPathVolume(p) {name: name(p)}
                       for p in hostPaths],
          },
        },
      },
    },
  },

  operator: {
    sa: kube.ServiceAccount("update-operator") + $.namespace,

    clusterrole: kube.ClusterRole("flatcar-update-operator") {
      rules: [
        {
          apiGroups: [""],
          resources: ["nodes"],
          verbs: ["get", "watch", "list", "update"],
        },
      ],
    },

    clusterbinding: kube.ClusterRoleBinding("flatcar-update-operator") {
      subjects_: [$.operator.sa],
      roleRef_: $.operator.clusterrole,
    },

    role: kube.Role("update-operator") + $.namespace {
      rules: [
        {
          apiGroups: [""],
          resources: ["configmaps"],
          verbs: ["create"],
        },
        {
          apiGroups: [""],
          resources: ["configmaps"],
          resourceNames: ["flatcar-linux-update-operator-lock"],
          verbs: ["get", "update"],
        },
        {
          apiGroups: [""],
          resources: ["events"],
          verbs: ["create", "watch"],
        },
        {
          apiGroups: ["coordination.k8s.io"],
          resources: ["leases"],
          verbs: ["create"],
        },
        {
          apiGroups: ["coordination.k8s.io"],
          resources: ["leases"],
          resourceNames: ["flatcar-linux-update-operator-lock"],
          verbs: ["get", "update"],
        },
      ],
    },

    binding: kube.RoleBinding("update-operator") + $.namespace {
      subjects_: [$.operator.sa],
      roleRef_: $.operator.role,
    },

    deploy: kube.Deployment("update-operator") + $.namespace {
      spec+: {
        template+: {
          spec+: {
            serviceAccountName: $.operator.sa.metadata.name,
            containers_+: {
              update_operator: kube.Container("update-operator") {
                image: "ghcr.io/flatcar/flatcar-linux-update-operator:v0.9.0", // renovate
                command: ["/bin/update-operator"],
                args_+: {
                  "before-reboot-annotations": "ceph-before-reboot-check",
                  "after-reboot-annotations": "ceph-after-reboot-check",
                },
                env_+: {
                  POD_NAMESPACE: kube.FieldRef("metadata.namespace"),
                },
              },
            },
            tolerations+: utils.toleratesMaster,
          },
        },
      },
    },
  },
}
