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
              {path: this.prom_path, backend: $.prometheus.svc.name_port},
              {path: this.am_path, backend: $.alertmanager.svc.name_port},
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
    // "foo.yml": {...},
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
          apiGroups: ["extensions"],
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
        annotations+: {
          "prometheus.io/scrape": "true",
          "prometheus.io/path": path_join($.ingress.prom_path, "metrics"),
        },
      },
      target_pod: prom.deploy.spec.template,
    },

    config: kube.ConfigMap("prometheus") + $.namespace {
      data+: $.rules {
        "prometheus.yml": kubecfg.manifestYaml($.config),
      },
    },

    data: kube.PersistentVolumeClaim("prometheus-data") + $.namespace {
      // https://prometheus.io/docs/prometheus/2.0/storage/#operational-aspects
      //  On average, Prometheus uses only around 1-2 bytes per
      //  sample. Thus, to plan the capacity of a Prometheus server,
      //  you can use the rough formula:
      //  needed_disk_space = retention_time_seconds * ingested_samples_per_second * bytes_per_sample
      retention_days:: prom.deploy.spec.template.spec.containers_.default.args_.retention_days,
      retention_secs:: self.retention_days * 86400,
      time_series:: 1000, // wild guess
      samples_per_sec:: self.time_series / $.config.global.scrape_interval_secs,
      bytes_per_sample:: 2,
      needed_space:: self.retention_secs * self.samples_per_sec * self.bytes_per_sample,
      overhead_factor:: 1.5,
      storage: "%dMi" % [self.overhead_factor * self.needed_space / 1e6],
    },

    deploy: kube.Deployment("prometheus") + $.namespace {
      spec+: {
        template+: {
          spec+: {
            terminationGracePeriodSeconds: 300,
            serviceAccountName: prom.serviceAccount.metadata.name,
            nodeSelector+: utils.archSelector("amd64"),
            volumes_+: {
              config: kube.ConfigMapVolume(prom.config),
              data: kube.PersistentVolumeClaimVolume(prom.data),
            },
            containers_+: {
              default: kube.Container("prometheus") {
                local this = self,
                image: "prom/prometheus:v2.0.0",
                args_+: {
                  //"log.level": "debug",  // default is info

                  "web.external-url": $.ingress.prom_url,

                  "config.file": this.volumeMounts_.config.mountPath + "/prometheus.yml",
                  "storage.tsdb.path": this.volumeMounts_.data.mountPath,
                  retention_days:: 28,
                  "storage.tsdb.retention": "%dd" % self.retention_days,

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
                  data: {mountPath: "/prometheus"},
                },
                resources: {
                  requests: {cpu: "500m", memory: "500Mi"},
                },
                livenessProbe: {
                  httpGet: {path: "/", port: this.ports[0].name},
                  // Crash recovery can take a long time (~1 minute)
                  initialDelaySeconds: 3 * 60,
                },
                readinessProbe: self.livenessProbe {
                  successThreshold: 2,
                  initialDelaySeconds: 5,
                },
              },
              config_reload: kube.Container("configmap-reload") {
                image: "jimmidyson/configmap-reload:v0.1",
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
        annotations+: {
          "prometheus.io/scrape": "true",
          "prometheus.io/scheme": "http",
          "prometheus.io/path": path_join($.ingress.am_path, "metrics"),
        },
      },
      target_pod: am.deploy.spec.template,
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

    data: kube.PersistentVolumeClaim("alertmanager-data") + $.namespace {
      storage: "5Gi",
    },

    deploy: kube.Deployment("alertmanager") + $.namespace {
      spec+: {
        template+: {
          spec+: {
            nodeSelector+: utils.archSelector("amd64"),
            volumes_+: {
              config: kube.ConfigMapVolume(am.config),
              templates: kube.ConfigMapVolume(am.templates),
              storage: kube.PersistentVolumeClaimVolume(am.data),
            },
            containers_+: {
              default: kube.Container("alertmanager") {
                image: "quay.io/prometheus/alertmanager:v0.13.0",
                args_+: {
                  "config.file": "/etc/alertmanager/config.yml",
                  "storage.path": "/alertmanager",
                  "web.external-url": $.ingress.am_url,
                },
                ports_+: {
                  alertmanager: {containerPort: 9093},
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
                  timeoutSeconds: 3,
                  periodSeconds: 3,
                },
              },
              config_reload: kube.Container("configmap-reload") {
                image: "jimmidyson/configmap-reload:v0.1",
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
          spec+: {
            hostNetwork: true,
            hostPID: true,
            volumes_+: {
              root: kube.HostPathVolume("/"),
              procfs: kube.HostPathVolume("/proc"),
              sysfs: kube.HostPathVolume("/sys"),
            },
            tolerations: [{
              effect: "NoSchedule",
              key: "node-role.kubernetes.io/master",
            }],
            containers_+: {
              default: kube.Container("node-exporter") {
                image: "prom/node-exporter:v0.15.2",  // fixme: +this.arch
                local v = self.volumeMounts_,
                args_+: {
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
        apps: ["statefulsets"],
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
          apiGroups: ["extensions"],
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
                image: "quay.io/coreos/kube-state-metrics:v1.1.0",
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
              },
              resizer: kube.Container("addon-resizer") {
                image: "gcr.io/google_containers/addon-resizer:1.0",
                command: ["/pod_nanny"],
                args_+: {
                  container: spec.containers[0].name,
                  cpu: "100m",
                  "extra-cpu": "1m",
                  memory: "100Mi",
                  "extra-memory": "2Mi",
                  threshold: 5,
                  deployment: deploy.metadata.name,
                },
                env_+: {
                  MY_POD_NAME: kube.FieldRef("metadata.name"),
                  MY_POD_NAMESPACE: kube.FieldRef("metadata.namespace"),
                },
                resources: {
                  limits: {cpu: "100m", memory: "30Mi"},
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
