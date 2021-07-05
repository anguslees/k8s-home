local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";
local jenkins = import "jenkins.jsonnet";

// This adds some additional things into the jenkins namespace
// relevant to my jenkins jobs, but almost certainly not generally
// useful.

{
  namespace:: jenkins.namespace,

  scratch: kube.PersistentVolumeClaim("oe-scratch") + $.namespace {
    storageClass: "csi-cephfs", // no storage class
    storage: "200Gi",
    spec+: {
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
                scratch: kube.PersistentVolumeClaimVolume($.scratch),
              },
              containers_+: {
                update: utils.shcmd("update") {
                  image: "alpine/git:1.0.4", // renovate
                  volumeMounts_+: {
                    scratch: {mountPath: "/scratch"},
                  },
                  shcmd: |||
                    cd /scratch/downloads/gitref

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

  cleaner: kube.CronJob("oe-sstate-cleaner") + $.namespace {
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
                scratch: kube.PersistentVolumeClaimVolume($.scratch),
              },
              containers_+: {
                update: utils.shcmd("update") {
                  // Need gnu find
                  image: "debian:jessie-slim", // renovate
                  volumeMounts_+: {
                    scratch: {mountPath: "/scratch"},
                  },
                  shcmd: |||
                    cd /scratch

                    echo Before:
                    df -h .

                    find sstate-cache -name 'sstate*' -atime +90 -delete

                    #find downloads -type f -atime +120 -delete

                    echo After:
                    df -h .
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
