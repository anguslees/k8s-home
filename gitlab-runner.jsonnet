local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";

{
  namespace:: {metadata+: {namespace: "gitlab-runner"}},
  ns: kube.Namespace($.namespace.metadata.namespace),

  secret: utils.SealedSecret("gitlab-runner") + $.namespace {
    // If data_ is changed, reseal with ./seal.sh gitlab-runner-secret.jsonnet
    data_:: {
      "runner-registration-token": error "secret! value not overridden",
      //"runner-token": error "secret! value not overridden",
    },
    spec+: {
      data: "AgAKiXvFhUXpT263yvOYWGSSO6efaJMtykEV9Uvo0t+24qyHsUyiHg9MrQHA9LJovPqykdNi6ebLrka47aocJQH8pIw+EPZxsmZe+5Nm7v2MO51oC0ErvNRDWIm5KISVisL79E+jZ8Ajs7CjspPHumHIfCMWBf05RrmLDVg6AFv35Pt0st7AGeKYFh9sqBIy6lHWJ7CaRlSjj9+iRZdkubHoW/9JBCjssQYKxqJLrK4NvoEKjjtHFRgzzYfGKSnh5+G3m6mRU5wr9lTlJHblRIeRLMZ3IHSdpUrNu4/WHJMQNo/QnmWmdsiuNN9nJncqMDpGpA3N/7ySlgg6DVF4IjiShOCkZv3YOAOdp+5FInsbI2gw1D/8cf73LlHy9ZlK9WTDGz5M9JWNXEqAQ78NJ2V6MPRxHcAq2EWjbrITH6BqnyWJ//K2nH1I/8nhrU90aE7EpCrZIEWjJISm2dtb5CcvQa2JdZNQRtoU/cD5H9T7tANnQMbxiKx5T6YVFAzqHZQG9/s9fg7wDqDac+wg6Neo9tbZOUuIs7yDFomRWsfhcsjcQx+9N51aMKPjZhn3QTohq7ludocwS9cpzxUgdIhutfVHsRjiO3EcTpqT/NYBSNsSTz7fk9/nDTI+OJY8Igcx7WqoULyOqnZoSywgc5B6TXyZFOrhxh9kzrZ4bsW+49HuVtNF0y09lvJYLK5ePp2VpdapmcctHoZYkIEGg0KBzGCLwRWg9etfsLMAJvdKuycDirjpkhCQtDDrIz4Pz0Nxjk9rzEJGo9i4WZpeGPorcdHcU1d6zF/L9mU7qzFwhU2kAKyLnyj2/jkqde7W8E0huHIQSq2nuchH0xaXSy9Ds93rxQkUZc0ORPovnEk7SrM1aWkr5Gy2TG7voQugQnKKgLvNuFGexV3jxGWTs5Zwab02zQ5jCEjlw+tTGtXA/vUOTi+Q3s33Yxjf9FR1zOBi3RbwfUNLTuI/HGuLrNyePaHOpAiBRt4sArlxUWjwF18NH+hG/ZlANFUL9twxZOFdqNfIbXme2mCvYM9Hd8GwN4VfQs/WaVvJ/6SKrSwEYJgMjdQQlFYI0Ek7RBFb",
    },
  },

  config: utils.HashedConfigMap("gitlab-runner") + $.namespace {
    data: {
      config:: {
        concurrent: 2,
        check_interval: 60,
      },
      "config.toml": std.join("", [
        "%s = %s\n" % [kv[0], std.manifestJson(kv[1])]
        for kv in kube.objectItems(self.config)]),
    },
  },

  sa: kube.ServiceAccount("gitlab-runner") + $.namespace,

  role: kube.Role("gitlab-runner") + $.namespace {
    rules: [
      {
        apiGroups: [""],
        resources: ["pods", "secrets"],
        verbs: ["create", "delete", "get", "list", "patch", "update", "watch"],
      },
      {
        apiGroups: [""],
        resources: ["pods/attach", "pods/exec"],
        verbs: ["create"],
      },
      {
        apiGroups: [""],
        resources: ["pods/log"],
        verbs: ["get", "list", "watch"],
      },
    ],
  },

  rolebinding: kube.RoleBinding("gitlab-runner") + $.namespace {
    roleRef_: $.role,
    subjects_+: [$.sa],
  },

  deploy: kube.Deployment("gitlab-runner") + $.namespace + utils.PromScrape(9252) {
    spec+: {
      template+: {
        spec+: {
          securityContext+: {
            runAsUser: 100,
            fsGroup: 65533,
          },
          serviceAccountName: $.sa.metadata.name,

          volumes_+: {
            secrets: kube.EmptyDirVolume() {emptyDir+: {medium: "Memory"}},
            etcrunner: kube.EmptyDirVolume() {emptyDir+: {medium: "Memory"}},
            config: kube.ConfigMapVolume($.config),
          },

          containers_+: {
            runner: kube.Container("runner") {
              image: "gitlab/gitlab-runner:alpine-v10.8.0", // renovate
              command: ["/bin/sh", "-x", "-e", "-c",
                        |||
                          mkdir /home/gitlab-runner/.gitlab-runner/
                          cp /config/config.toml /home/gitlab-runner/.gitlab-runner/

                          /entrypoint register --non-interactive \
                            --executor kubernetes \
                            --tag-list linux,private,k8s \
                            --url https://gitlab.com/ci

                          exec /entrypoint run --user=gitlab-runner \
                            --working-directory=/home/gitlab-runner
                        |||
                       ],
              ports_+: {
                metrics: {containerPort: 4902},
              },
              lifecycle+: {
                preStop: {
                  exec: {
                    command: ["gitlab-runner", "unregister", "--all-runners"],
                  },
                },
              },
              env_+: {
                RUNNER_EXECUTOR: "kubernetes",
                CACHE_TYPE: "",  // NB: supports s3
                CACHE_SHARED: "",
                METRICS_SERVER: ":9252",
                //CI_SERVER_URL,
                //CLONE_URL,
                KUBERNETES_IMAGE: "bitnami/minideb:stretch",
                KUBERNETES_PRIVILEGED: "false",
                KUBERNETES_NAMESPACE: kube.FieldRef("metadata.namespace"),
                KUBERNETES_CPU_LIMIT: "2",
                KUBERNETES_MEMORY_LIMIT: "1Gi",
                KUBERNETES_CPU_REQUEST: "0",
                KUBERNETES_MEMORY_REQUEST: "256Ki",
                KUBERNETES_SERVICE_ACCOUNT: "", // for runners
                KUBERNETES_SERVICE_CPU_LIMIT: "",
                KUBERNETES_SERVICE_MEMORY_LIMIT: "",
                KUBERNETES_SERVICE_CPU_REQUEST: "",
                KUBERNETES_SERVICE_MEMORY_REQUEST: "",
                KUBERNETES_HELPERS_CPU_LIMIT: "",
                KUBERNETES_HELPERS_MEMORY_LIMIT: "",
                KUBERNETES_HELPERS_CPU_REQUEST: "",
                KUBERNETES_HELPERS_MEMORY_REQUEST: "",
                KUBERNETES_PULL_POLICY: "",
                REGISTRATION_TOKEN: kube.SecretKeyRef($.secret, "runner-registration-token"),
                //CI_SERVER_TOKEN: kube.SecretKeyRef($.secret, "runner-token"),
              },
              volumeMounts_+: {
                secrets: {mountPath: "/secrets"},
                etcrunner: {mountPath: "/etc/gitlab-runner"},
                config: {mountPath: "/config"},
              },
              readinessProbe: {
                exec: {command: ["/usr/bin/pgrep", "gitlab.*runner"]},
                initialDelaySeconds: 10,
                timeoutSeconds: 1,
                periodSeconds: 30,
                successThreshold: 1,
                failureThreshold: 3,
              },
              livenessProbe: self.readinessProbe {
                initialDelaySeconds: 60,
              },
              resources+: {
                limits: {memory: "256Mi", cpu: "200m"},
              },
            },
          },
        },
      },
    },
  },
}
