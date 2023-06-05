local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";

{
  namespace:: { metadata+: { namespace: "external-dns" }},
  ns: kube.Namespace($.namespace.metadata.namespace),

  dnsEndpointCRD: kube.CustomResourceDefinition("externaldns.k8s.io", "v1beta1", "DNSEndpoint") {
    metadata+: {
      labels+: {
        api: "externaldns",
        "kubebuilder.k8s.io": "1.0.0",
      },
    },
    spec+: {
      versions_+: {
        v1beta1+: {
          subresources+: {status+: {}},
          schema: {
            openAPIV3Schema: {
              properties+: {
                apiVersion: {
                  type: "string",
                },
                kind: {
                  type: "string",
                },
                metadata: {
                  type: "object",
                },
                spec+: {
                  properties+: {
                    endpoints+: {
                      items+: {
                        properties: {
                          dnsName: {
                            type: "string",
                          },
                          labels: {
                            type: "object",
                          },
                          providerSpecific: {
                            items: {
                              properties: {
                                name: {
                                  type: "string",
                                },
                                value: {
                                  type: "string",
                                },
                              },
                              type: "object",
                            },
                            type: "array",
                          },
                          recordTTL: {
                            format: "int64",
                            type: "integer",
                          },
                          recordType: {
                            type: "string",
                          },
                          targets: {
                            items: {
                              type: "string",
                            },
                            type: "array",
                          },
                        },
                        type: "object",
                      },
                      type: "array",
                    },
                  },
                  type: "object",
                },
                status+: {
                  properties+: {
                    observedGeneration: {
                      format: "int64",
                      type: "integer",
                    },
                  },
                  type: "object",
                },
              },
            },
          },
        },
      },
    },
  },

  secret: utils.SealedSecret("external-dns") + $.namespace {
    // If data_ is changed, reseal with ./seal.sh extdns-secret.jsonnet
    data_:: {
      // digitalocean API token
      token: error "secret! token value not overridden",
    },
    spec+: {
      data: "AgCqkMx2aUkig2+9n16OOjPI6WVRAFI0WmGWxT/bOPoeRYAutET73OztIiEM7BbBQx5oxIh9M9ng8hLiGTthHUruUte91SWGVy41Bh//qxwN1Q+SiY8PJyM9yLOeay16nlj/3mvdUdQEAGXxyjE3G9zo/4/p2zI49ggSyoB1kjS8eGSguu79g1wKYb+5JVhLd1jGtSWNNEegQUptDy9N9OjLFMNGD0qGMMPUrwgXa4SNiFVYmc/LVNBYZ98As9iz2YvEoDNodbevZZbq9L6Uj9nZrC3Pz7flNsorVZ6oZOb/tYgydIxXQi79aorJfTQ+y8t7kmwTqAr9NOtPIJBCWjq+3txvetP7oplx7XevOR/uJ0LwFLeCtDBqIbxdN3grGmhzCOw9M1V1vFMm57ZIpvTVChwMsuxTHVY7t9TaJr/yBwjk41f1/zs3jDqXr9J1j5zlc4/r4uyBGEJgfyO9rMGKXhZON0YaS2dfKwimiPtjSYj1VEhVzrWpLUmhY2wry33teClThlW2pv4cH23vbZ5v08CalUueZ82VxNFlHkIYOjSVN71eeDwax7wp+4jvY54YJmAFk9mb8JMszvG/cPOAHn4UeKRuk/H4Zcjk4ap6raINxCPIVgm4lyzBKeislbU+fjFpBQqBompSqhyPlahLoZT7z95YzTY/xyliXRvJ9bQkOnpg3+YV6wui3u702IoByPqLV3cjCiQbQs6i0ou8VrJ4idIDKHnWJg7izvBZJ2cIVxySvjIDvxJAF2Y41JfZmRhyvw2AFf+mnuMz9ui1wfzVutsMD03p0GgrKEr6nRE1SPv/EZ9TsrI8V/vnzI1ZbasQtSkECn4H5yjLYecWr8etIVBaDldrM3NSBbpNUqZGvMzilEwhYud9JabdBzo0F2THQjkIf2W93zslmudDlUvaId7JT755mXot0cx9I2s488CB2p1B6EW2G/GV+fAoA3v7qsp/gx1g+OMiN7JzRFw1IfprGqPb2D7j9/2rMlbRS6RHOoNtzIzpdQta4SxOHj4vI4uP3mZxYQ0m5WQO97FtVT5ex+C6VrX2+vPsMLNjpJD1F4Ji",
    },
  },

  sa: kube.ServiceAccount("external-dns") + $.namespace,

  role: kube.ClusterRole("external-dns-controller") {
    rules: [
      {
        apiGroups: [""],
        resources: ["services", "pods", "nodes", "endpoints"],
        verbs: ["get", "watch", "list"],
      },
      {
        apiGroups: ["extensions", "networking.k8s.io"],
        resources: ["ingresses", "gateways"],
        verbs: ["get", "watch", "list"],
      },
      {
        apiGroups: ["externaldns.k8s.io"],
        resources: ["dnsendpoints"],
        verbs: ["get", "watch", "list"],
      },
      {
        apiGroups: ["externaldns.k8s.io"],
        resources: ["dnsendpoints/status"],
        verbs: ["update"],
      },
    ],
  },

  binding: kube.ClusterRoleBinding("external-dns-controller") {
    roleRef_: $.role,
    subjects_+: [$.sa],
  },

  dyndns: kube.Deployment("dyndns") + $.namespace {
    spec+: {
      template+: {
        spec+: {
          automountServiceAccountToken: false,
          nodeSelector+: utils.archSelector("amd64"),
          securityContext+: {
            runAsNonRoot: true,
            runAsUser: 65534, // nobody
          },
          containers_+: {
            default: kube.Container("dyndns") {
              image: "tunix/digitalocean-dyndns", // renovate
              env_+: {
                DIGITALOCEAN_TOKEN: kube.SecretKeyRef($.secret, "token"),
                DOMAIN: "oldmacdonald.farm",
                NAME: "webhooks",
                SLEEP_INTERVAL: "600", // seconds
              },
            },
          },
        },
      },
    },
  },

  extdns: kube.Deployment("external-dns") + $.namespace {
    spec+: {
      template+: utils.PromScrape(7979) + {
        spec+: {
          serviceAccountName: $.sa.metadata.name,
          nodeSelector+: utils.archSelector("amd64"),
          securityContext+: {
            runAsNonRoot: true,
            runAsUser: 65534, // nobody
          },
          containers_+: {
            default: kube.Container("extdns") {
              image: "registry.k8s.io/external-dns/external-dns:v0.13.5", // renovate
              args_+: {
                sources_:: ["ingress", "service"],
                "domain-filter": "oldmacdonald.farm",
                provider: "digitalocean",
                registry: "txt",
                "txt-owner-id": "ext-dns",
                "txt-prefix": "_xdns.",
                "log-level": "info",
              },
              args+: ["--source=" + s for s in self.args_.sources_],
              env_+: {
                DO_TOKEN: kube.SecretKeyRef($.secret, "token"),
              },
              ports_+: {
                metrics: {containerPort: 7979},
              },
              readinessProbe: {
                httpGet: {path: "/healthz", port: "metrics"},
              },
              livenessProbe: self.readinessProbe {
                timeoutSeconds: 10,
                failureThreshold: 3,
              },
            },
          },
        },
      },
    },
  },
}
