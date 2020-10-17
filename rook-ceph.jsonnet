local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";
local rookCephSystem = import "rook-ceph-system.jsonnet";

local arch = "amd64";

// https://hub.docker.com/r/ceph/ceph/tags
local cephVersion = "v14.2.6-20200115";

{
  namespace:: {metadata+: {namespace: "rook-ceph"}},
  ns: kube.Namespace($.namespace.metadata.namespace),

  // operator picks this up and merges it into rook-ceph-config, which
  // then (eventually) ends up as ceph.conf everywhere.
  configOverride: kube.ConfigMap("rook-config-override") + $.namespace {
    data+: {
      config: |||
        [global]
        # Default of 0.05 is too aggressive for my cluster. (seconds)
        mon clock drift allowed = 0.1
        # K8s image-gc-low-threshold is 80% - not much point warning
        # before that point. (percent)
        # Really, this should align with {nodefs,imagefs}.available
        # soft limit, and allow absolute size, not just ratio.
        mon data avail warn = 10
      |||,
    },
  },

  mgrSa: kube.ServiceAccount("rook-ceph-mgr") + $.namespace,

  osdRole: kube.Role("rook-ceph-osd") + $.namespace {
    rules: [
      {
        apiGroups: [""],
        resources: ["configmaps"],
        verbs: ["get", "list", "watch", "create", "update", "delete"],
      },
    ],
  },

  osdSa: kube.ServiceAccount("rook-ceph-osd") + $.namespace,

  osdRoleBinding: kube.RoleBinding("rook-ceph-osd") + $.namespace {
    roleRef_: $.osdRole,
    subjects_+: [$.osdSa],
  },

  reporterSa: kube.ServiceAccount("rook-ceph-cmd-reporter") + $.namespace,

  reporterRole: kube.Role("rook-ceph-cmd-reporter") + $.namespace {
    rules: [
      {
        apiGroups: [""],
        resources: ["pods", "configmaps"],
        verbs: ["get", "list", "watch", "create", "update", "delete"],
      },
    ],
  },

  reporterRoleBinding: kube.RoleBinding("rook-ceph-cmd-reporter") + $.namespace {
    roleRef_: $.reporterRole,
    subjects_+: [$.reporterSa],
  },

  mgrRole: kube.Role("rook-ceph-mgr") + $.namespace {
    rules: [
      {
        apiGroups: [""],
        resources: ["pods", "services"],
        verbs: ["get", "list", "watch"],
      },
      {
        apiGroups: ["batch"],
        resources: ["jobs"],
        verbs: ["get", "list", "watch", "create", "update", "delete"],
      },
      {
        apiGroups: ["ceph.rook.io"],
        resources: ["*"],
        verbs: ["*"],
      },
    ],
  },

  mgrClusterRole: kube.ClusterRole("rook-ceph-mgr-cluster") {
    metadata+: {
      labels+: {operator: "rook", "storage-backend": "ceph"},
    },
    rules: [
      {
        apiGroups: [""],
        resources: ["configmaps", "nodes", "nodes/proxy"],
        verbs: ["get", "list", "watch"],
      },
    ],
  },

  mgrSystemBinding: kube.RoleBinding("rook-ceph-mgr-system") + $.namespace {
    roleRef_: rookCephSystem.mgrSystemRole,
    subjects_+: [$.mgrSa],
  },

  mgrClusterRoleBinding: kube.ClusterRoleBinding("rook-ceph-mgr-cluster") {
    roleRef_: $.mgrClusterRole,
    subjects_+: [$.mgrSa],
  },

  mgrBinding: kube.RoleBinding("rook-ceph-mgr") + $.namespace {
    roleRef_: $.mgrRole,
    subjects_+: [$.mgrSa],
  },

  // Allow operator to create resources in this namespace too.
  cephClusterMgmtBinding: kube.RoleBinding("rook-ceph-cluster-mgmt") + $.namespace {
    roleRef_: rookCephSystem.cephClusterMgmt,
    subjects_+: [rookCephSystem.sa],
  },

  cluster: rookCephSystem.CephCluster("rook-ceph") + $.namespace {
    spec+: {
      // NB: Delete contents of this dir if recreating Cluster
      dataDirHostPath: "/var/lib/rook",
      cephVersion: {
        image: "ceph/ceph:" + cephVersion,
      },
      mon: {
        count: 3,
        allowMultiplePerNode: false,
        resources: {
          requests: {memory: "750Mi", cpu: "100m"},
        },
      },
      mgr: {
        modules: [
          {name: "pg_autoscaler", enabled: true},
        ],
        resources: {
          requests: {memory: "400Mi", cpu: "100m"},
        },
      },
      osd: {
        resources: {
          requests: {memory: "400Mi", cpu: "100m"},
        },
      },
      dashboard: {
        enabled: true,
        port: 8443,
        ssl: true,
      },
      network: {
        hostNetwork: false,
      },
      placement: {
        all: {
          nodeAffinity: {
            requiredDuringSchedulingIgnoredDuringExecution: {
              nodeSelectorTerms+: [{
                matchExpressions: [
                  {key: kv[0], operator: "In", values: [kv[1]]}
                  for kv in kube.objectItems(utils.archSelector(arch))
                ],
              }],
            },
          },
        },
      },
      storage: {
        useAllNodes: true,
        useAllDevices: false,
        directories: [{path: "/var/lib/rook"}],
      },
    },
  },

  // Expose rook-ceph-mgr-dashboard outside cluster
  ing: utils.Ingress("ceph-dashboard") + $.namespace {
    metadata+: {
      annotations+: {
        "nginx.ingress.kubernetes.io/backend-protocol": "HTTPS",
        "nginx.ingress.kubernetes.io/server-snippet": |||
          proxy_ssl_verify off;
        |||,
      },
    },
    spec+: {
      rules: [{
        host: "ceph.k.lan",
        http: {
          paths: [{
            path: "/",
            backend: {
              serviceName: "rook-ceph-mgr-dashboard",
              servicePort: "https-dashboard",
            },
          }],
        },
      }],
    },
  },

  // These are not defined upstream, but should be (imo).
  // https://github.com/rook/rook/issues/2128
  monDisruptionBudget: kube.PodDisruptionBudget("rook-ceph-mon") + $.namespace {
    spec+: {
      minAvailable:: null,
      maxUnavailable: 1,
      selector: {matchLabels: {app: "rook-ceph-mon"}},
    },
  },
  mdsDisruptionBudget: kube.PodDisruptionBudget("rook-ceph-mds") + $.namespace {
    spec+: {
      minAvailable: 1,
      selector: {matchLabels: {app: "rook-ceph-mds"}},
    },
  },
  osdDisruptionBudget: kube.PodDisruptionBudget("rook-ceph-osd") + $.namespace {
    spec+: {
      minAvailable:: null,
      maxUnavailable: 1,  // not true _after_ re-replication has taken place..
      selector: {matchLabels: {app: "rook-ceph-osd"}},
    },
  },

  // Define storage pools / classes
  replicapool: rookCephSystem.CephBlockPool("replicapool") + $.namespace {
    spec+: {
      failureDomain: "host",
      replicated: {size: 2},
    },
  },

  block: kube.StorageClass("ceph-block") {
    provisioner: "ceph.rook.io/block",
    parameters: {
      pool: $.replicapool.metadata.name,
      clusterNamespace: $.cluster.metadata.namespace,
      fstype: "ext4",
    },
  },

  blockCsi: kube.StorageClass("csi-ceph-block") {
    provisioner: rookCephSystem.cephSystem.metadata.namespace + ".rbd.csi.ceph.com",
    parameters: {
      clusterID: $.cluster.metadata.namespace,
      pool: $.replicapool.metadata.name,
      imageFormat: "2",
      imageFeatures: "layering",

      "csi.storage.k8s.io/provisioner-secret-name": "rook-csi-rbd-provisioner",
      "csi.storage.k8s.io/provisioner-secret-namespace": self.clusterID,
      "csi.storage.k8s.io/node-stage-secret-name": "rook-csi-rbd-node",
      "csi.storage.k8s.io/node-stage-secret-namespace": self.clusterID,

      "csi.storage.k8s.io/fstype": "ext4",
    },
  },

  // NB: Still needs provisioner support in rook
  filesystem: rookCephSystem.CephFilesystem("ceph-filesystem") + $.namespace {
    local this = self,
    spec+: {
      metadataPool: {replicated: {size: 3}},
      dataPools: [{replicated: {size: 2}}],
      metadataServer: {
        activeCount: 1,
        activeStandby: true,
        placement: {
          podAntiAffinity: {
            local selector = {
              app: "rook-ceph-mds",
              rook_file_system: this.metadata.name,
            },
            preferredDuringSchedulingIgnoredDuringExecution: [
              {
                weight: 100,
                podAffinityTerm: {
                  labelSelector: selector,
                  topologyKey: "kubernetes.io/hostname",
                },
              },
              {
                weight: 100,
                podAffinityTerm: {
                  labelSelector: selector,
                  topologyKey: "failure-domain.beta.kubernetes.io/zone",
                },
              },
            ],
          },
        },
      },
    },
  },

  cephfsCsi: kube.StorageClass("csi-cephfs") {
    provisioner: rookCephSystem.cephSystem.metadata.namespace + ".cephfs.csi.ceph.com",
    parameters: {
      clusterID: $.cluster.metadata.namespace,
      fsName: $.filesystem.metadata.name,
      pool: self.fsName + "-data0",
      "csi.storage.k8s.io/provisioner-secret-name": "rook-csi-cephfs-provisioner",
      "csi.storage.k8s.io/provisioner-secret-namespace": self.clusterID,
      "csi.storage.k8s.io/node-stage-secret-name": "rook-csi-cephfs-node",
      "csi.storage.k8s.io/node-stage-secret-namespace": self.clusterID,
    },
  },

  // These are used to coordinate with coreos' node updater
  // https://github.com/rook/rook/tree/release-1.0/cluster/examples/coreos

  rebootScriptSa: kube.ServiceAccount("rook-node-annotator") + $.namespace,
  annotatorRole: kube.ClusterRole("rook-node-annotator") {
    rules+: [{
      apiGroups: [""],
      resources: ["nodes"],
      verbs: ["patch", "get"],
    }],
  },
  annotatorBinding: kube.ClusterRoleBinding("rook-node-annotator") {
    roleRef_: $.annotatorRole,
    subjects_+: [$.rebootScriptSa],
  },

  rebootScript(beforeAfter):: {
    local this = self,

    config: utils.HashedConfigMap("ceph-%s-reboot-script" % beforeAfter) + $.namespace {
      data+: {
        "status-check.sh": |||
           #!/bin/bash

           # preflightCheck checks for existence of "dependencies"
           preflightCheck() {
               if [ ! -f "/var/run/secrets/kubernetes.io/serviceaccount/token" ]; then
                   echo "$(date) | No Kubernetes ServiceAccount token found."
                   exit 1
               else
                   KUBE_TOKEN="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
                   export KUBE_TOKEN
               fi
           }

           # updateNodeRebootAnnotation sets the `ceph-reboot-check` annotation to `true` on `$NODE`
           updateNodeRebootAnnotation(){
               local annotation="$1"
               local msg="$2"
               local PATCH="[{ \"op\": \"add\", \"path\": \"/metadata/annotations/$annotation\", \"value\": \"true\" }]"
               TRIES=0
               until [ $TRIES -eq 10 ]; do
                   if curl -sSk \
                       --fail \
                       -XPATCH \
                       -H "Authorization: Bearer $KUBE_TOKEN" \
                       -H "Accept: application/json" \
                       -H "Content-Type:application/json-patch+json" \
                       --data "$PATCH" \
                       "https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_PORT_443_TCP_PORT/api/v1/nodes/$NODE"; then
                       echo "$(date) | Annotation \"$annotation\" from node $NODE updated to \"true\". $msg"
                       return 0
                   else
                       echo "$(date) | Kubernetes API server connection error, will retry in 5 seconds..."
                       (( TRIES++ ))
                       /bin/sleep 5
                   fi
               done
               return 1
           }

           # checkCephClusterHealth checks `ceph health` command for `HEALTH_OK`
           checkCephClusterHealth(){
               echo "$(date) | Running ceph health command"
               if /usr/bin/ceph health | grep -q "HEALTH_OK"; then
                   echo "$(date) | Ceph cluster health is: OKAY"
                   return 0
               fi
               return 1
           }

        |||,
      },
    },

    deploy: kube.DaemonSet("ceph-%s-reboot-check" % beforeAfter) + $.namespace {
      spec+: {
        template+: utils.CriticalPodSpec + {
          spec+: {
            serviceAccountName: $.rebootScriptSa.metadata.name,
            affinity: {
              nodeAffinity: {
                requiredDuringSchedulingIgnoredDuringExecution: {
                  nodeSelectorTerms: [
                    {
                      matchExpressions: [{
                        key: "container-linux-update.v1.coreos.com/%s-reboot" % beforeAfter,
                        operator: "In",
                        values: ["true"],
                      }],
                    },
                    {
                      matchExpressions: [{
                        key: "flatcar-linux-update.v1.flatcar-linux.net/%s-reboot" % beforeAfter,
                        operator: "In",
                        values: ["true"],
                      }],
                    },
                  ],
                },
              },
            },
            tolerations+: utils.toleratesMaster,
            volumes_+: {
              mons: {
                configMap: {
                  name: "rook-ceph-mon-endpoints",
                  items: [{
                    key: "data",
                    path: "mon-endpoints",
                  }],
                },
              },
              scripts: kube.ConfigMapVolume(this.config) {
                configMap+: {
                  defaultMode: kube.parseOctal("0750"),
                },
              },
            },
            containers_+: {
              check: kube.Container("reboot-check") {
                image: rookCephSystem.deploy.spec.template.spec.containers_.operator.image,
                command: ["/scripts/status-check.sh"],
                env_+: {
                  ROOK_ADMIN_SECRET: {
                    secretKeyRef: {
                      name: "rook-ceph-mon",
                      key: "admin-secret",
                    },
                  },
                  NODE: kube.FieldRef("spec.nodeName"),
                },
                volumeMounts_+: {
                  mons: {mountPath: "/etc/rook"},
                  scripts: {mountPath: "/scripts"},
                },
              },
            },
          },
        },
      },
    },
  },

  before_reboot: $.rebootScript("before") {
    config+: {
      data+: {
        "status-check.sh"+: |||
           # Check if noout option should be set
           checkForNoout() {
               # Fetch the annotations list of the node
               TRIES=0
               until [ $TRIES -eq 10 ]; do
                   if NODE_ANNOTATIONS=$(curl -sSk \
                       --fail \
                       -H "Authorization: Bearer $KUBE_TOKEN" \
                       -H "Accept: application/json" \
                       "https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_PORT_443_TCP_PORT/api/v1/nodes/$NODE" \
                       | jq ".metadata.annotations") ; then
                       echo "$(date) | Node annotations collected, looking for \"ceph-no-noout\" annotation"
                       if [ $(echo "$NODE_ANNOTATIONS" | jq '."ceph-no-noout"') != "null" ] ; then
                           echo "$(date) | Node annotation \"ceph-no-noout\" exists, not setting Ceph noout flag"
                       else
                           echo "$(date) | Node annotation \"ceph-no-noout\" doesn't exist, setting Ceph noout flag"
                           ceph osd set noout
                       fi
                       return 0
                   else
                       echo "$(date) | Kubernetes API server connection error, will retry in 5 seconds..."
                       (( TRIES++ ))
                       /bin/sleep 5
                   fi
               done
               return 1
           }

           preflightCheck

           echo "$(date) | Running the rook toolbox config initiation script..."
           /usr/local/bin/toolbox.sh &

           TRIES=0
           until [ -f /etc/ceph/ceph.conf ]; do
               [ $TRIES -eq 10 ] && { echo "$(date) | No Ceph config found after 10 tries. Exiting ..."; exit 1; }
               echo "$(date) | Waiting for Ceph config (try $TRIES from 10) ..."
               (( TRIES++ ))
               sleep 3
           done

           while true; do
               if checkCephClusterHealth; then
                   if checkForNoout; then
                       if updateNodeRebootAnnotation ceph-before-reboot-check "Reboot confirmed!" ; then
                           while true; do
                               echo "$(date) | Waiting for $NODE to reboot ..."
                               /bin/sleep 30
                           done
                           exit 0
                       else
                           echo "$(date) | Failed updating annotation for $NODE. Exiting."
                           exit 1
                       fi
                   else
                       echo "$(date) | Failed setting the Ceph osd noout flag. Exiting."
                       exit 1
                   fi
               fi
               echo "$(date) | Ceph cluster Health not HEALTH_OK currently. Checking again in 20 seconds ..."
               /bin/sleep 20
           done

        |||,
      },
    },
  },

  after_reboot: $.rebootScript("after") {
    config+: {
      data+: {
        "status-check.sh"+: |||
           # deleteNooutAnnotation deletes the `ceph-no-noout` annotation from `$NODE`
           deleteNooutAnnotation(){
               export PATCH="[{ \"op\": \"remove\", \"path\": \"/metadata/annotations/ceph-no-noout\"}]"
               TRIES=0
               until [ $TRIES -eq 10 ]; do
                   if curl -sSk \
                       --fail \
                       -XPATCH \
                       -H "Authorization: Bearer $KUBE_TOKEN" \
                       -H "Accept: application/json" \
                       -H "Content-Type:application/json-patch+json" \
                       --data "$PATCH" \
                       "https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_PORT_443_TCP_PORT/api/v1/nodes/$NODE"; then
                       echo "$(date) | Annotation \"ceph-no-noout\" from node $NODE removed!"
                       return 0
                   else
                       echo "$(date) | Kubernetes API server connection error, will retry in 5 seconds..."
                       (( TRIES++ ))
                       /bin/sleep 5
                   fi
               done
               return 1
           }

           # Check if noout option should be set
           checkForNoout() {
               # Fetch the annotations list of the node
               TRIES=0
               until [ $TRIES -eq 10 ]; do
                   if NODE_ANNOTATIONS=$(curl -sSk \
                       --fail \
                       -H "Authorization: Bearer $KUBE_TOKEN" \
                       -H "Accept: application/json" \
                       "https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_PORT_443_TCP_PORT/api/v1/nodes/$NODE" \
                       | jq ".metadata.annotations") ; then
                       echo "$(date) | Node annotations collected, looking for \"ceph-no-noout\" annotation"
                       if [ $(echo "$NODE_ANNOTATIONS" | jq '."ceph-no-noout"') != "null" ] ; then
                           echo "$(date) | Node annotation \"ceph-no-noout\" exists, deleting the annotation on node $NODE"
                           deleteNooutAnnotation
                       else
                           echo "$(date) | Node annotation \"ceph-no-noout\" doesn't exist, unsetting Ceph noout flag"
                           ceph osd unset noout
                       fi
                       return 0
                   else
                       echo "$(date) | Kubernetes API server connection error, will retry in 5 seconds..."
                       (( TRIES++ ))
                       /bin/sleep 5
                   fi
               done
               return 1
           }

           preflightCheck

           echo "$(date) | Running the rook toolbox config initiation script..."
           /usr/local/bin/toolbox.sh &

           TRIES=0
           until [ -f /etc/ceph/ceph.conf ]; do
               [ $TRIES -eq 10 ] && { echo "$(date) | No Ceph config found after 10 tries. Exiting ..."; exit 1; }
               echo "$(date) | Waiting for Ceph config (try $TRIES from 10) ..."
               (( TRIES++ ))
               sleep 3
           done

           while true; do
               if checkForNoout; then
                   if updateNodeRebootAnnotation ceph-after-reboot-check "Reboot finished!" ; then
                       echo "$(date) | Reboot from node $NODE completely finished!"
                       exit 0
                   else
                       echo "$(date) | Failed updating annotation for $NODE. Exiting."
                       exit 1
                   fi
               else
                   echo "$(date) | Failed updating ceph noout flag or node annotation. Exiting."
                   exit 1
               fi
           done
        |||,
      },
    },
  },
}
