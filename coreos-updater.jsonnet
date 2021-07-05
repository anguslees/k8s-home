local kube = import "kube.libsonnet";
local kubecfg = import "kubecfg.libsonnet";
local utils = import "utils.libsonnet";

local stripLeading(c, str) = if std.startsWith(str, c) then
  stripLeading(c, std.substr(str, 1, std.length(str)-1)) else str;

local isalpha(c) = std.codepoint(c) >= std.codepoint("a") && std.codepoint(c) <= std.codepoint("z");

// renovate: depName=quay.io/kinvolk/flatcar-linux-update-operator
local version = "v0.7.3";

local arch = "amd64";

local archNodeSelector(a) = {nodeSelector+: utils.archSelector(a)};

{
  namespace:: {
    metadata+: { namespace: "coreos-pxe-install" },
  },

  ns: kube.Namespace($.namespace.metadata.namespace),

  serviceAccount: kube.ServiceAccount("update-agent") + $.namespace,

  updater_role: kube.ClusterRole("update-agent") {
    rules: [
      {
        apiGroups: [""],
        resources: ["nodes"],
        verbs: ["get", "watch", "list", "update"],
      },
      {
        apiGroups: [""],
        resources: ["configmaps"],
        verbs: ["create", "get", "update", "list", "watch"],
      },
      {
        apiGroups: [""],
        resources: ["events"],
        verbs: ["create", "watch"],
      },
      {
        apiGroups: [""],
        resources: ["pods"],
        verbs: ["get", "list", "delete"],
      },
      {
        apiGroups: ["extensions", "apps"],
        resources: ["daemonsets"],
        verbs: ["get"],
      },
    ],
  },

  updater_binding: kube.ClusterRoleBinding("update-agent") {
    subjects_: [$.serviceAccount],
    roleRef_: $.updater_role,
  },

  flatcar_update_agent: kube.DaemonSet("flatcar-update-agent") + $.namespace {
    spec+: {
      template+: {
        local hostPaths = ["/var/run/dbus", "/etc/flatcar", "/usr/share/flatcar", "/etc/os-release"],
        local name(path) = stripLeading("-", std.join("", [if isalpha(c) then c else "-" for c in std.stringChars(path)])),

        spec+: archNodeSelector(arch) + {
          serviceAccountName: $.serviceAccount.metadata.name,
          containers_+: {
            update_agent: kube.Container("update-agent") {
              image: "quay.io/kinvolk/flatcar-linux-update-operator:%s" % version,
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

  flatcar_update_operator: kube.Deployment("flatcar-update-operator") + $.namespace {
    spec+: {
      template+: {
        spec+: archNodeSelector(arch) + {
          serviceAccountName: $.serviceAccount.metadata.name,
          containers_+: {
            update_operator: kube.Container("update-operator") {
              image: "quay.io/kinvolk/flatcar-linux-update-operator:%s" % version,
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
}
