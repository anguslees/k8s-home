local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";
local certman = import "cert-manager.jsonnet";
local metallb = (import "all.jsonnet").metallb;

local ValidatingWebhookConfiguration(name) = kube._Object("admissionregistration.k8s.io/v1", "ValidatingWebhookConfiguration", name) {
  webhooks_:: {},
  webhooks: kube.mapToNamedList(self.webhooks_),
};

local apiGroup(gv) = (
  local split = std.splitLimit(gv, "/", 1);
  if std.length(split) == 1 then "" else split[0]
);

local issuerRef(issuer) = {
  group: apiGroup(issuer.apiVersion),
  kind: issuer.kind,
  name: issuer.metadata.name,
};

{
  namespace:: { metadata+: { namespace: "kube-system" }},

  config: kube.ConfigMap("nginx-ingress") + $.namespace {
    data+: {
      "proxy-connect-timeout": "15",
      "disable-ipv6": "false",

      //"hsts": "true",
      //"hsts-include-subdomains": "false",

      "enable-vts-status": "true",

      // extend for websockets
      //"proxy-read-timeout": "3600",
      //"proxy-send-timeout": "3600",
      // -> use ingress.kubernetes.io/proxy-{read,send}-timeout annotation
    },
  },

  tcpconf: kube.ConfigMap("tcp-services") + $.namespace {
    // empty
  },

  udpconf: kube.ConfigMap("udp-services") + $.namespace {
    // empty
  },

  tcpconfIntern: kube.ConfigMap("tcp-services-internal") + $.namespace {
    // empty
  },

  udpconfIntern: kube.ConfigMap("udp-services-internal") + $.namespace {
    // empty
  },

  defaultSvc: kube.Service("default-http-backend") + $.namespace {
    target_pod: $.defaultBackend.spec.template,
    port: 80,
  },

  defaultBackend: kube.Deployment("default-http-backend") + $.namespace {
    spec+: {
      template+: {
        spec+: {
          nodeSelector+: utils.archSelector("amd64"),
          terminationGracePeriodSeconds: 60,
          containers_+: {
            default: kube.Container("default-http-backend") {
              image: "registry.k8s.io/defaultbackend:1.4", // renovate
              livenessProbe: {
                httpGet: { path: "/healthz", port: 8080, scheme: "HTTP" },
                initialDelaySeconds: 30,
                timeoutSeconds: 5,
              },
              ports_+: {
                default: { containerPort: 8080 },
              },
              resources: {
                limits: { cpu: "10m", memory: "20Mi" },
                requests: self.limits,
              },
            },
          },
        },
      },
    },
  },

  ingressControllerClusterRole: kube.ClusterRole("nginx-ingress-controller") {
    rules: [
      {
        apiGroups: [""],
        resources: ["configmaps", "endpoints", "nodes", "pods", "secrets"],
        verbs: ["list", "watch"],
      },
      {
        apiGroups: [""],
        resources: ["nodes"],
        verbs: ["get"],
      },
      {
        apiGroups: [""],
        resources: ["services"],
        verbs: ["get", "list", "watch"],
      },
      {
        apiGroups: ["extensions", "networking.k8s.io"],
        resources: ["ingresses"],
        verbs: ["get", "list", "watch"],
      },
      {
        apiGroups: ["extensions", "networking.k8s.io"],
        resources: ["ingresses/status"],
        verbs: ["update"],
      },
      {
        apiGroups: ["networking.k8s.io"],
        resources: ["ingressclasses"],
        verbs: ["get", "list", "watch"],
      },
      {
        apiGroups: [""],
        resources: ["events"],
        verbs: ["create", "patch"],
      },
    ],
  },

  ingressControllerRole: kube.Role("nginx-ingress-controller") + $.namespace {
    local leaderElectRule(deploy) = {
      local container = deploy.spec.template.spec.containers_.default,
      local election_id = container.args_["election-id"],
      apiGroups: [""],
      resources: ["configmaps"],
      resourceNames: [election_id],
      verbs: ["get", "update"],
    },

    rules: [
      {
        apiGroups: [""],
        resources: ["namespaces"],
        verbs: ["get"],
      },
      {
        apiGroups: [""],
        resources: ["configmaps", "pods", "secrets", "endpoints", "services"],
        verbs: ["get", "list", "watch"],
      },
      leaderElectRule($.controller),
      leaderElectRule($.controllerIntern),
      {
        apiGroups: [""],
        resources: ["configmaps"],
        verbs: ["create"],
      },
    ],
  },

  ingressControllerClusterRoleBinding: kube.ClusterRoleBinding("nginx-ingress-controller") {
    roleRef_: $.ingressControllerClusterRole,
    subjects_: [$.serviceAccount],
  },

  ingressControllerRoleBinding: kube.RoleBinding("nginx-ingress-controller") + $.namespace {
    roleRef_: $.ingressControllerRole,
    subjects_: [$.serviceAccount],
  },

  serviceAccount: kube.ServiceAccount("nginx-ingress-controller") + $.namespace,

  service: kube.Service("nginx-ingress") + $.namespace {
    local this = self,
    target_pod: $.controller.spec.template,
    spec+: {
      ports: [
        {name: "http", port: 80, protocol: "TCP"},
        {name: "https", port: 443, protocol: "TCP"},
      ],
      loadBalancerIP: "192.168.0.50",
      type: "LoadBalancer",
    },
  },

  class: kube.IngressClass("nginx") {
    metadata+: {
      annotations+: {
        "ingressclass.kubernetes.io/is-default-class": "true",
      },
    },
    spec+: {
      controller: "k8s.io/ingress-nginx",
    },
  },

  controller: kube.Deployment("nginx-ingress-controller") + $.namespace {
    local this = self,
    spec+: {
      replicas: 2,
      template+: utils.PromScrape(10254) {
        spec+: {
          serviceAccountName: $.serviceAccount.metadata.name,
          priorityClassName: "high",
          terminationGracePeriodSeconds: 300,
          affinity+: {
            podAffinity+: {
              preferredDuringSchedulingIgnoredDuringExecution+: [{
                weight: 10,
                podAffinityTerm: {
                  namespaces: [metallb.speaker.deploy.metadata.namespace],
                  labelSelector: metallb.speaker.deploy.spec.selector,
                  topologyKey: "kubernetes.io/hostname",
                },
              }],
            },
            podAntiAffinity+: {
              preferredDuringSchedulingIgnoredDuringExecution+: [
                {
                  weight: 100,
                  podAffinityTerm: {
                    labelSelector: this.spec.selector,
                    topologyKey: "kubernetes.io/hostname",
                  },
                },
                {
                  weight: 100,
                  podAffinityTerm: {
                    labelSelector: this.spec.selector,
                    topologyKey: "topology.kubernetes.io/zone",
                  },
                },
              ],
            },
          },
          volumes_+: {
            webhookcert: kube.SecretVolume($.webhook.cert.secret_),
          },
          containers_+: {
            default: kube.Container("nginx") {
              image: "registry.k8s.io/ingress-nginx/controller:v1.1.3", // renovate
              env_+: {
                POD_NAME: kube.FieldRef("metadata.name"),
                POD_NAMESPACE: kube.FieldRef("metadata.namespace"),
                LD_PRELOAD: "/usr/local/lib/libmimalloc.so",
              },
              command: ["/nginx-ingress-controller"],
              args_+: {
                "election-id": this.metadata.name + "-leader",

                "shutdown-grace-period": this.spec.template.spec.terminationGracePeriodSeconds - 2,

                local fqname(o) = "%s/%s" % [o.metadata.namespace, o.metadata.name],
                "default-backend-service": fqname($.defaultSvc),
                "ingress-class": "nginx",
                "controller-class": $.class.spec.controller,
                configmap: fqname($.config),
                "validating-webhook": ":8443",
                "validating-webhook-certificate": "/webookcert/tls.crt",
                "validating-webhook-key": "/webhookcert/tls.key",
                // publish-service requires svc to have .Status.LoadBalancer.Ingress
                "publish-service": fqname($.service),

                "tcp-services-configmap": fqname($.tcpconf),
                "udp-services-configmap": fqname($.udpconf),

                "annotations-prefix": "nginx.ingress.kubernetes.io",
              },
              lifecycle: {
                preStop: {exec: {command: ["/wait-shutdown"]}},
              },
              securityContext: {
                capabilities: {drop: ["ALL"], add: ["NET_BIND_SERVICE"]},
                runAsUser: 101,
                allowPrivilegeEscalation: true,
              },
              ports_: {
                http: { containerPort: 80 },
                https: { containerPort: 443 },
                webhook: { containerPort: 8443 },
              },
              volumeMounts_: {
                webhookcert: {mountPath: "/webhookcert", readOnly: true},
              },
              livenessProbe: {
                httpGet: { path: "/healthz", port: 10254, scheme: "HTTP" },
                failureThreshold: 5,
                periodSeconds: 10,
                successThreshold: 1,
                timeoutSeconds: 1,
              },
              startupProbe: self.livenessProbe {
                failureThreshold: std.ceil(120 / self.periodSeconds),
              },
              readinessProbe: self.livenessProbe {
                failureThreshold: 3,
              },
              resources: {
                requests: {cpu: "10m", memory: "90Mi"},
                limits: { cpu: "1", memory: "500Mi" },
              },
            },
          },
        },
      },
    },
  },

  serviceIntern: $.service {
    metadata+: {name: super.name + "-internal"},
    target_pod: $.controllerIntern.spec.template,
    spec+: {
      loadBalancerIP: "192.168.0.53",
      loadBalancerSourceRanges: ["192.168.0.0/24"],
    },
  },

  classIntern: kube.IngressClass("nginx-internal") {
    spec+: {
      controller: "k8s.io/ingress-nginx-internal",
    },
  },

  controllerIntern: $.controller {
    metadata+: {name: super.name + "-internal"},
    spec+: {
      template+: {
        spec+: {
          containers_+: {
            default+: {
              args_+: {
                local fqname(o) = "%s/%s" % [o.metadata.namespace, o.metadata.name],

                "ingress-class": "nginx-internal",
                "controller-class": $.classIntern.spec.controller,

                "tcp-services-configmap": fqname($.tcpconfIntern),
                "udp-services-configmap": fqname($.udpconfIntern),

                // publish-service requires svc to have .Status.LoadBalancer.Ingress
                "publish-service": fqname($.serviceIntern),
              },
            },
          },
        },
      },
    },
  },

  webhook: {
    service: kube.Service("ingress-nginx-admission") + $.namespace {
      local this = self,
      target_pod: $.controller.spec.template,
      spec+: {
        ports: [
          {name: "webhook", port: 443, targetPort: "webhook", protocol: "TCP"},
        ],
      },
    },

    selfSigner: certman.Issuer("ingress-nginx-selfsign") + $.namespace {
      spec+: {selfSigned: {}},
    },

    cert: certman.Certificate("ingress-nginx-admission") + $.namespace {
      local this = self,
      spec+: {
        issuerRef: issuerRef($.webhook.selfSigner),
        isCA: false,
        usages: ["digital signature", "key encipherment"],
        commonName: this.metadata.name,
        secretName: this.metadata.name,
        duration_h_:: 365 * 24 / 4, // 3 months
        duration: "%dh" % self.duration_h_,
        renewBefore_h_:: self.duration_h_ / 3,
        renewBefore: "%dh" % self.renewBefore_h_,
        privateKey: {algorithm: "ECDSA"},
        revisionHistoryLimit: 1,
      },

      // Fake Secret, used to represent the _real_ cert Secret to jsonnet
      secret_:: kube.Secret(this.spec.secretName) {
        metadata+: {namespace: this.metadata.namespace},
        type: "kubernetes.io/tls",
        data: {[k]: error "attempt to access TLS value directly"
          for k in ["tls.crt", "tls.key", "ca.crt"]},
      },
    },

    validatinghook: ValidatingWebhookConfiguration("ingress-nginx-admission") {
      metadata+: {
        annotations+: {
          local cert = $.webhook.cert,
          "cert-manager.io/inject-ca-from": "%s/%s" % [
            cert.metadata.namespace, cert.metadata.name]
        },
      },

      webhooks_+: {
        "validate.nginx.ingress.kubernetes.io": {
          matchPolicy: "Equivalent",
          rules: [{
            apiGroups: ["networking.k8s.io"],
            apiVersions: ["v1"],
            operations: ["CREATE", "UPDATE"],
            resources: ["ingresses"],
          }],
          failurePolicy: "Ignore",
          sideEffects: "None",
          admissionReviewVersions: ["v1"],
          clientConfig: {
            local s = $.webhook.service,
            service: {
              namespace: s.metadata.namespace,
              name: s.metadata.name,
              path: "/networking/v1/ingresses",
            },
          },
        },
      },
    },
  },
}
