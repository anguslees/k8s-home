local kube = import "kube.libsonnet";

{
  archSelector(arch):: {"beta.kubernetes.io/arch": arch},

  toleratesMaster:: {
    tolerations+: [{
      key: "node-role.kubernetes.io/master",
      operator: "Exists",
      effect: "NoSchedule",
    }],
  },

  HashedSecret(name):: kube.Secret(name) {
    local this = self,
    metadata+: {
      local hash = std.substr(std.md5(std.toString(this.data)), 0, 7),
      name: super.name + "-" + hash,
    },
  },

  HashedConfigMap(name):: kube.ConfigMap(name) {
    local this = self,
    metadata+: {
      local hash = std.substr(std.md5(std.toString(this.data)), 0, 7),
      name: super.name + "-" + hash,
    },
  },

  shcmd(name):: kube.Container(name) {
    shcmd:: error "shcmd required",
    image: "busybox",
    command: ["/bin/sh", "-e", "-x", "-c", self.shcmd],
  },

  stripLeading(c, str):: if std.startsWith(str, c) then
  $.stripLeading(c, std.substr(str, 1, std.length(str)-1)) else str,

  isalpha(c):: std.codepoint(c) >= std.codepoint("a") &&
    std.codepoint(c) <= std.codepoint("z"),

  Webhook(name, path): $.Ingress(name) + $.IngressTls {
    local this = self,
    local host = "webhooks.oldmacdonald.farm",

    target_svc:: error "target_svc required",

    url:: "http://%s%s" % [host, path],

    metadata+: {
      annotations+: {
        "kubernetes.io/ingress.class": "nginx",
      },
    },
    spec+: {
      rules: [
        {
          host: host,
          http: {
            paths: [
              {path: path, backend: this.target_svc.name_port},
            ],
          },
        },
      ],
    },
  },

  IngressTls:: {
    local this = self,
    metadata+: {
      annotations+: {
        "kubernetes.io/tls-acme": "true",
      },
    },
    spec+: {
      tls+: [{
        hosts: std.set([r.host for r in this.spec.rules]),
        secretName: this.metadata.name + "-tls",
      }],
    },
  },

  Ingress(name): kube.Ingress(name) {
    local this = self,

    host:: error "host required",
    target_svc:: error "target_svc required",

    local scheme = if std.length(this.spec.tls) > 0 then "https" else "http",
    url:: "%s://%s/" % [scheme, self.host],

    metadata+: {
      annotations+: {
        "kubernetes.io/ingress.class": "nginx-internal",
      },
    },

    spec+: {
      tls: [],
      // Default to single-service - override if you want something else.
      rules: [
        {
          host: this.host,
          http: {
            paths: [
              {path: "/", backend: this.target_svc.name_port},
            ],
          },
        },
      ],
    },
  },

  PromScrape(port): {
    local this = self,
    prom_path:: "/metrics",

    metadata+: {
      annotations+: {
        "prometheus.io/scrape": "true",
        "prometheus.io/port": std.toString(port),
        "prometheus.io/path": this.prom_path,
      },
    },
  },

  ArchDaemonSets(template, archs):: {
    [arch]: template {
      arch:: arch,
      metadata+: {name: "%s-%s" % [super.name, arch]},
      spec+: {
        template+: {
          spec+: {
            nodeSelector+: $.archSelector(arch),
          },
        },
      },
    } for arch in archs
  },

  SealedSecret(name):: kube._Object("bitnami.com/v1alpha1", "SealedSecret", name) {
    local this = self,

    // Terrible workaround for
    // https://github.com/kubernetes/kubernetes/issues/53379
    metadata+: {annotations+: {"dummychange": std.extVar("RANDOM")}},

    // These are placed here to make this look (to jsonnet) like a
    // regular Secret.  If anything peeks at some actual secret info,
    // it will hit a jsonnet error
    data:: {[k]: error "attempt to use secret value"
            for k in std.objectFields(this.data_)},
    data_:: {},
    type:: "Opaque",

    // Helper for sealing.  Use in a separate file, so real secret
    // info (`overrides`) isn't accidentally exposed.
    Secret_(overrides):: kube.Secret(this.metadata.name) {
      metadata+: this.metadata,
      data_+: this.data_ + overrides,
      type: this.type,
    },

    spec+: {data: error "(sealed) data required"},
  },
}
