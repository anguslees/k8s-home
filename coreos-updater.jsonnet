local kube = import "kube.libsonnet";
local kubecfg = import "kubecfg.libsonnet";
local utils = import "utils.libsonnet";

local stripLeading(c, str) = if std.startsWith(str, c) then
  stripLeading(c, std.substr(str, 1, std.length(str)-1)) else str;

local isalpha(c) = std.codepoint(c) >= std.codepoint("a") && std.codepoint(c) <= std.codepoint("z");

local version = "v0.6.0";

local arch = "amd64";

local archNodeSelector(a) = {nodeSelector+: {"beta.kubernetes.io/arch": a}};

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

  update_agent: kube.DaemonSet("update-agent") + $.namespace {
    spec+: {
      template+: {
        local hostPaths = ["/var/run/dbus", "/etc/coreos", "/usr/share/coreos", "/etc/os-release"],
        local name(path) = stripLeading("-", std.join("", [if isalpha(c) then c else "-" for c in std.stringChars(path)])),

        spec+: archNodeSelector(arch) + {
          serviceAccountName: $.serviceAccount.metadata.name,
          containers_+: {
            update_agent: kube.Container("update-agent") {
              image: "quay.io/coreos/container-linux-update-operator:%s" % version,
              command: ["/bin/update-agent"],
              volumeMounts+: [{name: name(p), mountPath: p}
                              for p in hostPaths],
              env_+: {
                // Read by update-agent as the node name to manage reboots for
                UPDATE_AGENT_NODE: kube.FieldRef("spec.nodeName"),
                POD_NAMESPACE: kube.FieldRef("metadata.namespace"),
              },
            },
          },
          tolerations+: utils.toleratesMaster,
          volumes+: [kube.HostPathVolume(p) {name: name(p)}
                     for p in hostPaths],
        },
      },
    },
  },

  update_operator: kube.Deployment("update-operator") + $.namespace {
    spec+: {
      template+: {
        spec+: archNodeSelector(arch) + {
          serviceAccountName: $.serviceAccount.metadata.name,
          containers_+: {
            update_operator: kube.Container("update-operator") {
              image: "quay.io/coreos/container-linux-update-operator:%s" % version,
              command: ["/bin/update-operator"],
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
