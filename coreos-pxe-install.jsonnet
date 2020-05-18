local kube = import "kube.libsonnet";
local kubecfg = import "kubecfg.libsonnet";
local utils = import "utils.libsonnet";

local coreos_kubelet_tag = "v1.18.2";

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

  // Used by `coreos-cloudinit`
  cloud_config: utils.HashedConfigMap("cloud-config") + $.namespace {
    data: {
      user_data: "#cloud-config\n" + kubecfg.manifestYaml($.cloud_config_),
    },
  },
  cloud_config_:: {
    coreos: {
      local unit(name, hascontent=true) = {
        name: name,
        runtime: true,
        content_:: {},
        [if hascontent then "content"]: std.manifestIni(self.content_),
      },
      units: [
        unit("docker.service", false) {
          enable: false,  // started on-demand via docker.socket
        },
        unit("update-engine.service", false) {
          enable: true,
        },
        unit("locksmithd.service", false) {
          enable: false,
          mask: true,
        },
        unit("kubelet.path") {
          enable: true,
          content_:: {
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
        },
        unit("kubelet.service") {
          content_:: {
            sections: {
              Unit: {
                Description: "Kubelet via Hyperkube ACI",
                After: "network.target docker.socket",
                Wants: "docker.socket",
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
                  for p in ["/etc/resolv.conf", "/var/lib/cni", "/etc/cni/net.d", "/opt/cni/bin", "/var/log", "/var/lib/local-data", "/var/lib/calico"]
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
                    "/var/lib/calico",
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
                  "cgroup-driver": "systemd",
                  "hostname-override": "%m",
                  "lock-file": "/var/run/lock/kubelet.lock",
                  "network-plugin": "cni",
                  "cni-conf-dir": "/etc/cni/net.d",
                  "cni-bin-dir": "/opt/cni/bin",
                  "pod-manifest-path": "/etc/kubernetes/manifests",
                  "rotate-certificates": true,
                  "rotate-server-certificates": true,
                  feature_gates_:: {},
                  "feature-gates": std.join(",", ["%s=%s" % kv for kv in kube.objectItems(self.feature_gates_)]),
                  "tls-min-version": "VersionTLS12",
                  "tls-cipher-suites": "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_RSA_WITH_AES_256_GCM_SHA384,TLS_RSA_WITH_AES_128_GCM_SHA256",
                  "serialize-image-pulls": false,
                  "kubeconfig": "/etc/kubernetes/kubelet.conf",
                  "bootstrap-kubeconfig": "/etc/kubernetes/bootstrap-kubelet.conf",
                  "volume-plugin-dir": "/var/lib/kubelet/volumeplugins",
                  // TODO: compare these to defaults:
                    "runtime-request-timeout": "10m",
                  "sync-frequency": "5m",
                  eviction_:: {
                    "nodefs.available": {
                      hard: "1Gi",
                      soft: "2Gi",
                      minimum_reclaim: "500Mi",
                      soft_grace_period: "2m",
                    },
                    "imagefs.available": {
                      hard: "2Gi",
                      soft: "3Gi",
                      minimum_reclaim: "1Gi",
                      soft_grace_period: "2m",
                    },
                  },
                  local manifestEviction(key, template) = std.join(",", [
                    template % [kv[0], kv[1][key]] for kv in kube.objectItems(self.eviction_)
                    if std.objectHas(kv[1], key)
                  ]),
                  "eviction-hard": manifestEviction("hard", "%s<%s"),
                  "eviction-minimum-reclaim": manifestEviction("minimum_reclaim", "%s=%s"),
                  "eviction-soft": manifestEviction("soft", "%s<%s"),
                  "eviction-soft-grace-period": manifestEviction("soft_grace_period", "%s=%s"),
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
        },
        unit("create-swapfile.service") {
          content_:: {
            sections: {
              Unit: {
                Description: "Create a swapfile",
                RequiresMountsFor: "/var",
                ConditionPathExists: "!/var/vm/swapfile1",
                // Avoid (circular) dependency on basic.target
                DefaultDependencies: "no",
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
        },
        unit("var-vm-swapfile1.swap") {
          content_:: {
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
                WantedBy: "swap.target",
              },
            },
          },
        },
      ],
    },
    ssh_authorized_keys: sshKeys,
    local file(path, content) = {
      path: path,
      permissions: "0644",
      owner: "root",
      content: content,
    },
    write_files: [
      file("/etc/kubernetes/kubelet.env", |||
        KUBELET_IMAGE_URL=docker://k8s.gcr.io/hyperkube
        KUBELET_IMAGE_TAG=%(tag)s
        KUBELET_IMAGE_ARGS=--exec=kubelet
        RKT_GLOBAL_ARGS="--insecure-options=image"
      ||| % {tag: coreos_kubelet_tag},
      ),
      file("/etc/sysctl.d/max-user-watches.conf", |||
        fs.inotify.max_user_watches=16184
      |||
      ),
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
        "vm.swappiness=10\n"),
      file("/etc/docker/daemon.json",
        kubecfg.manifestJson({
          "exec-opts": ["native.cgroupdriver=systemd"],
          "storage-driver": "overlay2",
          "log-driver": "json-file",
          "log-opts": {"max-size": "100m"},
        })),
    ],
  },

  post_install: kube.DaemonSet("post-install-updater") + $.namespace {
    spec+: {
      template+: {
        spec+: {
          affinity+: {
            nodeAffinity: {
              requiredDuringSchedulingIgnoredDuringExecution: {
                nodeSelectorTerms: [{
                  matchExpressions: [{
                    // Hijack the updater label
                    key: "flatcar-linux-update.v1.flatcar-linux.net/id",
                    operator: "In",
                    values: std.set(["flatcar"]),
                  }],
                }],
              },
            },
          },
          volumes_: {
            config: kube.ConfigMapVolume($.cloud_config),
            dest: kube.HostPathVolume("/var/lib/flatcar-install", "DirectoryOrCreate"),
          },
          initContainers_+: {
            copy: utils.shcmd("copy") {
              shcmd: 'cp /config/user_data /dest/',
              volumeMounts_+: {
                config: {mountPath: "/config", readOnly: true},
                dest: {mountPath: "/dest"},
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

  ipxe_config: utils.HashedConfigMap("ipxe-config") + $.namespace {
    local http_url = "http://kube.lan:%d" % [$.httpdSvc.spec.ports[0].nodePort],
    data: {
      "boot.ipxe": |||
        #!ipxe
        set http_url %s

        #set base-url http://beta.release.flatcar-linux.net/amd64-usr/current
        # Local IPFS copy, cached on 2020-04-13:
        set base-url http://ipfs.k.lan/ipfs/QmVdgm13jqUsVcHQsxjT4fbTEMPaspCQ1jUdKSBZifVPfv
        prompt -k 0x197e -t 2000 Press F12 to install Flatcar to disk || exit
        kernel ${base-url}/flatcar_production_pxe.vmlinuz initrd=flatcar_production_pxe_image.cpio.gz flatcar.autologin=tty1 root=LABEL=ROOT flatcar.first_boot=1 ignition.config.url=${http_url}/pxe-config.ign
        initrd ${base-url}/flatcar_production_pxe_image.cpio.gz

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

      "cloud-init.yml": $.cloud_config.data.user_data,
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

  httpdSvc: kube.Service("pxe-httpd") + $.namespace {
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

  httpd: kube.Deployment("pxe-httpd") + $.namespace {
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

  dnsmasq: kube.Deployment("pxe-dnsmasq") + $.namespace {
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
