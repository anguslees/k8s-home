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
              image: "gcr.io/google_containers/echoserver:1.8",
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
