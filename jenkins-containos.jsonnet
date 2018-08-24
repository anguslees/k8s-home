local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";
local jenkins = import "jenkins.jsonnet";

// This adds some additional things into the jenkins namespace
// relevant to my jenkins jobs, but almost certainly not generally
// useful.

{
  namespace:: jenkins.namespace,

  dldir: kube.PersistentVolumeClaim("oe-dl-dir") + $.namespace {
    storageClass: "managed-nfs-storage",
    storage: "20Gi",
    spec+: {
      storageClassName: null, // avoid changing the current default.  FIXME: recreate at some point.
      accessModes: ["ReadWriteMany"],
    },
  },

  sstate: kube.PersistentVolumeClaim("oe-sstate-dir") + $.namespace {
    storageClass: "managed-nfs-storage",
    storage: "200Gi",
    spec+: {
      storageClassName: null, // avoid changing the current default.  FIXME: recreate at some point.
      accessModes: ["ReadWriteMany"],
    },
  },

  gitupdater: kube.CronJob("oe-git-updater") + $.namespace {
    spec+: {
      schedule: "@weekly",
      jobTemplate+: {
        spec+: {
          template+: {
            spec+: {
              securityContext+: {
                runAsUser: 10000,
                fsGroup: self.runAsUser,
              },
              volumes_+: {
                dl: kube.PersistentVolumeClaimVolume($.dldir),
              },
              containers_+: {
                update: utils.shcmd("update") {
                  image: "alpine/git:1.0.4",
                  volumeMounts_+: {
                    dl: {mountPath: "/downloads"},
                  },
                  shcmd: |||
                    cd /downloads/gitref

                    while read name url; do
                      git remote add $name $url || :
                    done <<EOF
                    bitbake git://git.openembedded.org/bitbake
                    oe-core git://git.openembedded.org/openembedded-core
                    meta-openembedded https://github.com/openembedded/meta-openembedded.git
                    meta-rauc https://github.com/rauc/meta-rauc.git
                    meta-containos https://gitlab.com/containos/meta-containos.git
                    meta-sunxi https://github.com/linux-sunxi/meta-sunxi
                    auto-upgrade-helper https://git.yoctoproject.org/git/auto-upgrade-helper
                    EOF

                    git fetch --all --prune
                  |||,
                },
              },
            },
          },
        },
      },
    },
  },
}
