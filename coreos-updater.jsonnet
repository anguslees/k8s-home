local kube = import "kube.libsonnet";
local kubecfg = import "kubecfg.libsonnet";

local stripLeading(c, str) = if std.startsWith(str, c) then
  stripLeading(c, std.substr(str, 1, std.length(str)-1)) else str;

local isalpha(c) = std.codepoint(c) >= std.codepoint("a") && std.codepoint(c) <= std.codepoint("z");

local version = "v0.3.1";

local arch = "amd64";

local archNodeSelector(a) = {nodeSelector+: {"beta.kubernetes.io/arch": a}};

{
  namespace:: {
    metadata+: { namespace: "coreos-pxe-install" },
  },

  ns: kube.Namespace($.namespace.metadata.namespace),

  updater_role: kube.ClusterRole("update-agent") {
    rules: [
      {
        apiGroups: [""],
        resources: ["nodes"],
        verbs: ["get", "watch", "list", "update"],
      },
      {
        apiGroups: [""],
        resources: ["pods"],
        verbs: ["list"],
      },
      {
        apiGroups: ["extensions", "apps"],
        resources: ["daemonsets"],
        verbs: ["get"],
      },
    ],
  },

  updater_binding: kube.ClusterRoleBinding("update-agent") {
    subjects: [{
      kind: "ServiceAccount",
      name: "default",
      namespace: $.namespace.metadata.namespace,
    }],

    roleRef_: $.updater_role,
  },

  updater_lock_role: kube.Role("update-agent-locker") + $.namespace {
    rules: [
      {
        apiGroups: [""],
        resources: ["endpoints"],
        resourceNames: ["container-linux-update-operator-lock"],
        verbs: ["get", "update"],
      },
      {
        apiGroups: [""],
        resources: ["endpoints"],
        verbs: ["create"],
      },
      {
        apiGroups: [""],
        resources: ["events"],
        verbs: ["create"],
      },
    ],
  },

  update_lock_binding: kube.RoleBinding("update-agent-lock") + $.namespace {
    subjects: [{
      kind: "ServiceAccount",
      name: "default",
      namespace: $.namespace.metadata.namespace,
    }],

    roleRef_: $.updater_lock_role,
  },

  update_agent: kube.DaemonSet("update-agent") + $.namespace {
    spec+: {
      template+: {
        local hostPaths = ["/var/run/dbus", "/etc/coreos", "/usr/share/coreos", "/etc/os-release"],
        local name(path) = stripLeading("-", std.join("", [if isalpha(c) then c else "-" for c in std.stringChars(path)])),

        spec+: archNodeSelector(arch) + {
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
          tolerations+: [
            {
              key: "node-role.kubernetes.io/master",
              operator: "Exists",
              effect: "NoSchedule",
            },
          ],
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
          containers_+: {
            update_operator: kube.Container("update-operator") {
              image: "quay.io/coreos/container-linux-update-operator:%s" % version,
              command: ["/bin/update-operator"],
              env_+: {
                POD_NAMESPACE: kube.FieldRef("metadata.namespace"),
              },
            },
          },
          tolerations+: [
            {
              key: "node-role.kubernetes.io/master",
              operator: "Exists",
              effect: "NoSchedule",
            },
          ],
        },
      },
    },
  },
}
