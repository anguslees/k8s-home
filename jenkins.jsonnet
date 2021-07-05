local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";

// aka lts-alpine
// renovate: depName=jenkins/jenkins
local version = "2.289.2-alpine";
// renovate: depName=jenkins/jnlp-slave
local jnlp_version = "4.9-1-alpine";

{
  namespace:: {metadata+: {namespace: "jenkins"}},

  ns: kube.Namespace($.namespace.metadata.namespace),

  http_proxy:: error "this file assumes an http_proxy",

  // List of plugins to be install during Jenkins master start
  plugins:: {
    kubernetes: "1.10.1",
    prometheus: "1.2.2",
    "workflow-aggregator": "2.5",
    "workflow-job": "2.23",
    "credentials-binding": "1.16",
    git: "3.9.1",
  },

  logging:: {
    level:: "FINEST",
    handlers: "java.util.logging.ConsoleHandler",
    "jenkins.level": self.level,
    "java.util.logging.ConsoleHandler.formatter": "java.util.logging.SimpleFormatter",
    "java.util.logging.ConsoleHandler.level": self.level,
  },

  // Used to approve a list of groovy functions in pipelines used the
  // script-security plugin. Can be viewed under /scriptApproval
  scriptApproval:: [
    //"method groovy.json.JsonSlurperClassic parseText java.lang.String",
    //"new groovy.json.JsonSlurperClassic",
  ],

  config: utils.HashedConfigMap("jenkins") + $.namespace {
    data+: {
      "config.xml":
      ("<?xml version='1.0' encoding='UTF-8'?>\n" +
       std.manifestXmlJsonml([
         "hudson",
         ["disabledAdministrativeMonitors"],
         ["version", "${JENKINS_VERSION}"],
         ["numExecutors", std.toString(0)],
         ["mode", "NORMAL"],
         ["useSecurity", std.toString(true)],
         ["authorizationStrategy",
          {class: "hudson.security.FullControlOnceLoggedInAuthorizationStrategy"},
          ["denyAnonymousReadAccess", std.toString(true)],
         ],
         ["securityRealm", {class: "hudson.security.LegacySecurityRealm"}],
         ["disableRememberMe", std.toString(false)],
         ["projectNamingStrategy", {class: "jenkins.model.ProjectNamingStrategy$DefaultProjectNamingStrategy"}],
         ["workspaceDir", "${JENKINS_HOME}/workspace/${ITEM_FULLNAME}"],
         ["buildsDir", "${ITEM_ROOTDIR}/builds"],
         ["markupFormatter", {class: "hudson.markup.EscapedMarkupFormatter"}],
         ["jdks"],
         ["viewsTabBar", {class: "hudson.views.DefaultViewsTabBar"}],
         ["myViewsTabBar", {class: "hudson.views.DefaultMyViewsTabBar"}],
         ["clouds",
          ["org.csanchez.jenkins.plugins.kubernetes.KubernetesCloud",
           {plugin: "kubernetes@" + $.plugins.kubernetes},
           ["name", "kubernetes"],
           ["templates",
            // TODO: transcribe from a regular jsonnet PodSpec declaration
            ["org.csanchez.jenkins.plugins.kubernetes.PodTemplate",
             ["inheritFrom"],
             ["name", "default"],
             ["instanceCap", std.toString(2147483647)], // INT_MAX
             ["idleMinutes", std.toString(0)],
             ["label", "jenkins-agent"],
             ["nodeSelector",
              std.join(",", [
                "%s=%s" % kv for kv in kube.objectItems(utils.archSelector("amd64"))])],
             ["nodeUsageMode", "NORMAL"],
             ["volumes"],
             ["containers",
              ["org.csanchez.jenkins.plugins.kubernetes.ContainerTemplate",
               ["name", "jnlp"],
               ["image", "jenkins/jnlp-slave:" + jnlp_version],
               ["privileged", std.toString(false)],
               ["workingDir", "/home/jenkins"],
               ["command"],
               ["args", "${computer.jnlpmac} ${computer.name}"],
               ["ttyEnabled", std.toString(false)],
               ["resourceRequestCpu", "2"],
               ["resourceRequestMemory", "256Mi"],
               //["resourceLimitCpu", "2"],
               //["resourceLimitMemory", "256Mi"],
               ["envVars",
                ["org.csanchez.jenkins.plugins.kubernetes.ContainerEnvVar",
                 ["key", "JENKINS_URL"],
                 ["value", $.masterSvc.http_url],
                ],
               ],
              ],
             ],
             ["envVars"],
             ["annotations"],
             ["imagePullSecrets"],
             ["nodeProperties"],
            ],
           ],
           ["serverUrl", "https://kubernetes.default"],
           ["skipTlsVerify", std.toString(false)],
           ["namespace", $.namespace.metadata.namespace],
           ["jenkinsUrl", $.masterSvc.http_url],
           ["jenkinsTunnel", $.agentSvc.host_colon_port],
           ["containerCap", std.toString(10)],
           ["retentionTimeout", std.toString(5)],
           ["connectTimeout", std.toString(5)],
           ["readTimeout", std.toString(15)],
          ],
         ],
         ["quietPeriod", std.toString(5)],
         ["scmCheckoutRetryCount", std.toString(0)],
         ["views",
          ["hudson.model.AllView",
           ["owner", {class: "hudson", reference: "../../.."}],
           ["name", "all"],
           ["filterExecutors", std.toString(false)],
           ["filterQueue", std.toString(false)],
           ["properties", {class: "hudson.model.View$PropertyList"}],
          ],
         ],
         ["primaryView", "all"],
         ["slaveAgentPort", $.master.spec.template.spec.containers_.jenkins.ports_.agent],
         ["disabledAgentProtocols",
          ["string", "JNLP-connect"],
          ["string", "JNLP2-connect"],
         ],
         ["label"],
         ["crumbIssuer", {class: "hudson.security.csrf.DefaultCrumbIssuer"},
          ["excludeClientIPFromCrumb", std.toString(true)],
         ],
         ["nodeProperties"],
         ["globalNodeProperties",
          ["hudson.slaves.EnvironmentVariablesNodeProperty",
           local env = {
             http_proxy: $.http_proxy.http_url,
             no_proxy: ".lan,.local,.cluster,.svc",
           };
           ["envVars", {serialization: "custom"},
            ["unserializable-parents"],
            ["tree-map",
             ["default",
              ["comparator", {class: "hudson.util.CaseInsensitiveComparator"}],
             ],
             ["int", std.toString(std.length(env))],
            ] + std.flattenArrays([
              [["string", kv[0]], ["string", kv[1]]] for kv in kube.objectItems(env)]),
           ],
          ],
         ],
         ["noUsageStatistics", std.toString(true)],
       ])),

      "scriptapproval.xml.override":
      ("<?xml version='1.0' encoding='UTF-8'?>\n" +
       std.manifestXmlJsonml([
         "scriptApproval",
         {plugin: "script-security@1.27"},
         ["approvedScriptHashes"],
         ["approvedSignatures"] + [["string", a] for a in $.scriptApproval],
         ["aclApprovedSignatures"],
         ["approvedClasspathEntries"],
         ["pendingScripts"],
         ["pendingSignatures"],
         ["pendingClasspathEntries"],
       ])),

      "log.properties.override": std.join("\n", [
        "%s=%s" % kv for kv in kube.objectItems($.logging)]),

      // remove the wizard "install additional plugins" banner
      "jenkins.install.UpgradeWizard.state": "2.0\n",
    },
  },

  initScripts: utils.HashedConfigMap("jenkins-init") + $.namespace {
    data+: {
      "init.groovy": |||
        import jenkins.model.*
        Jenkins.instance.setNumExecutors(0)
      |||,
    },
  },

  secret: utils.SealedSecret("jenkins") + $.namespace {
    // If data_ is changed, reseal with ./seal.sh jenkins-secret.jsonnet
    data_:: {
      "admin-user": error "secret! value not overridden",
      "admin-password": error "secret! value not overridden",
    },
    spec+: {
      data: "AgBY65ZUdHRv4OQjGD+oLFEZYexKiEfjX5PVC5dnuniLBD7AtmD03eBEqT4A2uu8LVThfMiKbDVMe3uHm3l7/ApG7dw3bCDFZGk2K8Z++z+ff+ZOTyaGNEafqKT8R3pqQhjrEpsDOIKH2eGnd1oPFIj66/HaWnBP97iWpTaERwYi0JU+aBrHQJTNpnVupZ0uRxAI46ZiYyj2mgaY+fZwEFcp+9OGxYY/iku+a1O64OAq0GHlkwb7aZcPErEgH5jYvMypXmyI7oG5bjfulJAQge88WHgzGdT0iO4NbWwVLgdIGdSYetIO7VO8asdZ48tZQ5qogc67b7PVyMPvx6Ycdk7LURt1quaN2eoxF6M2Vexf0d/f00KRIoDEg6++EN0XKC+RPY8W2m3/Kk3w7KrBybQ0a77+fHixMNPbVe+bYLQB4YC9DeY/afPaU2vR+r82pgd6iVEoG1kGw3sZg8TucNpn0lqQd+yvHBDOopSb6KtesyTM39hsGHH6JbWzvsqJWWYsCnp8UlGNiqPiXZwSlIHy5il80EwVuydZhlP/s//45dUBuf28Tvio+x2/Ba0LeOTCw5Fxk/dqVC1ZGVuv8htzDvMC+wb7+W6NpmZOnaao4ijEYa7UhX4fS2jrUPbXV5+9aQeOKjYKWQ29ktpHkIuG9GTkW0cCQzt2+n5AEZL6zOokVuHh1mD0rFZUGUQ8Ec9Sm1zbfm/tllBnjiFgcDPd2reO/b9qkO9cjdPXUPqPdcTjZozidTR71MRGzU+Ewagv+XLWy1QO2CBNUs3TaP4/3BvK5XVXJZEQ/YuZ1/mpSg5M47n//5XG2SIMTYJUutpaqp7kATHM9vYMvrI/61TGovA5WmqpYoq0knq24c5sFwxYvgniMbkD1iTC2FP5YGzkEfCo+bnmrCuwZ21KUL2pCScn+zneQVpf/EZAK4VK5QoVkx2lgMFuDZ4hhuIBSE678suAxryaZynt/p035NsmiCGKmNkdJccWLXEdcVcmLNenoAGuKmppitu24X/m0LMXdOZl8Nb/t4TE18v7J79bhlsBeVg5byfF",
    },
  },

  agentSvc: kube.Service("jenkins-agent") + $.namespace {
    target_pod: $.master.spec.template,
    spec+: {
      //clusterIP: "None", // headless
      ports: [
        {
          port: 50000,
          targetPort: "agent",
          name: "agent",
        },
      ],
    },
  },

  masterSvc: kube.Service("jenkins") + $.namespace {
    target_pod: $.master.spec.template,
    spec+: {
      ports: [
        {
          port: 80,
          name: "http",
          targetPort: "http",
        },
      ],
    },
  },

  masterSsh: kube.Service("jenkins-ssh") + $.namespace {
    target_pod: $.master.spec.template,
    spec+: {
      type: "LoadBalancer",
      ports: [
        {
          port: 50022,
          name: "ssh",
          targetPort: "ssh",
        },
      ],
    },
  },

  /*
  masterPolicy: kube.NetworkPolicy("jenkins") + $.namespace {
    target: $.master,
    spec+: {
      local master = $.master.spec.template.spec.containers_.jenkins,
      ingress: [
        // Allow web access to UI
        {
          ports: [{port: master.ports_.http.containerPort}],
        },
        // Allow inbound connections from slave
        {
          from: [{podSelector: {matchLabels: {"jenkins": "slave"}}}],
          ports: [
            {port: master.ports_.http.containerPort},
            {port: master.ports_.agent.containerPort},
          ],
        },
      ],
    },
  },
  */

  /*
  agentPolicy: kube.NetworkPolicy("jenkins-agent") + $.namespace {
    spec+: {
      podSelector: {matchLabels: {"jenkins": "slave"}},
      // Deny all ingress
    },
  },
  */

  serviceAccount: kube.ServiceAccount("jenkins") + $.namespace,

  // for jenkins kubernetes plugin
  k8sExecutorRole: kube.Role("jenkins-executor") + $.namespace {
    rules: [
      {
        apiGroups: [""],
        resources: ["pods"],
        verbs: ["create", "delete", "get", "list", "patch", "update", "watch"],
      },
      {
        apiGroups: [""],
        resources: ["pods/exec"],
        verbs: ["create", "delete", "get", "list", "patch", "update", "watch"],
      },
      {
        apiGroups: [""],
        resources: ["pods/log"],
        verbs: ["get", "list", "watch"],
      },
      {
        apiGroups: [""],
        resources: ["secrets"],  // is this really required?
        verbs: ["get"],
      },
    ],
  },

  k8sExecutorBinding: kube.RoleBinding("jenkins-executor") + $.namespace {
    roleRef_: $.k8sExecutorRole,
    subjects_: [$.serviceAccount],
  },

  ing: utils.Ingress("jenkins") + $.namespace {
    host: "jenkins.k.lan",
    target_svc: $.masterSvc,
  },

  ingExt: utils.Ingress("jenkins-external") + utils.IngressTls + $.namespace {
    host: "jenkins.oldmacdonald.farm",
    target_svc: $.masterSvc,
  },

  // FIXME: should be a StatefulSet, but they don't update well :(
  master: kube.StatefulSet("jenkins") + $.namespace {
    spec+: {
      replicas: 1,
      podManagementPolicy: "Parallel",
      volumeClaimTemplates_: {
        home: {storage: "10Gi", storageClass: "ceph-block"},
      },
      template+: {
        metadata+: {
          annotations+: {
            "prometheus.io/scrape": "true",
            "prometheus.io/port": "8080",
            "prometheus.io/path": "/prometheus",
          },
        },
        spec+: {
          nodeSelector+: utils.archSelector("amd64"),
          terminationGracePeriodSeconds: 30,
          serviceAccountName: $.serviceAccount.metadata.name,
          securityContext+: {
            runAsUser: 1000, // "jenkins"
            fsGroup: self.runAsUser,
          },
          volumes_+: {
            config: kube.ConfigMapVolume($.config),
            init: kube.ConfigMapVolume($.initScripts),
            plugins: kube.EmptyDirVolume(),
            secrets: kube.EmptyDirVolume(), // todo
          },
          initContainers_+: {
            /* (disabled - I'm not managing plugins declaratively)
            // TODO: The "right" thing to do is to build a custom
            // image, rather than download these again on every
            // container restart..
            plugins: kube.Container("plugins") {
              image: "jenkins/jenkins:" + version,
              command: ["install-plugins.sh"],
              args: ["%s:%s" % kv for kv in kube.objectItems($.plugins)],
              env_+: {
                http_proxy: $.http_proxy.http_url,
              },
              volumeMounts_+: {
                plugins: {mountPath: "/usr/share/jenkins/ref/plugins", readOnly: false},
              },
            },
             */
          },
          containers_+: {
            jenkins: kube.Container("jenkins") {
              local container = self,
              image: "jenkins/jenkins:" + version,
              env_+: {
                local heapmax = kube.siToNum(container.resources.requests.memory),
                JAVA_OPTS: std.join(" ", [
                  //"-XX:+UnlockExperimentalVMOptions",
                  //"-XX:+UseCGroupMemoryLimitForHeap",
                  //"-XX:MaxRAMFraction=1",
                  "-Xmx%dm" % (heapmax / std.pow(2, 20)),
                  "-Xms%dm" % (heapmax * 0.6 / std.pow(2, 20)),
                  "-XshowSettings:vm",
                  // See also https://jenkins.io/blog/2016/11/21/gc-tuning/
                  "-XX:+UseG1GC",
                  "-XX:+ExplicitGCInvokesConcurrent",
                  "-XX:+ParallelRefProcEnabled",
                  "-XX:+UseStringDeduplication",
                  "-XX:+UnlockExperimentalVMOptions",
                  "-XX:G1NewSizePercent=20",
                  "-XX:+UnlockDiagnosticVMOptions",
                  "-XX:G1SummarizeRSetStatsPeriod=1",

                  "-Dhudson.slaves.NodeProvisioner.initialDelay=0",
                  "-Dhudson.slaves.NodeProvisioner.MARGIN=50",
                  "-Dhudson.slaves.NodeProvisioner.MARGIN0=0.85",
                  //"-Djava.util.logging.config.file=/var/jenkins_home/log.properties",
                  "-Dhttp.proxyHost=%s" % $.http_proxy.host,
                  "-Dhttp.proxyPort=%s" % $.http_proxy.spec.ports[0].port,
                ]),
                JENKINS_OPTS: std.join(" ", [
                  "--argumentsRealm.passwd.$(ADMIN_USER)=$(ADMIN_PASSWORD)",
                  "--argumentsRealm.roles.$(ADMIN_USER)=admin",
                ]),
                ADMIN_USER: kube.SecretKeyRef($.secret, "admin-user"),
                ADMIN_PASSWORD: kube.SecretKeyRef($.secret, "admin-password"),
                http_proxy: $.http_proxy.http_url,
              },
              ports_+: {
                http: {containerPort: 8080},
                agent: {containerPort: 50000},
                ssh: {containerPort: 50022}, // disabled by default
              },
              readinessProbe: {
                httpGet: {path: "/login", port: "http"},
                timeoutSeconds: 10,
                periodSeconds: 30,
              },
              livenessProbe: self.readinessProbe {
                timeoutSeconds: 30,
                failureThreshold: 5,
                periodSeconds: 30,
              },
              startupProbe: self.livenessProbe {
                // Java :(
                initialDelaySeconds: 2*60,
                failureThreshold: 30 * 60 / self.periodSeconds,
              },
              resources: {
                limits: {cpu: "1", memory: "1.5Gi"},
                requests: {cpu: "10m", memory: "1Gi"},
              },
              volumeMounts_+: {
                home: {mountPath: "/var/jenkins_home", readOnly: false},
                config: {mountPath: "/usr/share/jenkins/ref", readOnly: true},
                init: {mountPath: "/usr/share/jenkins/ref/init.groovy.d", readOnly: true},
                plugins: {mountPath: "/usr/share/jenkins/ref/plugins", readOnly: true},
                secrets: {mountPath: "/usr/share/jenkins/ref/secrets", readOnly: true},
              },
            },
          },
        },
      },
    },
  },
}
