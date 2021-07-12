local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";
local metallb = (import "all.jsonnet").metallb;

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
              image: "k8s.gcr.io/defaultbackend:1.4", // renovate
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
        apiGroups: [""],
        resources: ["events"],
        verbs: ["create", "patch"],
      },
    ],
  },

  ingressControllerRole: kube.Role("nginx-ingress-controller") + $.namespace {
    rules: [
      {
        apiGroups: [""],
        resources: ["configmaps", "pods", "secrets", "namespaces"],
        verbs: ["get"],
      },
      {
        apiGroups: [""],
        resources: ["configmaps"],
        local election_id = "ingress-controller-leader",
        local ingress_class = "nginx",
        resourceNames: ["%s-%s" % [election_id, ingress_class]],
        verbs: ["get", "update"],
      },
      {
        apiGroups: [""],
        resources: ["configmaps"],
        local election_id = "ingress-controller-leader",
        local ingress_class = "nginx-internal",
        resourceNames: ["%s-%s" % [election_id, ingress_class]],
        verbs: ["get", "update"],
      },
      {
        apiGroups: [""],
        resources: ["configmaps"],
        verbs: ["create"],
      },
      {
        apiGroups: [""],
        resources: ["endpoints"],
        verbs: ["get"], // ["create", "update"],
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

  controller: kube.Deployment("nginx-ingress-controller") + $.namespace {
    local this = self,
    spec+: {
      replicas: 2,
      template+: utils.PromScrape(10254) {
        spec+: {
          nodeSelector+: utils.archSelector("amd64"),
          serviceAccountName: $.serviceAccount.metadata.name,
          //hostNetwork: true, // access real source IPs, IPv6, etc
          terminationGracePeriodSeconds: 60,
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
                    topologyKey: "failure-domain.beta.kubernetes.io/zone",
                  },
                },
              ],
            },
          },
          containers_+: {
            default: kube.Container("nginx") {
              image: "quay.io/kubernetes-ingress-controller/nginx-ingress-controller:0.33.0", // renovate
              env_+: {
                POD_NAME: kube.FieldRef("metadata.name"),
                POD_NAMESPACE: kube.FieldRef("metadata.namespace"),
              },
              command: ["/nginx-ingress-controller"],
              args_+: {
                local fqname(o) = "%s/%s" % [o.metadata.namespace, o.metadata.name],
                "default-backend-service": fqname($.defaultSvc),
                configmap: fqname($.config),
                // publish-service requires svc to have .Status.LoadBalancer.Ingress
                "publish-service": fqname($.service),

                "tcp-services-configmap": fqname($.tcpconf),
                "udp-services-configmap": fqname($.udpconf),

                "annotations-prefix": "nginx.ingress.kubernetes.io",
                "sort-backends": true,
              },
              securityContext: {
                capabilities: {drop: ["ALL"], add: ["NET_BIND_SERVICE"]},
                runAsUser: 33, // www-data
              },
              ports_: {
                http: { containerPort: 80 },
                https: { containerPort: 443 },
              },
              readinessProbe: {
                httpGet: { path: "/healthz", port: 10254, scheme: "HTTP" },
                failureThreshold: 3,
                periodSeconds: 10,
                successThreshold: 1,
                timeoutSeconds: 1,
              },
              livenessProbe: self.readinessProbe {
                initialDelaySeconds: 10,
              },
              resources: {
                requests: {cpu: "10m", memory: "120Mi"},
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

                // publish-service requires svc to have .Status.LoadBalancer.Ingress
                "publish-service": fqname($.serviceIntern),

                "tcp-services-configmap": fqname($.tcpconfIntern),
                "udp-services-configmap": fqname($.udpconfIntern),
              },
            },
          },
        },
      },
    },
  },
}
