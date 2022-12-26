local kube = import "kube.libsonnet";

{
  archSelector(arch):: {"kubernetes.io/arch": arch},

  toleratesMaster:: [
    {
      key: "node-role.kubernetes.io/master",
      operator: "Exists",
      effect: "NoSchedule",
    },
    {
      key: "node-role.kubernetes.io/control-plane",
      operator: "Exists",
      effect: "NoSchedule",
    },
  ],

  CriticalPodSpec:: {
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
    immutable: true,
  },

  HashedConfigMap(name):: kube.ConfigMap(name) {
    local this = self,
    metadata+: {
      local hash = std.substr(std.md5(std.toString(this.data)), 0, 7),
      name: super.name + "-" + hash,
    },
    immutable: true,
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

  toKindName(list): std.foldl(
    function(accum, item) accum + {[std.asciiLower(item.kind)]+: {[item.metadata.name]: item}},
    list, {}),

  Webhook(name, path): $.Ingress(name) + $.IngressTls {
    local this = self,
    host: "webhooks.oldmacdonald.farm",

    target_svc:: error "target_svc required",

    url:: "http://%s%s" % [this.host, path],

    metadata+: {
      annotations+: {
        "external-dns.alpha.kubernetes.io/target": "webhooks.oldmacdonald.farm",
      },
    },
    spec+: {
      ingressClassName: "nginx",
      rules: [
        {
          host: this.host,
          http: {
            paths: [
              {
                path: path,
                backend: this.target_svc.name_port,
                pathType: "Prefix",
              },
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
        "cert-manager.io/cluster-issuer": "letsencrypt-prod",
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

    spec+: {
      ingressClassName: "nginx-internal",
      tls: [],
      // Default to single-service - override if you want something else.
      rules: [
        {
          host: this.host,
          http: {
            paths: [
              {path: "/", backend: this.target_svc.name_port, pathType: "Prefix"},
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

  Certificate(name):: kube._Object("cert-manager.io/v1", "Certificate", name) {
    local this = self,
    host:: error "host is required",

    spec: {
      revisionHistoryLimit: 1,
      secretName: this.metadata.name,
      issuerRef: {
        name: "letsencrypt-prod",
        kind: "ClusterIssuer",
      },
      commonName: this.host,
      dnsNames: [this.host],
      acme: {
        config: [{
          dns01: {},
          domains: this.spec.dnsNames,
        }],
      },
    },
  },

  // TODO: use std.member in jsonnet >=0.15.0
  local member(arr, x) = (
    std.foldl(function (acc, item) (acc || item == x), arr, false)
  ),

  manifestToml(obj, tableprefix=""):: std.join("\n", [
    "%s = %s" % [
      kv[0],
      if std.isString(kv[1])
      then std.escapeStringJson(kv[1])
      else std.toString(kv[1]),
    ]
    for kv in kube.objectItems(obj)
    if !std.isObject(kv[1])
  ] + [
    local table = tableprefix + (if member(std.stringChars(kv[0]), ".") then '"%s"' % kv[0] else kv[0]);
    ("[%s]\n" % table) + $.manifestToml(kv[1], table + ".")
    for kv in kube.objectItems(obj)
    if std.isObject(kv[1])
  ] + [
    // empty -> force trailing newline
  ]),

  crdNew(crd, version):: (
    local versions = if crd.apiVersion == "apiextensions.k8s.io/v1beta1" then
    [crd.spec.version] else [v.name for v in crd.spec.versions];
    assert std.member(versions, version) : "%s not one of CRD %s versions %s" % [version, crd.spec.group, versions];
    local gv = crd.spec.group + "/" + version;
    function (name) kube._Object(gv, crd.spec.names.kind, name)
  ),
}
