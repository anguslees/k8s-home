local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";

{
  namespace:: {metadata+: {namespace: "webcache"}},
  ns: kube.Namespace($.namespace.metadata.namespace),

  svc: kube.Service("proxy") + $.namespace {
    target_pod: $.deploy.spec.template,
    port: 80,
    spec+: {
      type: "LoadBalancer",
      ports: [
        { name: "proxy", port: 80, targetPort: "proxy" },    // moving to this
        { name: "squid", port: 3128, targetPort: "proxy" },  // deprecated
      ],
    },
  },

  config: utils.HashedConfigMap("squid") + $.namespace {
    data: {
      "squid.conf": |||
        acl localnet src 192.168.0.0/16
        acl localnet src 10.0.0.0/8
        acl localnet src fc00::/7
        acl localnet src fe80::/10
        acl localnet src 2001:44b8:3185:9c00::/56  # my IPv6 subnet
        http_access allow localhost manager
        http_access deny manager
        http_access deny to_localhost
        http_access allow localnet
        http_access allow localhost
        http_access deny all
        http_port 3128
        maximum_object_size 300 MB
        refresh_pattern ^ftp:              1440 20% 10080
        refresh_pattern ^gopher:           1440  0% 1440
        refresh_pattern -i (/cgi-bin/|\?)  0     0% 1440
        refresh_pattern .                  0    20% 4320
        refresh_pattern \.u?deb$           0   100% 129600
        refresh_pattern \/(Packages|Sources)(\.(bz2|gz|xz))?$ 0 0% 0 refresh-ims
        refresh_pattern \/Release(\.gpg)?$ 0     0% 0 refresh-ims
        refresh_pattern \/InRelease$       0     0% 0 refresh-ims
        refresh_pattern \/(Translation-.*)(\.(bz2|gz|xz))?$ 0 0% 0 refresh-ims
      |||,
    },
  },

  deploy: kube.Deployment("squid") + $.namespace {
    spec+: {
      template+: {
        metadata+: {
          annotations+: {
            "prometheus.io/scrape": "true",
            "prometheus.io/port": "9301",
            "prometheus.io/path": "/metrics",
          },
        },
        spec+: {
          automountServiceAccountToken: false,
          volumes_+: {
            data: kube.EmptyDirVolume(),  // NB: non-persistent cache
            conf: kube.ConfigMapVolume($.config),
          },
          default_container: "squid",
          containers_+: {
            squid: kube.Container("squid") {
              image: "sameersbn/squid:3.5.27",
              ports_+: {
                proxy: {containerPort: 3128},
              },
              volumeMounts_+: {
                conf: {mountPath: "/etc/squid", readOnly: true},
                data: {mountPath: "/var/spool/squid"},
              },
              readinessProbe: {
                tcpSocket: {port: "proxy"},
              },
              livenessProbe: self.readinessProbe,
              resources+: {
                limits: {cpu: "1", memory: "1Gi"},
                requests: {cpu: "10m", memory: "280Mi"},
              },
            },
            metrics: kube.Container("squid-exporter") {
              image: "boynux/squid-exporter:v1.4",
              args_+: {
                listen: ":9301",
              },
              ports_+: {
                metrics: {containerPort: 9301},
              },
              readinessProbe: {
                httpGet: {path: "/", port: "metrics"},
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
