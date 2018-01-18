local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";
local vips = import "keepalived.jsonnet";

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
              image: "gcr.io/google_containers/defaultbackend:1.4",
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
        apiGroups: ["extensions"],
        resources: ["ingresses"],
        verbs: ["get", "list", "watch"],
      },
      {
        apiGroups: ["extensions"],
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
      //externalIPs+: [vips.vip(this)],
      externalIPs: [],
      loadBalancerIP: vips.vip(this),
    },
  },

  controller: kube.Deployment("nginx-ingress-controller") + $.namespace {
    spec+: {
      template+: utils.PromScrape(10254) {
        spec+: {
          nodeSelector+: utils.archSelector("amd64"),
          serviceAccountName: $.serviceAccount.metadata.name,
          //hostNetwork: true, // access real source IPs, IPv6, etc
          terminationGracePeriodSeconds: 60,
          containers_+: {
            default: kube.Container("nginx") {
              image: "quay.io/kubernetes-ingress-controller/nginx-ingress-controller:0.9.0",
              env_+: {
                POD_NAME: kube.FieldRef("metadata.name"),
                POD_NAMESPACE: kube.FieldRef("metadata.namespace"),
              },
              command: ["/nginx-ingress-controller"],
              args_+: {
                "default-backend-service": "$(POD_NAMESPACE)/" + $.defaultSvc.metadata.name,
                configmap: "$(POD_NAMESPACE)/" + $.config.metadata.name,
                // publish-service requires svc to have .Status.LoadBalancer.Ingress
                //"publish-service": "$(POD_NAMESPACE)/" + $.service.metadata.name,

                "tcp-services-configmap": "$(POD_NAMESPACE)/" + $.tcpconf.metadata.name,
                "udp-services-configmap": "$(POD_NAMESPACE)/" + $.udpconf.metadata.name,

                "sort-backends": true,
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
            },
          },
        },
      },
    },
  },

  serviceIntern: $.service {
    metadata+: {name: super.name + "-internal"},
    target_pod: $.controllerIntern.spec.template,
  },

  controllerIntern: $.controller {
    metadata+: {name: super.name + "-internal"},
    spec+: {
      template+: {
        spec+: {
          containers_+: {
            default+: {
              args_+: {
                "ingress-class": "nginx-internal",

                // publish-service requires svc to have .Status.LoadBalancer.Ingress
                //"publish-service": "$(POD_NAMESPACE)/" + $.serviceIntern.metadata.name,

                "tcp-services-configmap": "$(POD_NAMESPACE)/" + $.tcpconfIntern.metadata.name,
                "udp-services-configmap": "$(POD_NAMESPACE)/" + $.udpconfIntern.metadata.name,
              },
            },
          },
        },
      },
    },
  },
}
