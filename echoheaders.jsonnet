local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";

{
  namespace:: {metadata+: {namespace: "default"}},

  ingress: utils.Ingress("echoheaders") + $.namespace {
    host: "echoheaders.k.lan",
    target_svc: $.svc,
  },

  svc: kube.Service("echoheaders") + $.namespace {
    target_pod: $.deploy.spec.template,
  },

  deploy: kube.Deployment("echoheaders") + $.namespace {
    spec+: {
      template+: {
        spec+: {
          nodeSelector+: utils.archSelector("amd64"),
          containers_+: {
            default: kube.Container("echoheaders") {
              image: "k8s.gcr.io/echoserver:1.10", // renovate
              ports_: {
                http: {containerPort: 8080},
              },
            },
          },
        },
      },
    },
  },
}
