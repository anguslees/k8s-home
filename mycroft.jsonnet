local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";
local kubecfg = import "kubecfg.libsonnet";

// CLI access is:
//  kubectl exec -ti -n mycroft mycroft-0 ./start-mycroft.sh cli

local image = "mycroftai/docker-mycroft:latest"; // FIXME: a release?

{
  namespace:: {metadata+: {namespace: "mycroft"}},
  ns: kube.Namespace($.namespace.metadata.namespace),

  http_proxy:: error "this file assumes an http_proxy",
  openhab:: error "this file assumes openhab",

  conf: utils.HashedSecret("mycroft") + $.namespace {
    data_+: {
      mycroft:: {
        enclosure: {
          platform: "kubernetes",
          update: true,
        },
        //log_level: "DEBUG",
        WeatherSkill: {
          // FIXME: sealedsecret!
          api_key: "de1317a35fa5b4bc7e23c71afef9aa5c",
        },
        openHABSkill: {
          host: $.openhab.host,
          port: $.openhab.spec.ports[0].port,
        },
      },
      "mycroft.conf": kubecfg.manifestJson(self.mycroft),
    },
  },

  mycroft: kube.StatefulSet("mycroft") + $.namespace {
    spec+: {
      replicas: 1,
      volumeClaimTemplates_: {
        data: {storage: "1G"},
      },
      template+: {
        spec+: {
          nodeSelector+: utils.archSelector("amd64"),
          volumes_+: {
            conf: kube.SecretVolume($.conf),
          },
          initContainers_+: {
            default_skills: kube.Container("default-skills") {
              image: image,
              command: ["/bin/sh", "-e", "-x", "-c", self.shcmd],
              shcmd:: "test -d /dst/mycroft-pairing || cp -R /opt/mycroft/skills /dst",
              volumeMounts_+: {
                dst: {
                  name: "data", subPath: "skills",
                  mountPath: "/dst",
                },
              },
            },
          },
          containers_+: {
            mycroft: kube.Container("mycroft") {
              image: image,
              command: ["/bin/bash", "-c",
                // Hacky workaround for MycroftAI/mycroft-core#1730
                "rm /.dockerenv; exec /opt/mycroft/startup.sh",
              ],
              ports_+: {
                mycroft: {containerPort: 8181},
              },
              env_+: {
                USER: "root", // prepare-msm.sh assumes this is set correctly
                // PULSE_SERVER: ...
                http_proxy: $.http_proxy.http_url,
                no_proxy_:: [".lan", ".local", ".cluster", ".svc",
                             "localhost", "127.0.0.1", "0.0.0.0", "::1"],
                no_proxy: std.join(",", std.set(self.no_proxy_)),
              },
              lifecycle+: {
                preStop: {
                  exec: {command: ["./stop-mycroft.sh"]},
                },
              },
              volumeMounts_+: {
                conf: {mountPath: "/etc/mycroft", readOnly: true},
                dotconf: {
                  name: "data", subPath: "dotconf",
                  mountPath: "/root/.mycroft",
                },
                skills: {
                  name: "data", subPath: "skills",
                  mountPath: "/opt/mycroft/skills",
                },
              },
              readinessProbe: {
                tcpSocket: {port: 8181},
                periodSeconds: 30,
              },
              livenessProbe: self.readinessProbe {
                initialDelaySeconds: 30,
              },
            },
          },
        },
      },
    },
  },
}
