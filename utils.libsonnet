local kube = import "kube.libsonnet";

{
  // NB: deprecated in 1.14 and removed in 1.18
  // TODO: Replace with kubernetes.io/arch
  archSelector(arch):: {"beta.kubernetes.io/arch": arch},

  toleratesMaster:: [{
    key: "node-role.kubernetes.io/master",
    operator: "Exists",
    effect: "NoSchedule",
  }],

  CriticalPodSpec:: {
    // https://kubernetes.io/docs/tasks/administer-cluster/guaranteed-scheduling-critical-addon-pods/
    // NB: replaced with "priorities" in k8s >=1.10
    metadata+: {
      annotations+: {
        "scheduler.alpha.kubernetes.io/critical-pod": "",
      },
    },
    spec+: {
      priorityClassName: "system-cluster-critical",
      tolerations+: [{
        key: "CriticalAddonsOnly",
        operator: "Exists",
      }],
    },
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
    host: "webhooks.oldmacdonald.farm",

    target_svc:: error "target_svc required",

    url:: "http://%s%s" % [this.host, path],

    metadata+: {
      annotations+: {
        "kubernetes.io/ingress.class": "nginx",
      },
    },
    spec+: {
      rules: [
        {
          host: this.host,
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
        "kubernetes.io/ingress.class": "nginx",
        "certmanager.k8s.io/cluster-issuer": "letsencrypt-prod",
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

  Certificate(name):: kube._Object("certmanager.k8s.io/v1alpha1", "Certificate", name) {
    local this = self,
    host:: error "host is required",

    spec: {
      secretName: this.metadata.name,
      issuerRef: {
        name: "letsencrypt-prod",
        kind: "ClusterIssuer",
      },
      commonName: this.host,
      dnsNames: [this.host],
      acme: {
        config: [{
          http01: {},
          domains: this.spec.dnsNames,
        }],
      },
    },
  },
}
