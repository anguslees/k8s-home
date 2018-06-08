local kube = import "kube.libsonnet";
local kubecfg = import "kubecfg.libsonnet";
local utils = import "utils.libsonnet";

local flannel_version = "v0.10.0";
local cniplugins_version = "v0.6.0";

{
  namespace:: {
    metadata+: { namespace: "kube-system" },
  },

  serviceAccount: kube.ServiceAccount("flannel") + $.namespace,

  cniconf:: {
    name: "cni0",
    cniVersion: "0.3.1",
    plugins: [
      {
        type: "flannel",
        delegate: {
          isDefaultGateway: true,
          hairpinMode: true,
        },
      },
      {
        type: "portmap",
        capabilities: {portMappings: true},
      },
    ],
  },

  netconf:: {
    Network: "10.244.0.0/16",
    Backend: {
      Type: "host-gw",
    },
  },

  config: utils.HashedConfigMap("kube-flannel-cfg") + $.namespace {
    metadata+: {
      labels+: {
	tier: "node",
	app: "flannel",
      },
    },
    data+: {
      "cni-conflist.json": kubecfg.manifestJson($.cniconf),
      "net-conf.json": kubecfg.manifestJson($.netconf),
    },
  },

  daemonsetTemplate:: kube.DaemonSet("kube-flannel-ds") + $.namespace {
    local this = self,
    arch:: error "arch is unset",

    metadata+: {
      name: "%s-%s" % [super.name, this.arch],
      labels+: {
	tier: "node",
	app: "flannel",
      },
    },
    spec+: {
      template+: utils.CriticalPodSpec {
	spec+: {
	  hostNetwork: true,
	  nodeSelector: {
	    "beta.kubernetes.io/arch": this.arch,
	  },
	  tolerations+: [{
	    key: "node-role.kubernetes.io/master",
	    operator: "Exists",
	    effect: "NoSchedule",
	  }],

	  serviceAccountName: $.serviceAccount.metadata.name,

          initContainers_+:: {
	    installconf: utils.shcmd("install-conf") {
              shcmd:: |||
                rm -f /etc/cni/net.d/10-flannel.conf
                tmp=/etc/cni/net.d/.tmp-flannel-cfg
                cp /etc/kube-flannel/cni-conflist.json $tmp
                mv $tmp /etc/cni/net.d/10-flannel.conflist
              |||,
              volumeMounts_+: {
                cni: { mountPath: "/etc/cni/net.d/" },
                cfg: { mountPath: "/etc/kube-flannel/", readOnly: true },
              },
            },
            installbin: utils.shcmd("install-bin") {
              shcmd:: |||
                if [ ! -e /opt/cni/bin/flannel ]; then
                  wget https://github.com/containernetworking/plugins/releases/download/$VERSION/cni-plugins-$ARCH-$VERSION.tgz
                  tar zxvf cni-plugins-$ARCH-$VERSION.tgz -C /opt/cni/bin/
                fi
              |||,
              volumeMounts_+: {
                cnibin: { mountPath: "/opt/cni/bin/" },
              },
              env_+: {
                VERSION: cniplugins_version,
                ARCH: this.arch,
              },
            },
          },

	  containers_+: {
	    default: kube.Container("kube-flannel") {
	      image: "quay.io/coreos/flannel:%s-%s" % [flannel_version, this.arch],
	      command: ["/opt/bin/flanneld", "--ip-masq", "--kube-subnet-mgr", "--iface=$(POD_IP)"],
	      securityContext+: {
		privileged: true,
	      },
	      env_: {
		POD_NAME: kube.FieldRef("metadata.name"),
		POD_NAMESPACE: kube.FieldRef("metadata.namespace"),
                POD_IP: kube.FieldRef("status.podIP"),
	      },
	      volumeMounts_+: {
		run: { mountPath: "/run" },
		cni: { mountPath: "/etc/cni/net.d/" },
		cfg: { mountPath: "/etc/kube-flannel/" },
	      },
	    },
	  },

	  volumes_+: {
	    run: kube.HostPathVolume("/run", "Directory"),
	    cni: kube.HostPathVolume("/etc/cni/net.d", "DirectoryOrCreate"),
	    cnibin: kube.HostPathVolume("/opt/cni/bin", "DirectoryOrCreate"),
	    cfg: kube.ConfigMapVolume($.config),
	  },
	},
      },
    },
  },

  daemonset: {
    [arch]: $.daemonsetTemplate { arch: arch }
    for arch in ["amd64", "arm", "arm64", "ppc64le"]
  },

  clusterRole: kube.ClusterRole("flannel") {
    rules: [
      {
	apiGroups: [""],
	resources: ["pods"],
	verbs: ["get"],
      },
      {
	apiGroups: [""],
	resources: ["nodes"],
	verbs: ["list", "watch"],
      },
      {
	apiGroups: [""],
	resources: ["nodes/status"],
	verbs: ["patch"],
      },
    ],
  },

  clusterRoleBinding: kube.ClusterRoleBinding("flannel") {
    roleRef_: $.clusterRole,
    subjects_: [$.serviceAccount],
  },
}
