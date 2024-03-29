local kube = import "kube.libsonnet";
local kubecfg = import "kubecfg.libsonnet";
local utils = import "utils.libsonnet";

local path_join(prefix, suffix) = (
  if std.endsWith(prefix, "/") then prefix + suffix
  else prefix + "/" + suffix
);

{
  namespace:: {metadata+: {namespace: "monitoring"}},

  ns: kube.Namespace($.namespace.metadata.namespace),

  ingress: utils.Ingress("prometheus") + $.namespace {
    local this = self,
    local host = "prometheus.k.lan",
    prom_path:: "/",
    am_path:: "/alertmanager",
    prom_url:: "http://%s%s" % [host, self.prom_path],
    am_url:: "http://%s%s" % [host, self.am_path],
    spec+: {
      rules: [
        {
          host: host,
          http: {
            paths: [
              {path: this.prom_path, backend: $.prometheus.svc.name_port, pathType: "Prefix"},
              {path: this.am_path, backend: $.alertmanager.svc.name_port, pathType: "Prefix"},
            ],
          },
        },
      ],
    },
  },

  config:: (import "prometheus-config.jsonnet") {
    rule_files+: std.objectFields($.rules),
  },
  rules:: {
    // See also: https://github.com/coreos/prometheus-operator/tree/master/contrib/kube-prometheus/assets/prometheus/rules
    // "foo.yml": {...},
    basic_:: {
      groups: [
        {
          name: "basic.rules",
          rules: [
            {
              alert: "K8sApiUnavailable",
              expr: "max(up{job=\"kubernetes_apiservers\"}) != 1",
              "for": "10m",
              annotations: {
                summary: "Kubernetes API is unavailable",
                description: "Kubernetes API is not responding",
              },
            },
            {
              alert: "CrashLooping",
              expr: "sum(rate(kube_pod_container_status_restarts_total[15m])) BY (namespace, container) * 3600 > 0",
              "for": "1h",
              labels: {severity: "notice"},
              annotations: {
                summary: "Frequently restarting container",
                description: "{{$labels.namespace}}/{{$labels.container}} is restarting {{$value | printf \"%.2g\"}} times per hour",
              },
            },
            {
              alert: "RebootRequired",
              expr: "kured_reboot_required != 0",
              "for": "24h",
              labels: {severity: "warning"},
              annotations: {
                summary: "Machines require being rebooted, and reboot daemon has failed to do so for 24h",
                description: "Machine(s) require being rebooted.",
              },
            },
          ],
        },
      ],
    },
    "basic.yaml": kubecfg.manifestYaml(self.basic_),
    monitoring_:: {
      groups: [
        {
          name: "monitoring.rules",
          rules: [
            {
              alert: "PrometheusBadConfig",
              expr: "prometheus_config_last_reload_successful{kubernetes_namespace=\"%s\"} == 0" % $.namespace.metadata.namespace,
              "for": "10m",
              labels: {severity: "critical"},
              annotations: {
                summary: "Prometheus failed to reload config",
                description: "Config error with prometheus, see container logs",
              },
            },
            {
              alert: "AlertmanagerBadConfig",
              expr: "alertmanager_config_last_reload_successful{kubernetes_namespace=\"%s\"} == 0" % $.namespace.metadata.namespace,
              "for": "10m",
              labels: {severity: "critical"},
              annotations: {
                summary: "Alertmanager failed to reload config",
                description: "Config error with alertmanager, see container logs",
              },
            },
          ],
        },
      ],
    },
    "monitoring.yml": kubecfg.manifestYaml(self.monitoring_),
  },

  am_config:: (import "alertmanager-config.jsonnet"),

  prometheus: {
    local prom = self,

    serviceAccount: kube.ServiceAccount("prometheus") + $.namespace,

    prometheusRole: kube.ClusterRole("prometheus") {
      rules: [
        {
          apiGroups: [""],
          resources: ["nodes", "nodes/proxy", "services", "endpoints", "pods"],
          verbs: ["get", "list", "watch"],
        },
        {
          apiGroups: ["extensions", "networking.k8s.io"],
          resources: ["ingresses"],
          verbs: ["get", "list", "watch"],
        },
        {
          nonResourceURLs: ["/metrics"],
          verbs: ["get"],
        },
      ],
    },

    prometheusBinding: kube.ClusterRoleBinding("prometheus") {
      roleRef_: prom.prometheusRole,
      subjects_+: [prom.serviceAccount],
    },

    svc: kube.Service("prometheus") + $.namespace {
      metadata+: {
        annotations+: {"kubernetes.io/cluster-service": "true"},
      },
      target_pod: prom.deploy.spec.template,
    },

    config: kube.ConfigMap("prometheus") + $.namespace {
      data+: $.rules {
        "prometheus.yml": kubecfg.manifestYaml($.config),
      },
    },

    deploy: kube.StatefulSet("prometheus") + $.namespace {
      local this = self,
      spec+: {
        replicas: 2,
        volumeClaimTemplates_+: {
          prometheus_data: {
            // https://prometheus.io/docs/prometheus/2.0/storage/#operational-aspects
            //  On average, Prometheus uses only around 1-2 bytes per
            //  sample. Thus, to plan the capacity of a Prometheus server,
            //  you can use the rough formula:
            //  needed_disk_space = retention_time_seconds * ingested_samples_per_second * bytes_per_sample
            retention_days:: prom.deploy.spec.template.spec.containers_.prometheus.args_.retention_days,
            retention_secs:: self.retention_days * 86400,
            time_series:: 1000, // wild guess
            samples_per_sec:: self.time_series / $.config.global.scrape_interval_secs,
            bytes_per_sample:: 2,
            needed_space:: self.retention_secs * self.samples_per_sec * self.bytes_per_sample,
            overhead_factor:: 1.5,
            storage: "%dMi" % [self.overhead_factor * self.needed_space / 1e6],
            storageClass: "ceph-block",
          },
        },
        template+: {
          metadata+: {
            annotations+: {
              "prometheus.io/scrape": "true",
              "prometheus.io/port": "9090",
              "prometheus.io/path": path_join($.ingress.prom_path, "metrics"),
            },
          },
          spec+: {
            terminationGracePeriodSeconds: 300,
            serviceAccountName: prom.serviceAccount.metadata.name,
            nodeSelector+: utils.archSelector("amd64"),
            volumes_+: {
              config: kube.ConfigMapVolume(prom.config),
            },
            securityContext+: {
              runAsUser: 65534,
              runAsGroup: 65534,
              fsGroup: 65534, // nobody:nogroup
              runAsNonRoot: true,
            },
            affinity+: {
              podAntiAffinity+: {
                preferredDuringSchedulingIgnoredDuringExecution+: [{
                  weight: 100,
                  podAffinityTerm: {
                    labelSelector: this.spec.selector,
                    topologyKey: "kubernetes.io/hostname",
                  },
                }],
              },
            },
            default_container: "prometheus",
            containers_+: {
              prometheus: kube.Container("prometheus") {
                local this = self,
                image: "quay.io/prometheus/prometheus:v2.40.5", // renovate
                args_+: {
                  //"log.level": "debug",  // default is info

                  "web.external-url": $.ingress.prom_url,

                  "config.file": this.volumeMounts_.config.mountPath + "/prometheus.yml",
                  "storage.tsdb.path": this.volumeMounts_.prometheus_data.mountPath,
                  retention_days:: 15,
                  "storage.tsdb.retention": "%dd" % self.retention_days,

                  // "As a rule of thumb, you should have at least 50% headroom in physical memory over the configured heap size. (Or, in other words, set storage.local.target-heap-size to a value of two thirds of the physical memory limit Prometheus should not exceed.)"

                  // These are unmodified upstream console files. May
                  // want to ship in config instead.
                  "web.console.libraries": "/etc/prometheus/console_libraries",
                  "web.console.templates": "/etc/prometheus/consoles",
                },
                args+: [
                  // Enable /-/reload hook.  TODO: move to SIGHUP when
                  // shared pid namespaces are widely supported.
                  "--web.enable-lifecycle",
                ],
                ports_+: {
                  web: {containerPort: 9090},
                },
                volumeMounts_+: {
                  config: {mountPath: "/etc/prometheus-config", readOnly: true},
                  prometheus_data: {mountPath: "/prometheus"},
                },
                resources: {
                  requests: {cpu: "500m", memory: "3Gi"},
                  limits: self.requests {cpu: "1"},
                },
                readinessProbe: {
                  httpGet: {path: "/-/ready", port: this.ports[0].name},
                  successThreshold: 2,
                  initialDelaySeconds: 5,
                  periodSeconds: 30,
                },
                livenessProbe: self.readinessProbe {
                  httpGet: {path: "/-/healthy", port: this.ports[0].name},
                  successThreshold: 1,
                  timeoutSeconds: 10,
                  failureThreshold: 5,
                },
                startupProbe: self.livenessProbe {
                  // Crash recovery can take a _long_ time (many
                  // minutes), depending on the time since last
                  // successful compaction.
                  failureThreshold: 1 * 60 * 60 / self.periodSeconds,  // I have seen >45mins when NFS is overloaded.
                },
              },
              config_reload: kube.Container("configmap-reload") {
                image: "jimmidyson/configmap-reload:v0.1", // renovate
                args_+: {
                  "volume-dir": "/config",
                  "webhook-url": "http://localhost:9090/-/reload",
                },
                volumeMounts_+: {
                  config: {mountPath: "/config", readOnly: true},
                },
              },
            },
          },
        },
      },
    },
  },

  alertmanager: {
    local am = self,

    svc: kube.Service("alertmanager") + $.namespace {
      metadata+: {
        annotations+: {"kubernetes.io/cluster-service": "true"},
      },
      target_pod: am.deploy.spec.template,
      spec+: {
        // headless, for StatefulSet
        assert am.svc.metadata.name == am.deploy.spec.serviceName,
        clusterIP: "None",
      },
    },

    config: kube.ConfigMap("alertmanager") + $.namespace {
      data+: {
        "config.yml": kubecfg.manifestYaml($.am_config),
      },
    },

    templates: kube.ConfigMap("alertmanager-templates") + $.namespace {
      data+: {
        // empty (for now)
      },
    },

    deploy: kube.StatefulSet("alertmanager") + $.namespace {
      local this = self,
      spec+: {
        replicas: 2,
        volumeClaimTemplates_+: {
          storage: { storage: "5Gi", storageClass: "ceph-block" },
        },
        template+: {
          metadata+: {
            annotations+: {
              "prometheus.io/scrape": "true",
              "prometheus.io/scheme": "http",
              "prometheus.io/port": "9093",
              "prometheus.io/path": path_join($.ingress.am_path, "metrics"),
            },
          },
          spec+: {
            nodeSelector+: utils.archSelector("amd64"),
            volumes_+: {
              config: kube.ConfigMapVolume(am.config),
              templates: kube.ConfigMapVolume(am.templates),
            },
            affinity+: {
              podAntiAffinity+: {
                preferredDuringSchedulingIgnoredDuringExecution+: [{
                  weight: 100,
                  podAffinityTerm: {
                    labelSelector: this.spec.selector,
                    topologyKey: "kubernetes.io/hostname",
                  },
                }],
              },
            },
            default_container: "alertmanager",
            containers_+: {
              alertmanager: kube.Container("alertmanager") {
                image: "quay.io/prometheus/alertmanager:v0.24.0", // renovate
                args_+: {
                  "config.file": "/etc/alertmanager/config.yml",
                  "storage.path": "/alertmanager",
                  "web.external-url": $.ingress.am_url,

                  "cluster.listen-address": ":9094",
                  "cluster.advertise-address": "$(POD_IP):9094"
                },
                args+: [
                  "--cluster.peer=alertmanager-%s.alertmanager.monitoring:9094" % [i]
                  for i in std.range(0, this.spec.replicas - 1)
                ],
                env_+: {
                  POD_IP: kube.FieldRef("status.podIP"),
                },
                ports_+: {
                  alertmanager: {containerPort: 9093},
                  cluster: {containerPort: 9094},
                },
                volumeMounts_+: {
                  config: {mountPath: "/etc/alertmanager", readOnly: true},
                  templates: {mountPath: "/etc/alertmanager-templates", readOnly: true},
                  storage: {mountPath: "/alertmanager"},
                },
                livenessProbe+: {
                  httpGet: {path: "/alertmanager/-/healthy", port: 9093},
                  initialDelaySeconds: 60,
                  failureThreshold: 10,
                },
                readinessProbe+: self.livenessProbe {
                  initialDelaySeconds: 3,
                  timeoutSeconds: 10,
                  periodSeconds: 3,
                },
                resources+: {
                  limits: {cpu: "20m", memory: "40Mi"},
                  requests: self.limits,
                },
              },
              config_reload: kube.Container("configmap-reload") {
                image: "jimmidyson/configmap-reload:v0.1", // renovate
                args_+: {
                  "volume-dir": "/config",
                  "webhook-url": "http://localhost:9093/alertmanager/-/reload",
                },
                volumeMounts_+: {
                  config: { mountPath: "/config", readOnly: true },
                },
              },
            },
          },
        },
      },
    },
  },

  nodeExporter: {
    daemonset: utils.ArchDaemonSets(self.daemonset_, ["amd64"]),
    daemonset_:: kube.DaemonSet("node-exporter") + $.namespace {
      local this = self,

      arch:: error "arch required",

      spec+: {
        template+: {
          metadata+: {
            annotations+: {
              "prometheus.io/scrape": "true",
              "prometheus.io/port": "9100",
            },
          },
          spec+: {
            hostNetwork: true,
            hostPID: true,
            volumes_+: {
              root: kube.HostPathVolume("/"),
              procfs: kube.HostPathVolume("/proc"),
              sysfs: kube.HostPathVolume("/sys"),
            },
            tolerations: utils.toleratesMaster,
            containers_+: {
              default: kube.Container("node-exporter") {
                image: "quay.io/prometheus/node-exporter:v1.4.0", // renovate
                local v = self.volumeMounts_,
                args_+: {
                  "path.rootfs": v.root.mountPath,
                  "path.procfs": v.procfs.mountPath,
                  "path.sysfs": v.sysfs.mountPath,

                  "collector.filesystem.ignored-mount-points":
                  "^(/rootfs|/host)?/(sys|proc|dev|host|etc)($|/)",

                  "collector.filesystem.ignored-fs-types":
                  "^(sys|proc|auto|cgroup|devpts|ns|au|fuse\\.lxc|mqueue)(fs)?$",
                },
                /* fixme
                args+: [
                  "collector."+c
                  for c in ["nfs", "mountstats", "systemd"]],
                */
                ports_+: {
                  scrape: {containerPort: 9100},
                },
                livenessProbe: {
                  httpGet: {path: "/", port: "scrape"},
                },
                readinessProbe: self.livenessProbe {
                  successThreshold: 2,
                },
                volumeMounts_+: {
                  root: {mountPath: "/rootfs", readOnly: true},
                  procfs: {mountPath: "/host/proc", readOnly: true},
                  sysfs: {mountPath: "/host/sys", readOnly: true},
                },
                resources+: {
                  limits: {cpu: "100m", memory: "50Mi"},
                  requests: {cpu: "10m", memory: "25Mi"},
                },
                securityContext: {
                  allowPrivilegeEscalation: false,
                  capabilities: {
                    add+: ["SYS_TIME"],
                    drop+: ["all"],
                  },
                },
              },
            },
          },
        },
      },
    },
  },

  ksm: {
    serviceAccount: kube.ServiceAccount("kube-state-metrics") + $.namespace,

    clusterRole: kube.ClusterRole("kube-state-metrics") {
      local listwatch = {
        "": ["nodes", "pods", "services", "resourcequotas", "replicationcontrollers", "limitranges", "persistentvolumeclaims", "namespaces"],
        extensions: ["daemonsets", "deployments", "replicasets"],
        apps: ["statefulsets"] + self.extensions,
        batch: ["cronjobs", "jobs"],
      },
      all_resources:: std.set(std.flattenArrays(kube.objectValues(listwatch))),
      rules: [{
        apiGroups: [k],
        resources: listwatch[k],
        verbs: ["list", "watch"],
      } for k in std.objectFields(listwatch)],
    },

    clusterRoleBinding: kube.ClusterRoleBinding("kube-state-metrics") {
      roleRef_: $.ksm.clusterRole,
      subjects_: [$.ksm.serviceAccount],
    },

    role: kube.Role("kube-state-metrics-resizer") + $.namespace {
      rules: [
        {
          apiGroups: [""],
          resources: ["pods"],
          verbs: ["get"],
        },
        {
          apiGroups: ["extensions", "apps"],
          resources: ["deployments"],
          resourceNames: ["kube-state-metrics"],
          verbs: ["get", "update"],
        },
      ],
    },

    roleBinding: kube.RoleBinding("kube-state-metrics") + $.namespace {
      roleRef_: $.ksm.role,
      subjects_: [$.ksm.serviceAccount],
    },

    deploy: kube.Deployment("kube-state-metrics") + $.namespace {
      local deploy = self,
      spec+: {
        template+: {
          metadata+: {
            annotations+: {
              "prometheus.io/scrape": "true",
              "prometheus.io/port": "8080",
            },
          },
          spec+: {
            local spec = self,
            serviceAccountName: $.ksm.serviceAccount.metadata.name,
            nodeSelector: utils.archSelector("amd64"),
            containers_+: {
              default+: kube.Container("ksm") {
                image: "quay.io/coreos/kube-state-metrics:v1.9.8", // renovate
                ports_: {
                  metrics: {containerPort: 8080},
                },
                args_: {
                  collectors_:: std.set([
                    // remove "cronjobs" for kubernetes/kube-state-metrics#295
                    "daemonsets", "deployments", "limitranges", "nodes", "pods", "replicasets", "replicationcontrollers", "resourcequotas", "services", "jobs", "statefulsets", "persistentvolumeclaims",
                  ]),
                  collectors: std.join(",", self.collectors_),
                },
                local no_access = std.setDiff(self.args_.collectors_, $.ksm.clusterRole.all_resources),
                assert std.length(no_access) == 0 : "Missing clusterRole access for resources %s" % no_access,
                readinessProbe: {
                  httpGet: {path: "/healthz", port: 8080},
                  initialDelaySeconds: 5,
                  timeoutSeconds: 5,
                },
                resources+: {
                  limits: {cpu: "100m", memory: "100Mi"},
                  requests: {cpu: "10m", memory: "50Mi"},
                },
              },
              resizer: kube.Container("addon-resizer") {
                image: "registry.k8s.io/addon-resizer:2.3", // renovate
                command: ["/pod_nanny"],
                args_+: {
                  container: spec.containers[0].name,
                  cpu: "10m",
                  "extra-cpu": "1m",
                  memory: "10Mi",
                  "extra-memory": "2Mi",
                  deployment: deploy.metadata.name,
                },
                env_+: {
                  MY_POD_NAME: kube.FieldRef("metadata.name"),
                  MY_POD_NAMESPACE: kube.FieldRef("metadata.namespace"),
                },
                resources: {
                  limits: {cpu: "10m", memory: "30Mi"},
                  requests: self.limits,
                },
              },
            },
          },
        },
      },
    },
  },
}
