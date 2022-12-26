local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";
local certman = import "cert-manager.jsonnet";

// NB: create accounts using
// kubectl -n restic exec -ti rest-server-xxx create_user myuser
// (modifies /data/.htpasswd in place)

local host = "restic.oldmacdonald.farm";

{
  namespace:: {metadata+: {namespace: "restic"}},

  ns: kube.Namespace($.namespace.metadata.namespace),

  cert: certman.Certificate("cert") + $.namespace {
    spec+: {
      issuer_:: certman.letsencryptProd,
      local i = self.issuer_,
      issuerRef: {
        name: i.metadata.name,
        [if std.objectHas(i.metadata, "namespace") then "namespace"]: i.metadata.namespace,
        kind: i.kind,
      },
      isCA: false,
      usages: ["digital signature", "key encipherment"],
      dnsNames: [host],
      secretName: "ingress-tls",
      duration_h_:: 365 * 24 / 4, // 3 months
      duration: "%dh" % self.duration_h_,
      renewBefore_h_:: self.duration_h_ / 3,
      renewBefore: "%dh" % self.renewBefore_h_,
      privateKey: {algorithm: "ECDSA"},
      revisionHistoryLimit: 1,
    },
  },

  ingress: utils.Ingress("ingress") + $.namespace {
    local this = self,
    host: host,
    target_svc: $.svc,
    metadata+: {
      annotations+: {
        "kubernetes.io/ingress.class": "nginx-internal",
        // restic upload sends large bodies (that's the point)
        "nginx.ingress.kubernetes.io/proxy-body-size": "0",
      },
    },
    spec+: {
      tls+: [{
        hosts: [this.host],
        secretName: $.cert.spec.secretName,
      }],
    },
  },

  svc: kube.Service("rest-server") + $.namespace {
    target_pod: $.deploy.spec.template,
    spec+: {
      ports: [{
        port: 80,
        name: "http",
        targetPort: "http",
      }],
    },
  },

  data: kube.PersistentVolumeClaim("data") + $.namespace {
    storageClass: "csi-cephfs",
    storage: "200Gi",
    spec+: {
      accessModes: ["ReadWriteMany"],
    },
  },

  hpa: kube.HorizontalPodAutoscaler("rest-server") + $.namespace {
    target: $.deploy,
    spec+: {
      maxReplicas: 5,
    },
  },

  deploy: kube.Deployment("rest-server") + $.namespace {
    spec+: {
      template+: utils.PromScrape(8000) {
        spec+: {
          volumes_+: {
            data: kube.PersistentVolumeClaimVolume($.data),
          },
          containers_+: {
            default: kube.Container("rest-server") {
              image: "restic/rest-server:0.11.0", // renovate
              ports_+: {
                http: {containerPort: 8000},
              },
              env_+: {
                OPTIONS: std.join(" ", ["--%s=%s" % kv for kv in kube.objectItems(self.options_)]),
                options_:: {
                  prometheus: true,
                  "max-size": kube.siToNum($.data.storage),
                  // TODO: enable nginx->backend TLS using self-signed certs
                  // https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/#backend-certificate-authentication
                  //tls: true,
                  //"tls-cert": "/cert/tls.crt",
                  //"tls-key": "/cert/tls.key",
                },
              },
              volumeMounts_+: {
                data: {mountPath: "/data"},
              },
              resources: {
                requests: {cpu: "10m", memory: "25Mi"},
              },
              livenessProbe: {
                tcpSocket: {port: "http"}, // FIXME
                //httpGet: {path: "/config", port: "http"},
                failureThreshold: 3,
                timeoutSeconds: 10,
              },
              readinessProbe: self.livenessProbe,
            },
          },
        },
      },
    },
  },
}
