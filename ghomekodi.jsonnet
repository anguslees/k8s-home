// https://github.com/OmerTu/GoogleHomeKodi
local kube = import "kube.libsonnet";
local kubecfg = import "kubecfg.libsonnet";
local utils = import "utils.libsonnet";

// Nov 5, 2017
local version = "3824e0ee27df3d081371785d0f20cce8dfd835e3";

local port = 8099;

{
  namespace:: {metadata+: {namespace: "google-home-kodi"}},

  ns: kube.Namespace($.namespace.metadata.namespace),

  ingress: utils.Webhook("google-home-kodi", "/ifttt-kodi") + $.namespace {
    metadata+: {
      annotations+: {"ingress.kubernetes.io/rewrite-target": "/"},
    },
    target_svc: $.svc,
  },

  config: utils.SealedSecret("google-home-kodi") + $.namespace {
    // If data_ is changed, reseal with ./seal.sh ghomekodi-secret.jsonnet
    data_: {
      kodi:: {
        id: "kodi",
        kodiIp: "tellymonster.lan",
        kodiPort: "8080",
        kodiUser: "kodi",
        kodiPassword: error "secret! kodi password not overridden",
      },
      global:: {
        authToken: error "secret! authToken not overridden",
        listenerPort: std.toString(port),
        youtubeKey: error "secret! youtubeKey not overridden",
      },
      "kodi-hosts.config.js": |||
        exports.kodiConfig = %s;
        exports.globalConfig = %s;
      ||| % [
        kubecfg.manifestJson([self.kodi]),
        kubecfg.manifestJson(self.global),
      ],
    },
    spec+: {
      data: "AgBZSJeeKEkNs3IXt+UloaftbdYMlAjc5FeWAs8Bct08aFmv20PHnvixVjd6pWtbWg7fLZmpHt/8Q8p+7D2kFNQar64R6ySW2VJjtunnAUNzkxgcegPrbGU1atvJY/s4xiqeVVkGHPl9H6EpQ2dvxFydSx6jSMtDfln9QRtSMSMC5rpVX9CdjCBl5F9Y6v4QRf4pa+sogs+rkQOUaHCxJAdTkKUuxUMFB3/W/4dZ0h8/5P8Njb05vm8ZinePGhGp+gKlAgDQiUciuHTlXxAAn8oiztGZ6ns/TxE8YoAQ8GLtIrXdVlnG2hJHs8KFWdGfUQ6Hrqif+llsZIENANYmVrIhR1LX+d358A8fdP1kZAMHSKM0nS21twaEiqVRV12yh0ZFYTIH4GwuXbkY6YZP89tMAQsHBoFMtPyftJyEcns9So6PcGl7jS9GuFEFr5CEwFft9ThS/Un34CCevlSPF581bnPudcvGSw6Vr1xpOA4kwqVuBNHfKqsj9smIrRa5sJhfpwgruUTfH23Gc57KuV5XfztTEuFFPxdzR8MUzlfDNj+Ckn7omSnf0IhA59gxOzS2dixtCagB8W8zERUVzCOQYqDnfZG6awuIRgJYMViexh2E+7EWNejinI4hs9kmUarB7vKh1StDT82fp+2O/JOyEduM+EVxvC5SuPEsYzGcT4xNzIoWdAazexcvYkAu03/eCfcfmtBImm6AXWVoeZuMsBmioGUAB4WdYQJdVtQz1+9+zYL5qMSfd7trVGlWdz7nIzVJLm5Nl5MDBccG2L2Lyp1t8E7x0V0Ohcf4CDq3UrKG/RWhVdshpv8Gf3Rgu3aPTLfupWSLzkw1m8g7L1GF2ABMQEYJDJYJnQp9ieDPvk2aqGdoG8TteY88TCDPxnoMq7l5i+Asxlh8u3zGjnKTNZK7+ed0+W5XdLnlWyRfPg3w+nSiBhxVD9xCJLVYX93npXt4mOYHJJcEV4I2AGAbgkqKeaJhJmQZ/Tbh25Kd5cTljfiJxObaCiHhSgHXaHMB/2ipQkDTAWxNgSGrhghHjoMxpRl2+dueI9mNrv8n4IdUA5ZrRxz6X4vbvP1FEBehsILFTqHtePd+o6OAqzbkHBliKT4lg4nO8XY3WDL86s0lTQXYkEFnNZRJgfERXqtn3nj8ELW5GDaoZFDjWkiV6csJzNngxwg6NPkpj7EC9eekVB4PNtpc1GxDhT5cHEsN4ZaHiHbDOOYcGFkGgaAwRwy2w+Ud/wujpQFl/9WgifUNGoKREWnpLMuYsS7YTACdnAgN0/BKS3xMwkkol3+NWQwK3EzruZSxlU+2k9opkzLunFW0V28u6j9e2L1Mtw69eb2na6psYCYWrrPrM4giQGKpvDoFHGHP3xHfTf8I7O7w5tV/OO32GJhZ6X8de89We4PXMfGcQSqel6vCOTNMLBVE2bQWFUPF9MsxZC0f2wkk2tcVx/6UJqxqSCXOJQvkFaofeXqaNzrE9YlRZFx923Bc6/ebYXSACjQQoxBQtRJfL7MKN6MiAE2h3L02Fc20fhk=",
    },
  },

  svc: kube.Service("google-home-kodi") + $.namespace {
    target_pod: $.deploy.spec.template,
  },

  deploy: kube.Deployment("google-home-kodi") + $.namespace {
    local this = self,
    spec+: {
      template+: {
        spec+: {
          initContainers+: [
            this.spec.template.spec.containers_.default {
              name: "npm-install",
              command: ["npm", "install"],
            },
          ],
          volumes_+: {
            app: kube.GitRepoVolume("https://github.com/OmerTu/GoogleHomeKodi", version),
            config: kube.SecretVolume($.config),
          },
          containers_+: {
            default: kube.Container("server") {
              image: "node:9.1.0-alpine",
              workingDir: "/app/GoogleHomeKodi",
              command: ["node", "server.js"],
              ports_+: {
                default: {containerPort: port, protocol: "TCP"},
              },
              volumeMounts_+: {
                app: {mountPath: "/app", readOnly: false},
                config: {
                  mountPath: "/app/GoogleHomeKodi/kodi-hosts.config.js",
                  subPath: "kodi-hosts.config.js",
                  readOnly: true,
                },
              },
            },
          },
        },
      },
    },
  },
}
