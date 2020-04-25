local kube = import "kube.libsonnet";
local kubecfg = import "kubecfg.libsonnet";
local utils = import "utils.libsonnet";

local stripLeading(c, str) = if std.startsWith(str, c) then
  stripLeading(c, std.substr(str, 1, std.length(str)-1)) else str;

local isalpha(c) = std.codepoint(c) >= std.codepoint("a") && std.codepoint(c) <= std.codepoint("z");

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

  coreos_update_agent: kube.DaemonSet("coreos-update-agent") + $.namespace {
    spec+: {
      template+: {
        local hostPaths = ["/var/run/dbus", "/etc/coreos", "/usr/share/coreos", "/etc/os-release"],
        local name(path) = stripLeading("-", std.join("", [if isalpha(c) then c else "-" for c in std.stringChars(path)])),

        spec+: archNodeSelector(arch) + {
          serviceAccountName: $.serviceAccount.metadata.name,
          containers_+: {
            update_agent: kube.Container("update-agent") {
              image: "quay.io/coreos/container-linux-update-operator:v0.7.0",
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

  flatcar_upgrader: kube.DaemonSet("flatcar-upgrader") + $.namespace {
    spec+: {
      template+: {
        spec+: {
          nodeSelector+: {
            "container-linux-update.v1.coreos.com/id": "coreos",
          },
          volumes_: {
            root: kube.HostPathVolume("/"),
          },
          hostPID: true, // required for systemctl
          initContainers_+: {
            upgrade: utils.shcmd("upgrade") {
              securityContext+: {privileged: true},
              volumeMounts_+: {
                root: {mountPath: "/target", mountPropagation: "Bidirectional"},
              },
              command: ["chroot", "/target"] + super.command,
              // Slightly modified version of
              // https://docs.flatcar-linux.org/update-to-flatcar.sh
              shcmd: |||
                d=/run/flatcar-update
                mkdir -p $d
                cat <<EOF >$d/key
                -----BEGIN PUBLIC KEY-----
                MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAw/NZ5Tvc93KynOLPDOxa
                hyAGRKB2NvgF9l2A61SsFw5CuZc/k02u1/BvFehK4XL/eOo90Dt8A2l28D/YKs7g
                2IPUSAnA9hc5OKBbpHsDzisxlAh7kg4FpeeJJWJMzO8NDCG5NZVqXEpGjCmX0qSh
                5MLiTDr9dU2YhLo93/92dKnTvsLjUVv5wnuF55Lt2wJv4CbxVn4hHwotGfSomTBO
                +7o6hE3VIIo1C6lkP+FAqMyWKA9s6U0x4tGxCXszW3hPWOANLIT4m0e55ayxiy5A
                ESEVW/xx6Rul75u925m21AqA6wwaEB6ZPKTnUiWoNKNv1xi8LPIz12+0nuE6iT1K
                jQIDAQAB
                -----END PUBLIC KEY-----
                EOF
                umount /usr/share/update_engine/update-payload-key.pub.pem || :
                mount --bind $d/key /usr/share/update_engine/update-payload-key.pub.pem
                sed -i '$a\
                SERVER=https://public.update.flatcar-linux.net/v1/update/
                /^SERVER=/d' /etc/coreos/update.conf
                umount /usr/share/coreos/release || :
                sed -E 's/(COREOS_RELEASE_VERSION=).*/\10.0.0/' </usr/share/coreos/release >$d/release
                mount --bind $d/release /usr/share/coreos/release
                systemctl restart update-engine
                echo "Success. Waiting for regular update/reboot cycle."
              |||,
            },
          },
          containers_: {
            pause: kube.Container("pause") {
              image: "k8s.gcr.io/pause:3.1",
            },
          },
        },
      },
    },
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

  coreos_update_operator: kube.Deployment("coreos-update-operator") + $.namespace {
    spec+: {
      template+: {
        spec+: archNodeSelector(arch) + {
          serviceAccountName: $.serviceAccount.metadata.name,
          containers_+: {
            update_operator: kube.Container("update-operator") {
              image: "quay.io/coreos/container-linux-update-operator:%s" % version,
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
