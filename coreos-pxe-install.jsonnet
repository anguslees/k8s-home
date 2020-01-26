local kube = import "kube.libsonnet";
local kubecfg = import "kubecfg.libsonnet";
local utils = import "utils.libsonnet";

local coreos_kubelet_tag = "v1.17.1";

local default_env = {
  // NB: dockerd can't route to a cluster LB VIP? (fixme)
  //http_proxy: "http://proxy.lan:80/",
  http_proxy: "http://192.168.0.10:3128/",
  no_proxy: ".lan,.local",
};

local arch = "amd64";

local pxeNodeSelector = {
  tolerations+: utils.toleratesMaster,
  nodeSelector+: utils.archSelector(arch),
};

local sshKeys = [
  importstr "/home/gus/.ssh/id_rsa.pub",
];

local filekey(path) = (
  local tmp = kubecfg.regexSubst("[^a-zA-Z0-9]+", path, "-");
  kubecfg.regexSubst("^-+", tmp, "")
);

{
  namespace:: {
    metadata+: { namespace: "coreos-pxe-install" },
  },

  ns: kube.Namespace($.namespace.metadata.namespace),

  // see https://coreos.com/ignition/docs/latest/configuration-v2_1.html
  ignition_config:: {
    ignition: {
      version: "2.1.0",
      config: {},
    },
    storage: {
      /* coreos-install already partitions disk
      disks: [
	{
	  device: "/dev/sda",
	  wipeTable: true,
	  partitions: [
	    {
	      label: "ROOT",
	      number: 0,
	      size: 0,
	      start: 0,
	    },
	  ],
	},
      ],
      filesystems: [
	{
	  name: "root",
	  mount: {
	    device: "/dev/disk/by-partlabel/ROOT",
	    format: "ext4",
	    label: "ROOT",
	  },
	},
      ],
      */
      local dir(path, mode="0755") = {
        filesystem: "root",
        path: path,
        mode: kube.parseOctal(mode),
      },
      directories: [
        dir("/etc/ssl/etcd/"),
      ],
      local file(path, contents) = {
        local this = self,
        filesystem: "root",
        path: path,
        contents_:: contents,
        contents: {
          source: "data:;base64," + std.base64(this.contents_),
        },
        mode: kube.parseOctal("0644"),
      },
      files: [
        file("/etc/kubernetes/kubelet.env", |||
               KUBELET_IMAGE_URL=docker://gcr.io/google-containers/hyperkube
               KUBELET_IMAGE_TAG=%(tag)s
               KUBELET_IMAGE_ARGS=--exec=kubelet
               RKT_GLOBAL_ARGS="--insecure-options=image"
             ||| % {tag: coreos_kubelet_tag},
            ),
        file("/etc/sysctl.d/max-user-watches.conf", |||
               fs.inotify.max_user_watches=16184
             |||
            ),
        file("/etc/systemd/system.conf.d/10-default-env.conf",
             std.manifestIni({
               sections: {
                 Manager: {
                   /* Breaks too many things
                   DefaultEnvironment: std.join(" ", [
                     "\"%s=%s\"" % kv for kv in kube.objectItems(default_env)]),
                    */
                 },
               },
             })),
        file("/etc/profile.env",
             std.join("", ["export %s=%s\n" % kv for kv in kube.objectItems(default_env)])),
        file("/etc/systemd/logind.conf.d/lid.conf",
             std.manifestIni({
               sections: {
                 Login: {
                   HandleLidSwitch: "ignore",
                 },
               },
             })),
        file("/etc/sysctl.d/80-swappiness.conf",
            "vm.swappiness=10"),
      ],
    },
    systemd: {
      // https://github.com/coreos/matchbox/blob/master/examples/ignition/bootkube-worker.yaml
      units: [
        {
          name: "docker.service",
          enabled: true,
        },
        {
          name: "update-engine.service",
          enabled: true,
        },
        {
          name: "locksmithd.service",
          enabled: false,  // use newer update-engine instead
          mask: true,
        },
        {
          name: "kubelet.path",
          enabled: true,
          contents_:: {
            sections: {
              Unit: {
                Description: "Watch for kubeconfig",
              },
              Path: {
                PathExists: "/etc/kubernetes/kubelet.conf",
              },
              Install: {
                WantedBy: "multi-user.target",
              },
            },
          },
          contents: std.manifestIni(self.contents_),
        },
	{
	  name: "kubelet.service",
	  contents_:: {
            sections: {
              Unit: {
                Description: "Kubelet via Hyperkube ACI",
                After: "network.target",
              },
              Service: {
                EnvironmentFile: "/etc/kubernetes/kubelet.env",
                Environment: 'RKT_RUN_ARGS="%s"' % std.join(" ", [
                  "--uuid-file-save=/var/cache/kubelet-pod.uuid",
                ] + [
                  local name(path) = utils.stripLeading(
                    "-", std.join("", [if utils.isalpha(c) then c else "-"
                      for c in std.stringChars(path)]));
                  "--volume=%(n)s,kind=host,source=%(p)s --mount volume=%(n)s,target=%(p)s" % {n: name(p), p: p}
                  for p in ["/etc/resolv.conf", "/var/lib/cni", "/etc/cni/net.d", "/opt/cni/bin", "/var/log", "/var/lib/local-data"]
                ]),
                ExecStartPre: [
                  "-/usr/bin/rkt rm --uuid-file=/var/cache/kubelet-pod.uuid",
                  "/bin/mkdir -p " + std.join(" ", [
                    "/opt/cni/bin",
                    "/etc/kubernetes/manifests",
                    "/etc/cni/net.d",
                    "/etc/kubernetes/checkpoint-secrets",
                    "/etc/kubernetes/inactive-manifests",
                    "/var/lib/cni",
                    "/var/lib/kubelet/volumeplugins",
                    "/var/lib/local-data",
                  ]),
                ],
                // ExecStartPre=/usr/bin/bash -c "grep 'certificate-authority-data' /etc/kubernetes/kubeconfig | awk '{print $2}' | base64 -d > /etc/kubernetes/ca.crt"
                ExecStart: std.join(" ", ["/usr/lib/coreos/kubelet-wrapper"] + [
                  "--%s=%s" % kv for kv in kube.objectItems(self.args_)]),
                // https://github.com/kubernetes/release/blob/master/rpm/10-kubeadm.conf
                args_:: {
                  "anonymous-auth": false,
                  "client-ca-file": "/etc/kubernetes/pki/ca.crt",
                  "authentication-token-webhook": true,
                  "authorization-mode": "Webhook",
                  "cluster-dns": "10.96.0.10",
                  "cluster-domain": "cluster.local",
                  "cert-dir": "/var/lib/kubelet/pki",
                  "exit-on-lock-contention": true,
                  "pod-max-pids": "10000",
                  "fail-swap-on": false,
                  "hostname-override": "%m",
                  "lock-file": "/var/run/lock/kubelet.lock",
                  "network-plugin": "cni",
                  "cni-conf-dir": "/etc/cni/net.d",
                  "cni-bin-dir": "/opt/cni/bin",
                  "pod-manifest-path": "/etc/kubernetes/manifests",
                  "rotate-certificates": true,
                  feature_gates_:: {RotateKubeletClientCertificate: true},
                  "feature-gates": std.join(",", ["%s=%s" % kv for kv in kube.objectItems(self.feature_gates_)]),
                  "kubeconfig": "/etc/kubernetes/kubelet.conf",
                  "bootstrap-kubeconfig": "/etc/kubernetes/bootstrap-kubelet.conf",
                  "volume-plugin-dir": "/var/lib/kubelet/volumeplugins",
                  // TODO: compare these to defaults:
                  "runtime-request-timeout": "10m",
                  "sync-frequency": "5m",
                  "eviction-hard": std.join(",", [
                    "nodefs.available<1Gi",
                    "imagefs.available<2Gi",
                  ]),
                  "eviction-minimum-reclaim": std.join(",", [
                    "nodefs.available=500Mi",
                    "imagefs.available=2Gi",
                  ]),
                  "eviction-soft": std.join(",", [
                    "nodefs.available<2Gi",
                    "imagefs.available<2Gi",
                  ]),
                  "eviction-soft-grace-period": std.join(",", [
                    "imagefs.available=2m",
                    "nodefs.available=2m",
                  ]),
                  "eviction-max-pod-grace-period": "600",
                },
                ExecStop: "-/usr/bin/rkt stop --uuid-file=/var/cache/kubelet-pod.uuid",
                ExecStopPost: "-/usr/bin/rkt rm --uuid-file=/var/cache/kubelet-pod.uuid",
                Restart: "always",
                RestartSec: "5",
              },
              Install: {
                WantedBy: "multi-user.target",
              },
            },
	  },
          contents: std.manifestIni(self.contents_),
	},
        {
          name: "create-swapfile.service",
          contents_:: {
            sections: {
              Unit: {
                Description: "Create a swapfile",
                RequiresMountsFor: "/var",
                ConditionPathExists: "!/var/vm/swapfile1",
              },
              Service: {
                Type: "oneshot",
                ExecStart: [
                  "/usr/bin/mkdir -p /var/vm",
                  "/usr/bin/fallocate -l 8GiB /var/vm/swapfile1",
                  "/usr/bin/chmod 600 /var/vm/swapfile1",
                  "/usr/sbin/mkswap /var/vm/swapfile1",
                ],
                RemainAfterExit: "true",
              },
            },
          },
          contents: std.manifestIni(self.contents_),
        },
        {
          name: "var-vm-swapfile1.swap",
          contents_:: {
            sections: {
              Unit: {
                Description: "Turn on swap",
                Requires: "create-swapfile.service",
                After: "create-swapfile.service",
              },
              Swap: {
                What: "/var/vm/swapfile1",
              },
              Install: {
                WantedBy: "multi-user.target",
              },
            },
          },
          contents: std.manifestIni(self.contents_),
        },
      ],
    },
    networkd: {},
    passwd: {
      users: [{name: "core", sshAuthorizedKeys: sshKeys}],
    },
  },

  post_install: {
    config: utils.HashedConfigMap("post-install-config") + $.namespace {
      data+: {
        [filekey(f.path)]: f.contents_
        for f in $.ignition_config.storage.files
        if f.filesystem == "root"
      } + {
        ["systemd_" + f.name]: f.contents
        for f in $.ignition_config.systemd.units
        if std.objectHas(f, "contents")
      },
    },

    deploy: kube.DaemonSet("post-install-updater") + $.namespace {
      spec+: {
        template+: {
          spec+: {
            nodeSelector+: {
              // Hijack the updater label
              "container-linux-update.v1.coreos.com/id": "coreos",
            },
            volumes_: {
              data: kube.ConfigMapVolume($.post_install.config),
              systemd: kube.HostPathVolume("/etc/systemd/system", "Directory"),
            } + {
              [filekey(f.path)]: kube.HostPathVolume(f.path, "FileOrCreate")
              for f in $.ignition_config.storage.files
              if f.filesystem == "root" && !std.startsWith(f.path, "/etc/systemd")
            },
            initContainers_+: {
              copier: utils.shcmd("copier") {
                shcmd: std.join("\n", [
                  "cat %s > %s" % [
                    std.escapeStringBash("/in/" + filekey(f.path)),
                    std.escapeStringBash("/target/" + filekey(f.path))]
                  for f in $.ignition_config.storage.files
                  if f.filesystem == "root"
                ] + [
                  "cp %s %s" % [
                    std.escapeStringBash("/in/systemd_" + f.name),
                    std.escapeStringBash("/systemd/" + f.name)]
                  for f in $.ignition_config.systemd.units
                  if std.objectHas(f, "contents")
                ] + [
                  "ln -sf /dev/null %s" % [
                    std.escapeStringBash("/systemd/" + f.name)]
                  for f in $.ignition_config.systemd.units
                  if ({mask: false} + f).mask
                ]),
                volumeMounts_+: {
                  data: {mountPath: "/in", readOnly: true},
                  systemd: {mountPath: "/systemd"},
                } + {
                  [filekey(f.path)]: {mountPath: "/target/" + filekey(f.path)}
                  for f in $.ignition_config.storage.files
                  if f.filesystem == "root" && !std.startsWith(f.path, "/etc/systemd")
                },
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
  },

  ipxe_config: kube.ConfigMap("ipxe-config") + $.namespace {
    local http_url = "http://kube.lan:%d" % [$.httpdSvc.spec.ports[0].nodePort],
    data: {
      "boot.ipxe": |||
        #!ipxe
        set http_url %s

        #set base-url http://beta.release.core-os.net/amd64-usr/current
        # Local IPFS copy, cached on 2018-09-19:
        set base-url http://ipfs.k.lan/ipfs/QmeWaqrxn3PGrxbVfeejQDHPLjA6ETpQcX3epf7avaPwSg
        prompt -k 0x197e -t 2000 Press F12 to install CoreOS to disk || exit
        kernel ${base-url}/coreos_production_pxe.vmlinuz initrd=coreos_production_pxe_image.cpio.gz coreos.autologin=tty1 root=LABEL=ROOT coreos.first_boot=1 coreos.config.url=${http_url}/coreos-kube.ign
        initrd ${base-url}/coreos_production_pxe_image.cpio.gz

        # Fedora CoreOS (WIP)
        #set base-url http://ipfs.k.lan/ipfs/QmWMuK5PN4nQWo6eCAnYo3YP2L3PsoKUULGsM5bfuYZp6w
        #set name fedora-coreos-31.20200113.3.1-live
        #cpuid --ext 29 && set arch x86_64 || set arch x86
        #prompt -k 0x197e -t 2000 Press F12 to install ${name} to disk || exit
        #kernel ${base-url}/${name}-kernel-${arch} ip=dhcp rd.neednet=1 initrd=${name}-initramfs.${arch}.img console=tty0 console=ttyS0 coreos.inst.install_dev=/dev/sda coreos.inst.stream=stable coreos.inst.ignition_url=${http_url}/coreos-kube.ign BOOTIF=01-${net0/mac}
        #initrd ${base-url}/${name}-initramfs.${arch}.img

        boot
	||| % [http_url],

      // Just because I can ...
      "winpe.ipxe": |||
        #!ipxe
        # See http://ipxe.org/howto/winpe
        # Local IPFS copy
        set base-url http://ipfs.k.lan/ipfs/QmTPQ6aeZtk2EwHumbGJFqBeKiNUJidzs586uMj7kuBynn
        cpuid --ext 29 && set arch amd64 || set arch x86
        # http://git.ipxe.org/releases/wimboot/wimboot-latest.zip
        # This is wimboot-2.6.0-signed
        kernel http://ipfs.k.lan/ipfs/QmZemVSA6ub1pN2jUfcNFMLbDfpKFjcWqTustK6sXcQ2eq/wimboot
        initrd ${base-url}/${arch}/bcd BCD
        initrd ${base-url}/${arch}/boot.sdi boot.sdi
        initrd ${base-url}/${arch}/boot.wim boot.wim
        boot
      |||,
      "coreos-kube.ign": kubecfg.manifestJson($.ignition_config),
    },
  },

  tftpboot_fetch:: utils.shcmd("tftp-fetch") {
    shcmd:: |||
      cd /data
      wget http://boot.ipxe.org/undionly.kpxe
      ln -sf undionly.kpxe undionly.0
      wget http://boot.ipxe.org/ipxe.efi
      ln -sf ipxe.efi ipxe.0
    |||,
    volumeMounts_+: {
      tftpboot: { mountPath: "/data" },
    },
  },

  httpdSvc: kube.Service("coreos-pxe-httpd") + $.namespace {
    local this = self,
    target_pod: $.httpd.spec.template,

    spec+: {
      type: "NodePort",
      ports: [{
        port: 80,
        nodePort: 31069,
        targetPort: this.target_pod.spec.containers[0].ports[0].containerPort,
      }],
    },
  },

  httpd: kube.Deployment("coreos-pxe-httpd") + $.namespace {
    spec+: {
      template+: {
        spec+: {
          tolerations+: utils.toleratesMaster,
          containers_+: {
            httpd: kube.Container("httpd") {
              image: "httpd:2.4.33-alpine",
              ports_+: {
                http: { containerPort: 80 },
              },
              volumeMounts_: {
                htdocs: { mountPath: "/usr/local/apache2/htdocs", readOnly: true },
              },
              resources+: {
                requests+: {memory: "10Mi"},
              },
            },
          },
          volumes_+: {
            htdocs: kube.ConfigMapVolume($.ipxe_config)
          },
        },
      },
    },
  },

  dnsmasq: kube.Deployment("coreos-pxe-dnsmasq") + $.namespace {
    local this = self,

    spec+: {
      template+: {
        spec+: pxeNodeSelector + {
          hostNetwork: true,
          dnsPolicy: "ClusterFirstWithHostNet",
          initContainers+: [$.tftpboot_fetch],
          default_container: "dnsmasq",
          containers_+: {
            dnsmasq: kube.Container("dnsmasq") {
              local arch = this.spec.template.spec.nodeSelector["kubernetes.io/arch"],
              local http_url = "http://%s:%d" % ["$(HOST_IP)", $.httpdSvc.spec.ports[0].nodePort],

              // TFTP (not DHCP) could be served via a regular
              // Service, but it needs to be host-reachable, and we
              // don't really want to burn a NodePort on it.
              local tftpserver = "$(POD_IP)",

              image: "gcr.io/google_containers/kube-dnsmasq-%s:1.4" % arch,
              args: [
                "--log-facility=-", // stderr
                "--log-dhcp",
                "--port=0", // disable DNS
                "--dhcp-no-override",

                "--enable-tftp",
                "--tftp-root=/tftpboot",

                "--dhcp-userclass=set:ipxe,iPXE",

              ] + ["--dhcp-vendorclass=%s,PXEClient:Arch:%05d" % c for c in [
                ["BIOS", 0],
                ["UEFI32", 6],
                ["UEFI", 7],
                ["UEFI64", 9],
              ]] + [

                "--dhcp-range=$(POD_IP),proxy",  // Offer proxy DHCP to everyone on local subnet

                "--pxe-prompt=Esc to avoid iPXE boot ...,5",

                // NB: tag handling is last-match-wins
                "--dhcp-boot=tag:!ipxe,undionly.kpxe,,%s" % tftpserver,

                "--pxe-service=tag:!ipxe,X86PC,Boot to undionly,undionly,%s" % tftpserver,
              ] + std.flattenArrays([[
                "--pxe-service=tag:!ipxe,%s,Boot to iPXE,ipxe,%s" % [csa, tftpserver],
                "--pxe-service=tag:ipxe,%s,Run boot.ipxe,%s/boot.ipxe" % [csa, http_url],
                "--pxe-service=tag:ipxe,%s,Boot WinPE,%s/winpe.ipxe" % [csa, http_url],
                "--pxe-service=tag:ipxe,%s,Continue local boot,0" % csa,
              ] for csa in ["x86PC", "X86-64_EFI", "BC_EFI"]]),

              env_: {
                POD_IP: kube.FieldRef("status.podIP"),
                // HOST_IP is same as POD_IP because hostNetwork=true.
                // Used explicitly for clarity.
                HOST_IP: kube.FieldRef("status.hostIP"),
              },

              ports_: {
                dhcp: { hostPort: 67, containerPort: 67, protocol: "UDP" },
                proxydhcp: { hostPort: 4011, containerPort: 4011, protocol: "UDP" },
                tftp: { containerPort: 69, protocol: "UDP" },
              },

              volumeMounts_: {
                leases: { mountPath: "/var/lib/misc" },
                tftpboot: { mountPath: "/tftpboot", readOnly: true },
              },

              securityContext+: {
                capabilities+: {
                  add: ["NET_ADMIN"],
                },
              },
            },
          },
          volumes_: {
            leases: kube.EmptyDirVolume(),
            tftpboot: kube.EmptyDirVolume(),
          },
        },
      },
    },
  },
}
