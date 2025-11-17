local kube = import "kube.libsonnet";
local kubecfg = import "kubecfg.libsonnet";
local utils = import "utils.libsonnet";

// NB: To rolling-reboot all the nodes:  (I think it needs label _and_ annotation??)
//   kubectl annotate nodes -l flatcar-linux-update.v1.flatcar-linux.net/id flatcar-linux-update.v1.flatcar-linux.net/reboot-needed=true
//   kubectl label nodes -l flatcar-linux-update.v1.flatcar-linux.net/id flatcar-linux-update.v1.flatcar-linux.net/reboot-needed=true

// renovate: depName=kubernetes/kubernetes datasource=github-releases versioning=semver
local kubelet_tag = "v1.34.2";

local default_env = {
  // NB: dockerd can't route to a cluster LB VIP? (fixme)
  //http_proxy: "http://proxy.lan:80/",
  // Causes more surprises than it solves.
  //http_proxy: "http://192.168.0.10:3128/",
  //no_proxy: ".lan,.local",
};

local arch = "amd64";

local pxeNodeSelector = {
  tolerations+: utils.toleratesMaster,
  nodeSelector+: utils.archSelector(arch),
};

local sshKeys = [
  importstr "/home/gus/.ssh/id_ed25519.pub",
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
        unit("containerd.service", false) {
          enable: false,  // use kube-containerd
          mask: true,
        },
        unit("docker.service", false) {
          enable: false,  // use kube-containerd
          mask: true,
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
          command: "start",
          content_:: {
            sections: {
              Unit: {
                Description: "Watch for kubeconfig",
              },
              Path: {
                PathExists: "/etc/kubernetes/bootstrap-kubelet.conf",
              },
              Install: {
                WantedBy: "multi-user.target",
              },
            },
          },
        },
        unit("kube-containerd.service") {
          enable: true,
          content_:: {
            sections: {
              Unit: {
                Description: "Containerd container runtime",
                Documentation: "https://containerd.io",
                // containerd cri plugin gets upset if defaultroute doesn't exist
                // https://github.com/containerd/cri/pull/794#issuecomment-408830059
                Wants: "network-online.target",
                After: "network-online.target local-fs.target",
              },
              Service: {
                Environment: "CONTAINERD_CONFIG=/etc/containerd/config.toml",
                Slice: "podruntime.slice",
                ExecStart: "/usr/bin/containerd -a /run/containerd/containerd.sock --config ${CONTAINERD_CONFIG}",
                Delegate: "yes",
                KillMode: "process",
                Restart: "always",

                LimitNOFILE: 1048576,
                LimitNPROC: "infinity",
                LimitCORE: "infinity",
                TasksMax: "infinity",
              },
            },
          },
        },
        unit("kubelet.service") {
          enable: true,
          command: "start",
          content_:: {
            sections: {
              Unit: {
                Description: "Kubelet",
                After: "network.target kube-containerd.service",
                Wants: "kube-containerd.service",
              },
              Service: {
                EnvironmentFile: "/etc/kubernetes/kubelet.env",
                ExecStartPre: [
                  "/bin/mkdir -p " + std.join(" ", [
                    "/opt/cni/bin",
                    "/etc/cni/net.d",
                  ]),
                  "/opt/bin/download-kubelet /opt/kubelet ${KUBELET_VERSION}",
                ],
                Slice: "podruntime.slice",
                // TODO: /v/l/kubelet/plugins{,_registry} should maybe move to /run
                ConfigurationDirectory: std.join(" ", ["kubernetes", "kubernetes/manifests", "kubernetes/checkpoint-secrets", "kubernetes/inactive-manifests"]),
                LogsDirectory: std.join(" ", ["pods", "containers"]),
                StateDirectory: std.join(" ", ["kubelet", "kubelet/volumeplugins", "cni", "local-data", "calico"]),
                ExecStart: std.join(" \\\n ", [
                  "/opt/kubelet/kubelet",
                ] + [
                  "--%s=%s" % kv for kv in kube.objectItems(self.args_)
                ]),
                // https://github.com/kubernetes/release/blob/master/rpm/10-kubeadm.conf
                args_:: {
                  //v: 3,
                  "anonymous-auth": false,
                  "client-ca-file": "/var/lib/kubelet/pki/kube-ca/ca.crt",
                  "authentication-token-webhook": true,
                  "authorization-mode": "Webhook",
                  "cluster-dns": "10.96.0.10",
                  "cluster-domain": "cluster.local",
                  "cert-dir": "/var/lib/kubelet/pki",
                  allowed_unsafe_sysctls:: ["net.core.rmem_*"],
                  "allowed-unsafe-sysctls": std.join(",", std.set(self.allowed_unsafe_sysctls)),
                  "exit-on-lock-contention": true,
                  "pod-max-pids": "10000",
                  "fail-swap-on": false,
                  "kernel-memcg-notification": true,
                  "cgroup-driver": "systemd",
                  "cgroup-root": "/",
                  "container-runtime": "remote",
                  "container-runtime-endpoint": "unix:///run/containerd/containerd.sock",
                  "hostname-override": "%m",
                  "lock-file": "/var/run/lock/kubelet.lock",
                  "pod-manifest-path": "/etc/kubernetes/manifests",
                  "rotate-certificates": true,
                  "rotate-server-certificates": true,
                  feature_gates_:: {
                    IPv6DualStack: true,
                    NodeSwap: true,
                    DisableCloudProviders: true,
                    //DisableCloudCredentialProviders: true,  // 1.23
                  },
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
                  kube_reserved_:: { // NB: not enforced
                    cpu: "100m",
                    memory: "256Mi",
                    "ephemeral-storage": "256Mi",
                    pid: 100,
                  },
                  "kube-reserved": std.join(",", ["%s=%s" % kv for kv in kube.objectItems(self.kube_reserved_)]),
                  "kube-reserved-cgroup": "/podruntime.slice",
                  system_reserved_:: { // NB: not enforced
                    cpu: "10m",
                    memory: "100Mi",
                    "ephemeral-storage": "500Mi",
                    pid: 1000,
                  },
                  "system-reserved": std.join(",", ["%s=%s" % kv for kv in kube.objectItems(self.system_reserved_)]),
                  "system-reserved-cgroup": "/system.slice",
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
                Restart: "always",
                RestartSec: "10",
                StartLimitInterval: "0",
              },
              Install: {
                WantedBy: "multi-user.target",
              },
            },
          },
        },
        unit("zz-default.network", hascontent=false) {
          "drop-ins": [{
            name: "50-garagecloud.conf",
            content: std.manifestIni(self.content_),
            content_:: {
              sections: {
                Network: {
                  IPv6AcceptRA: "true",
                },
              },
            },
          }],
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
                  "/usr/bin/dd if=/dev/zero of=/var/vm/swapfile1 bs=1M count=8096",
                  "/usr/bin/chmod 600 /var/vm/swapfile1",
                  "/usr/sbin/mkswap /var/vm/swapfile1",
                ],
                RemainAfterExit: "true",
              },
            },
          },
        },
        unit("var-vm-swapfile1.swap") {
          enable: true,
          command: "start",
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
        unit("losetup@.service") {
          runtime: false,
          content_:: {
            sections: {
              Unit: {
                Description: "Loopback device for %f",
                DefaultDependencies: "no",
                RequiresMountsFor: "%f",
                Conflicts: "umount.target",
              },
              Service: {
                Type: "oneshot",
                RemainAfterExit: "yes",
                ExecStart: "/usr/sbin/losetup --direct-io=on --find %f",
                ExecStop: "/usr/sbin/losetup --detach %f",
              },
              Install: {
                WantedBy: "local-fs.target",
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
      file("/opt/bin/download-kubelet", importstr "download-kubelet") {
        permissions: "0755",
      },
      file("/etc/kubernetes/kubelet.env", |||
        KUBELET_VERSION=%(tag)s
      ||| % {tag: kubelet_tag},
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
      file("/etc/sysctl.d/80-garagecloud.conf",
        "vm.swappiness=10\n"),
      file("/usr/share/oem/grub.cfg", |||
        set linux_append="$linux_append coreos.config.url=oem:///coreos-install.json"
        set linux_append="$linux_append systemd.unified_cgroup_hierarchy=1"
      |||
      ),
      file("/etc/systemd/system.conf.d/garagecloud.conf",
        std.manifestIni({
          sections: {
            Manager: {
              RuntimeWatchdogSec: "20s",
            },
          },
        })),
      file("/etc/docker/daemon.json",
        kubecfg.manifestJson({
          "exec-opts": ["native.cgroupdriver=systemd"],
          "storage-driver": "overlay2",
          "log-driver": "json-file",
          "log-opts": {"max-size": "100m"},
        })),
      file("/etc/kubernetes/kubelet.conf",
        kubecfg.manifestYaml({
          apiVersion: "v1",
          kind: "Config",
          clusters: [{
            name: "default-cluster",
            cluster: {
              "certificate-authority": "/var/lib/kubelet/pki/kube-ca/ca.crt",
              server: "https://kube.lan:6443",
            },
          }],
          users: [{
            name: "default-auth",
            user: {
              "client-certificate": "/var/lib/kubelet/pki/kubelet-client-current.pem",
              "client-key": "/var/lib/kubelet/pki/kubelet-client-current.pem",
            },
          }],
          contexts: [{
            name: "default-context",
            context: {
              cluster: "default-cluster",
              namespace: "default",
              user: "default-auth",
            },
          }],
          "current-context": "default-context",
        })),
      file("/etc/containerd/config.toml",
        utils.manifestToml({
          version: 2,
          subreaper: true,
          oom_score: -999,
          grpc: {
            address: "/run/containerd/containerd.sock",
            uid: 0,
            gid: 0,
          },
          metrics: {
            address: "127.0.0.1:1338",
          },
          plugins: {
            "io.containerd.grpc.v1.cri": {
              containerd: {
                default_runtime_name: "runc",
                runtimes: {
                  runc: {
                    runtime_type: "io.containerd.runc.v2",
                    options: {
                      SystemdCgroup: true,
                    },
                  },
                },
              },
              registry: {
                mirrors: {
                  "docker.io": {endpoint: ["https://registry-1.docker.io"]},
                },
              },
            },
          },
        })),
      file("/etc/udev/rules.d/20-looppath.rules", |||
        # loop
        KERNEL=="loop[0-9]*", ATTRS{loop/backing_file}=="?*", PROGRAM="/bin/sh -c 'echo %s{loop/backing_file} | tr / -'", ENV{ID_PATH}="loop$result", OPTIONS+="string_escape=replace"
      |||
      ),
    ],
  },

  post_install: kube.DaemonSet("post-install-updater") + $.namespace {
    spec+: {
      template+: utils.CriticalPodSpec + {
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
            kubeca: kube.HostPathVolume("/var/lib/kubelet/pki/kube-ca", "DirectoryOrCreate"),
          },
          tolerations+: utils.toleratesMaster,
          priorityClassName: "system-node-critical",
          hostNetwork: true,
          terminationGracePeriodSeconds: 1,
          initContainers_+: {
            copy: utils.shcmd("copy") {
              shcmd: "cp /config/user_data /dest/",
              volumeMounts_+: {
                config: {mountPath: "/config", readOnly: true},
                dest: {mountPath: "/dest"},
              },
            },
            cacopy: utils.shcmd("cacopy") {
              shcmd: "cp /var/run/secrets/kubernetes.io/serviceaccount/ca.crt /kube-ca/ca.crt",
              volumeMounts_+: {
                kubeca: {mountPath: "/kube-ca"},
              },
            },
          },
          containers_: {
            status: kube.Container("status") {
              // Limit the rate of the kubelet rollout to the daemonset rollout
              image: "busybox",
              command: ["cat", "/dev/stdin"], // cheap 'sleep forever'
              stdin: true,
              readinessProbe: {
                exec+: {
                  command: [
                    // This only blocks on kubelet version.  Ideally
                    // it should block on every change implied by
                    // initContainer (perhaps even require a reboot).
                    "/bin/sh", "-e", "-x", "-c", |||
                      v="$(wget -qO- http://localhost:10255/metrics | sed -n 's/^kubernetes_build_info{.*git_version="\([^"]*\)".*/\1/p')"
                      test "$v" = %s
                    ||| % std.escapeStringBash(kubelet_tag),
                  ],
                },
                timeoutSeconds: 30,
                periodSeconds: 30*60, // 30mins
                initialDelaySeconds: 2*60,
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
        isset ${ip} || dhcp || echo DHCP failed

        #chain --autofree http://boot.ipxe.org/ipxe.lkrn ||

        :main_menu
        imgfree
        menu iPXE Boot Menu
        item local Boot local hdd
        item worker_install Install k8s worker
        item flatcar Boot flatcar
        item coreos Boot Fedora CoreOS
        item coreos_install Install Fedora CoreOS
        item debian Boot Debian installer (stable)
        item windows Boot Windows PE
        item --gap Other
        item netbootxyz Chain to netboot.xyz
        item shell iPXE shell
        choose menu && goto ${menu}
        goto local

        :error
        echo Error occured, press any key to return to menu ...
        prompt
        goto main_menu

        :local
        echo Booting from local disks ...
        exit 0

        :netbootxyz
        imgtrust --allow ||
        chain http://boot.netboot.xyz/
        exit

        :shell
        echo Type "exit" to return to menu.
        imgtrust --allow ||
        shell
        imgtrust ||
        goto main_menu

        :debian
        set debmirror http://cdn.debian.net/debian/
        set release stable
        cpuid --ext 29 && set arch amd64 || set arch i386
        set base-url ${debmirror}/dists/${release}/main/installer-${arch}/current/images/netboot/debian-installer/${arch}
        set 209:string pxelinux.cfg/default
        set 210:string ${base-url}
        chain --autofree ${base-url}/pxelinux.0
        boot
        goto error

        :flatcar
        cpuid --ext 29 && set arch amd64 || set arch i386
        set base-url http://beta.release.flatcar-linux.net/${arch}-usr/current

        kernel ${base-url}/flatcar_production_pxe.vmlinuz initrd=flatcar_production_pxe_image.cpio.gz flatcar.autologin
        initrd ${base-url}/flatcar_production_pxe_image.cpio.gz
        prompt Press enter when ready to boot
        boot
        goto error

        # Doesn't actually do anything, since the ignition 'install' just configures the ramdisk :/
        :worker_install
        cpuid --ext 29 && set arch amd64 || set arch i386
        set base-url http://beta.release.flatcar-linux.net/${arch}-usr/current
        # Local IPFS copy, cached on 2020-04-13:
        #set base-url http://ipfs.k.lan/ipfs/QmVdgm13jqUsVcHQsxjT4fbTEMPaspCQ1jUdKSBZifVPfv
        prompt -k 0x197e -t 10000 Press F12 to install to disk || goto error
        kernel ${base-url}/flatcar_production_pxe.vmlinuz initrd=flatcar_production_pxe_image.cpio.gz flatcar.autologin=tty1 flatcar.first_boot=1 ignition.config.url=${http_url}/pxe-config.ign
        # root=LABEL=ROOT ds=nocloud-net;s=${http_url}/
        initrd ${base-url}/flatcar_production_pxe_image.cpio.gz
        boot
        goto error

        :coreos
        # Fedora CoreOS
        set version 32.20200726.3.1
        set name fedora-coreos-${version}-live
        set stream stable
        cpuid --ext 29 && set arch x86_64 || set arch x86
        set base-url http://builds.coreos.fedoraproject.org/prod/streams/${stream}/builds/${version}/${arch}
        kernel ${base-url}/${name}-kernel-${arch} ip=dhcp rd.neednet=1 initrd=${name}-initramfs.${arch}.img,${name}-rootfs.${arch}.img console=tty0 console=ttyS0 ignition.platform.id=metal ignition.config.url=${http_url}/pxe-config.ign BOOTIF=01-${net0/mac}
        initrd ${base-url}/${name}-initramfs.${arch}.img
        initrd ${base-url}/${name}-rootfs.${arch}.img
        boot
        goto error

        :coreos_install
        # Fedora CoreOS
        #set base-url http://ipfs.k.lan/ipfs/QmWMuK5PN4nQWo6eCAnYo3YP2L3PsoKUULGsM5bfuYZp6w
        set version 32.20200726.3.1
        set name fedora-coreos-${version}-live
        set stream stable
        cpuid --ext 29 && set arch x86_64 || set arch x86
        set base-url http://builds.coreos.fedoraproject.org/prod/streams/${stream}/builds/${version}/${arch}
        prompt -k 0x197e -t 10000 Press F12 to install ${name} to disk || goto error
        kernel ${base-url}/${name}-kernel-${arch} ip=dhcp rd.neednet=1 initrd=${name}-initramfs.${arch}.img,${name}-rootfs.${arch}.img console=tty0 console=ttyS0 coreos.inst.install_dev=/dev/sda coreos.inst.stream=stable coreos.inst.ignition_url=${http_url}/pxe-config.ign BOOTIF=01-${net0/mac}
        initrd ${base-url}/${name}-initramfs.${arch}.img
        initrd ${base-url}/${name}-rootfs.${arch}.img
        boot
        goto error

        :windows
        set arch x64
        # See http://ipxe.org/howto/winpe
        # Local IPFS copy
        set base-url http://ipfs.k.lan/ipfs/QmTPQ6aeZtk2EwHumbGJFqBeKiNUJidzs586uMj7kuBynn
        # http://git.ipxe.org/releases/wimboot/wimboot-latest.zip
        # This is wimboot-2.6.0-signed
        imgfree
        kernel http://ipfs.k.lan/ipfs/QmZemVSA6ub1pN2jUfcNFMLbDfpKFjcWqTustK6sXcQ2eq/wimboot
        initrd -n bcd ${base-url}/${arch}/bcd BCD ||
        initrd -n boot.sdi ${base-url}/${arch}/boot.sdi boot.sdi ||
        initrd -n boot.wim ${base-url}/${arch}/boot.wim boot.wim ||
        #imgstat
        #prompt
        boot
        goto error
      ||| % [http_url],

      "cloud-init.yml": $.cloud_config.data.user_data,
      "user-data": self["cloud-init.yml"],

      // coreos/flatcar wants to install using ignition.
      // see https://coreos.com/ignition/docs/latest/configuration-v2_1.html
      ignition_config:: {
        ignition: {version: "2.1.0"},
        storage: {
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
          files: [{
            filesystem: "root",
            path: "/var/lib/flatcar-install/user_data",
            contents: {
              source: "http://kube.lan:%d/user-data" % [$.httpdSvc.spec.ports[0].nodePort],
              verification: {
                // Alas, jsonnet doesn't have a sha512 yet.
                //hash: "sha512-%s" % std.sha512($.cloud_config.data.user_data),
              },
            },
          }],
        },
      },
      "pxe-config.ign": kubecfg.manifestJson(self.ignition_config),
    },
  },

  tftpboot_fetch:: utils.shcmd("tftp-fetch") {
    shcmd:: |||
      cd /data
      rm -f undionly.kpxe ipxe.efi ipxe.pxe
      wget http://boot.ipxe.org/undionly.kpxe
      ln -sf undionly.kpxe undionly.0
      wget http://boot.ipxe.org/ipxe.efi
      wget http://boot.ipxe.org/ipxe.pxe
      ln -sf ipxe.pxe ipxe.0
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
              image: "httpd:2.4.65-alpine", // renovate
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

              // renovate: depName=registry.k8s.io/kube-dnsmasq-amd64
              local version = "1.4",
              image: "registry.k8s.io/kube-dnsmasq-%s:%s" % [arch, version],
              args: [
                "--log-facility=-", // stderr
                "--log-dhcp",
                "--port=0", // disable DNS
                "--dhcp-no-override",

                "--enable-tftp",
                "--tftp-root=/tftpboot",

                "--dhcp-userclass=set:ipxe,iPXE",

              ] + ["--dhcp-vendorclass=set:%s,PXEClient:Arch:%05d" % c for c in [
                ["BIOS", 0],
                ["UEFI32", 6],
                ["UEFI", 7],   // aka BC_EFI
                ["UEFI64", 9], // aka X86-64_EFI
              ]] + [
                "--dhcp-vendorclass=set:UEFI64-HTTP,HTTPClient:Arch:00016",

                "--dhcp-range=$(POD_IP),proxy",  // Offer proxy DHCP to everyone on local subnet

                //"--pxe-prompt=Esc to avoid iPXE boot ...,5",

                // NB: tag handling is last-match-wins
                "--dhcp-boot=tag:!ipxe,undionly.kpxe,,%s" % tftpserver,

                // Shiny UEFI boot by HTTP
                "--dhcp-boot=tag:UEFI64-HTTP,%s/ipxe.efi" % http_url,
                "--dhcp-option-force=tag:UEFI64-HTTP,60,HTTPClient",

                "--pxe-service=tag:!ipxe,x86PC,Boot to undionly,undionly,%s" % tftpserver,
                "--pxe-service=tag:!ipxe,x86PC,Boot to full iPXE,ipxe,%s" % tftpserver,
                "--pxe-service=tag:!ipxe,X86-64_EFI,Boot to iPXE (X86-64),ipxe.efi,%s" % tftpserver,
                "--pxe-service=tag:!ipxe,BC_EFI,Boot to iPXE (BC),ipxe.efi,%s" % tftpserver,
                "--dhcp-boot=tag:ipxe,%s/boot.ipxe" % http_url,
              ],
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
