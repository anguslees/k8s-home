local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";

{
  namespace:: {metadata+: {namespace: "openhab"}},
  ns: kube.Namespace($.namespace.metadata.namespace),

  svc: kube.Service("openhab") + $.namespace {
    target_pod: $.deploy.spec.template,
    spec+: {
      ports: [
        {name: "http", port: 8080, targetPort: "http"},
        {name: "https", port: 8443, targetPort: "https"},
        {name: "console", port: 8101, targetPort: "console"},
      ],
    },
  },

  config: {
    items: utils.HashedConfigMap("openhab-items") + $.namespace {
      data+: {
        "senseme.items": (importstr "openhab/items/senseme.items"),
        "kodi.items": (importstr "openhab/items/kodi.items"),
        "xiaomivacuum.items": (importstr "openhab/items/xiaomivacuum.items"),
      },
    },

    sitemaps: utils.HashedConfigMap("openhab-sitemaps") + $.namespace {
      data+: {
        "senseme.sitemap": (importstr "openhab/sitemaps/senseme.sitemap"),
        "kodi.sitemap": (importstr "openhab/sitemaps/kodi.sitemap"),
      },
    },

    things: utils.HashedConfigMap("openhab-things") + $.namespace {
      data+: {
        "senseme.things": (importstr "openhab/things/senseme.things"),
        "kodi.things": (importstr "openhab/things/kodi.things"),
        "chromecast.things": (importstr "openhab/things/chromecast.things"),
      },
    },

    services: utils.HashedConfigMap("openhab-services") + $.namespace {
      data+: {
        "runtime.cfg": (importstr "openhab/services/runtime.cfg") % {
          ing_host: $.ing.host,
        },
        // NB: Only honoured on first start
        "addons.cfg": (importstr "openhab/services/addons.cfg"),
      },
    },

    transform: utils.HashedConfigMap("openhab-transform") + $.namespace {
      data+: {
        "en.map": (importstr "openhab/transform/en.map"),
      },
    },
  },

  ing: utils.Ingress("openhab") + $.namespace {
    host: "openhab.k.lan",
    target_svc: $.svc,
  },

  deploy: kube.StatefulSet("openhab") + $.namespace {
    local this = self,
    spec+: {
      replicas: 1,
      volumeClaimTemplates_: {
        userdata: {storage: "10G", storageClass: "ceph-block"},
      },
      podManagementPolicy: "Parallel",
      template+: {
        spec+: {
          nodeSelector+: utils.archSelector("amd64"),
          terminationGracePeriodSeconds: 5*60,
          // Various UPnP and discovery things assume this.  Would be
          // nice to properly sandbox it, but that means giving all
          // the IoT dongles static addresses :(
          hostNetwork: true,
          volumes_+: {
            ["conf_"+kv[0]]: kube.ConfigMapVolume(kv[1])
            for kv in kube.objectItems($.config)
          } + {
            //usbacm: kube.HostPathVolume("/dev/ttyACM0"),
            conf: kube.EmptyDirVolume(),
            addons: kube.EmptyDirVolume(),
          },
          securityContext+: {
            // does various setup as root before su'ing to 9001 itself
            //runAsUser: 9001, // openhab
            fsGroup: 9001, // openhab
          },
          initContainers_+: {
            // openhab container entrypoint.sh wants to chmod -R
            // /openhab, so /openhab/conf has to be writeable
            conf: kube.Container("conf") {
              image: this.spec.template.spec.containers_.openhab.image,
              command: ["/bin/sh", "-x", "-e", "-c", self.shcmd],
              shcmd:: |||
                cp -av /openhab/conf.dist/. /openhab/conf/
                cd /config
                for d in *; do
                  mkdir -p /openhab/conf/$d
                  cp -v /config/$d/* /openhab/conf/$d/
                  # hey emacs: */
                done
              |||,
              volumeMounts_+: {
                ["conf_"+k]: {mountPath: "/config/"+k, readOnly: true}
                for k in std.objectFields($.config)
              } + {
                conf: {mountPath: "/openhab/conf"},
              },
            },
            // The openhab startup script gets confused by lost+found
            // magically existing in userdata, so need to manually
            // bootstrap on "empty" PV.
            init: kube.Container("init") {
              image: this.spec.template.spec.containers_.openhab.image,
              command: ["/bin/sh", "-x", "-e", "-c", self.shcmd],
              shcmd:: |||
                if [ ! -f /openhab/userdata/etc/version.properties ]; then
                  cp -av /openhab/userdata.dist/. /openhab/userdata/
                fi
              |||,
              volumeMounts_+: {
                userdata: {mountPath: "/openhab/userdata"},
              },
            },
          },
          containers_+: {
            openhab: kube.Container("openhab") {
              local container = self,
              image: "openhab/openhab:2.4.0-alpine",
              command: ["/entrypoint.sh", "su-exec", "openhab", "./start.sh"],
              tty: true,  // Required for odd kafka console thing
              stdin: true,
              ports_+: {
                http: {containerPort: 8080},
                https: {containerPort: 8443},
                // access console via (default user:pass is openhab:habopen):
                //  kubectl exec -ti -n openhab openhab-0 /openhab/runtime/bin/client
                console: {containerPort: 8101},
                lsp: {containerPort: 5007},
              },
              env_+: {
                JAVA_OPTS: std.join(" ", [
                  "-XshowSettings:vm",
                  "-Xmx%dm" % (kube.siToNum(container.resources.requests.memory) /
                      std.pow(2, 20)),
                ]),
                CRYPTO_POLICY: "limited",  // FIXME: unlimited is broken atm?
                LANGUAGE: "en_AU.UTF-8",
                LANG: self.LANGUAGE,
              },
              resources: {
                requests: {cpu: "10m", memory: "500Mi"},
                limits: {cpu: "1000m", memory: "600Mi"},
              },
              volumeMounts_+: {
                //usbacm: {mountPath: "/dev/ttyACM0"},
                conf: {mountPath: "/openhab/conf"},
                userdata: {mountPath: "/openhab/userdata"},
                addons: {mountPath: "/openhab/addons"},
                //.karaf, .java
              },
              readinessProbe: {
                httpGet: {path: "/", port: "http"},
                timeoutSeconds: 10,
                periodSeconds: 30,
              },
              livenessProbe: self.readinessProbe {
                // After a version update, openhab needs to download
                // all the updated modules before it will start acking
                // health checks.  Last time I tried, this took ~2h (!)
                // TODO: Rewrite all of the openhab setup to move
                // that into an init container.
                initialDelaySeconds: 4 * 60 * 60,  // 4h
                timeoutSeconds: 30,
                failureThreshold: 10,
                periodSeconds: 60,
              },
            },
          },
        },
      },
    },
  },
}
