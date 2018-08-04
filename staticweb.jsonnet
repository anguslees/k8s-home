local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";

{
  namespace:: {
    metadata+: { namespace: "staticweb" },
  },

  ns: kube.Namespace($.namespace.metadata.namespace),

  ingress: utils.Ingress("staticweb") + $.namespace {
    host: "static.k.lan",
    target_svc: $.svc,
  },

  svc: kube.Service("staticweb-data") + $.namespace {
    target_pod: $.httpd.spec.template,
  },

  pvc: kube.PersistentVolumeClaim("staticweb-data") + $.namespace {
    storage: "10Gi",
  },

  httpd: kube.Deployment("staticweb-httpd") + $.namespace {
    spec+: {
      template+: {
        spec+: {
          containers_+: {
            httpd: kube.Container("httpd") {
              image: "httpd:2.4.33-alpine",
              ports_+: {
                http: { containerPort: 80 },
              },
              volumeMounts_: {
                htdocs: { mountPath: "/usr/local/apache2/htdocs", readOnly: true },
              },
              livenessProbe: self.readinessProbe {
                initialDelaySeconds: 60,
                timeoutSeconds: 10,
                periodSeconds: 30,
                failureThreshold: 3,
              },
              readinessProbe: {
                httpGet: {path: "/", port: 80},
              },
              resources+: {
                requests+: {memory: "10Mi"},
              },
            },
          },
          volumes_+: {
            htdocs: kube.PersistentVolumeClaimVolume($.pvc),
          },
        },
      },
    },
  },
}
