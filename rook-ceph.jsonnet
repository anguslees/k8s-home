local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";
local rookCephSystem = import "rook-ceph-system.jsonnet";

{
  namespace:: {metadata+: {namespace: "rook-ceph"}},
  ns: kube.Namespace($.namespace.metadata.namespace),

  // operator picks this up and merges it into rook-ceph-config, which
  // then (eventually) ends up as ceph.conf everywhere.
  configOverride: kube.ConfigMap("rook-config-override") + $.namespace {
    data+: {
      config_:: {
        sections: {
          global: {
            // Avoid mon sync DoSing the sync source
            // https://tracker.ceph.com/issues/42830
            "mon sync max payload size": "4096",
            // Default of 0.05 is too aggressive for my cluster. (seconds)
            "mon clock drift allowed": "0.1",
            // K8s image-gc-low-threshold is 80% - not much point warning
            // before that point. (percent)
            // Really, this should align with {nodefs,imagefs}.available
            // soft limit, and allow absolute size, not just ratio.
            "mon data avail warn": "10",
          },
        },
      },
      config: std.manifestIni(self.config_),
    },
  },

  cluster: rookCephSystem.CephCluster("rook-ceph") + $.namespace {
    spec+: {
      // Note comment in https://github.com/rook/rook/issues/6849:
      // For the time being, stick with v14.2.12 or v15.2.7, and once Rook
      // 1.6 is released, upgrade to at least v14.2.14 or v15.2.9 to get
      // partitions working again. As of 1.6, Rook OSD's implementation for
      // simple scenarios (one OSD = one disk basically) is not using LVM
      // but RAW mode from ceph-volume. See ceph: add raw mode for non-pvc
      // osd #4879 for more details.
      cephVersion: {
        image: "ceph/ceph:v16.2.5", // renovate
      },
      // NB: Delete contents of this dir if recreating Cluster
      dataDirHostPath: "/var/lib/rook",
      disruptionManagement: {
        managePodBudgets: true,
        osdMaintenanceTimeout: 60, // minutes; default=30
      },
      //removeOSDsIfOutAndSafeToRemove: true,
      healthCheck: {
        daemonHealth: {
          mon: {
            disabled: false,
            timeout: "10s", // default 1s
          },
          osd: {
            disabled: false,
            interval: "30s", // default 10s
            timeout: "10s", // default 1s
          },
          mds: {
            disabled: false,
            interval: "30s", // default 10s
            timeout: "10s", // default 1s
          },
        },
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
      /*
      osd: {
        resources: {
          requests: {memory: "400Mi", cpu: "100m"},
        },
      },
      */
      dashboard: {
        enabled: true,
        port: 8443,
        ssl: true,
      },
      monitoring: {
        enabled: false, // Needs prometheus rules CRDs
      },
      network: {
        hostNetwork: false,
        dualStack: true,
      },
      placement: {
        /* TODO: crashes kubecfg.  Understand why.
           I think it looks up schema for 'all' and gets nil, which later crashes
```
strategicpatch/patch.go: handleMapDiff(...) {
        // ...

	subschema, patchMeta, err := schema.LookupPatchMetadataForStruct(key)
        // ^ returns PatchMetaFromOpenAPI{Schema: nil}, nil(?), nil for key="all"

```

        all: {
          nodeAffinity: {
            requiredDuringSchedulingIgnoredDuringExecution: {
              nodeSelectorTerms+: [{
                matchExpressions: [{
                  key: "kubernetes.io/arch",
                  operator: "In",
                  // TODO: Upstream images support arm64/v8 too
                  values: std.set(["amd64"]),
                }],
              }],
            },
          },
        },
*/
      },
      storage: {
        useAllNodes: false,
        useAllDevices: false,
        //directories: [{path: "/var/lib/rook"}],
        nodes_:: {
          //name: {devices: []}
        },
        nodes: kube.mapToNamedList(self.nodes_),
        storageClassDeviceSets_:: {
          set1: {
            count: 4,
            portable: false,
            tuneDeviceClass: true,
            placement: {
              podAntiAffinity: {
                local selector = {
                  matchLabels: {
                    app: "rook-ceph-osd",
                    rook_cluster: "rook-ceph",
                  },
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
                      topologyKey: "topology.kubernetes.io/zone",
                    },
                  },
                ],
              },
            },
            volumeClaimTemplates: [{
              metadata: {name: "data"},
              spec: {
                resources: {requests: {storage: "9Gi"}},
                storageClassName: "local-disk",
                volumeMode: "Block",
                accessModes: ["ReadWriteOnce"],
              },
            }],
          },
        },
        // FIXME: re-enable in newer rook
        storageClassDeviceSets: kube.mapToNamedList(self.storageClassDeviceSets_),
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
            pathType: "Prefix",
            backend: {
              service: {
                name: "rook-ceph-mgr-dashboard",
                port: {name: "https-dashboard"},
              },
            },
          }],
        },
      }],
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
    provisioner: "rook-ceph.rbd.csi.ceph.com",
    allowVolumeExpansion: true,
    parameters: {
      clusterID: $.cluster.metadata.namespace,
      pool: $.replicapool.metadata.name,
      imageFormat: "2",
      imageFeatures: "layering",

      "csi.storage.k8s.io/provisioner-secret-name": "rook-csi-rbd-provisioner",
      "csi.storage.k8s.io/provisioner-secret-namespace": self.clusterID,
      "csi.storage.k8s.io/controller-expand-secret-name": "rook-csi-rbd-provisioner",
      "csi.storage.k8s.io/controller-expand-secret-namespace": self.clusterID,
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
        resources: {
          requests: {cpu: "100m", memory: "128Mi"},
        },
        placement: {
          podAntiAffinity: {
            local selector = {
              matchLabels: {
                app: "rook-ceph-mds",
                rook_file_system: this.metadata.name,
              },
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
                  topologyKey: "topology.kubernetes.io/zone",
                },
              },
            ],
          },
        },
      },
    },
  },

  cephfsCsi: kube.StorageClass("csi-cephfs") {
    provisioner: "rook-ceph.cephfs.csi.ceph.com",
    allowVolumeExpansion: true,
    parameters: {
      clusterID: $.cluster.metadata.namespace,
      fsName: $.filesystem.metadata.name,
      pool: self.fsName + "-data0",
      "csi.storage.k8s.io/provisioner-secret-name": "rook-csi-cephfs-provisioner",
      "csi.storage.k8s.io/provisioner-secret-namespace": self.clusterID,
      "csi.storage.k8s.io/controller-expand-secret-name": "rook-csi-cephfs-provisioner",
      "csi.storage.k8s.io/controller-expand-secret-namespace": self.clusterID,
      "csi.storage.k8s.io/node-stage-secret-name": "rook-csi-cephfs-node",
      "csi.storage.k8s.io/node-stage-secret-namespace": self.clusterID,
    },
  },

  toolbox: kube.Deployment("rook-ceph-tools") + $.namespace {
    spec+: {
      template+: {
        spec+: {
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
            cfg: kube.EmptyDirVolume(),
          },
          containers_+: {
            toolbox: kube.Container("toolbox") {
              image: $.cluster.spec.cephVersion.image,
              command: ["/bin/bash", "-c", self.script_],
              script_:: |||
                #!/bin/bash

                CEPH_CONFIG="/etc/ceph/ceph.conf"
                MON_CONFIG="/etc/rook/mon-endpoints"
                KEYRING_FILE="/etc/ceph/keyring"

                # create a ceph config file in its default location so ceph/rados tools can be used
                # without specifying any arguments
                write_endpoints() {
                  endpoints=$(cat ${MON_CONFIG})
                  # filter out the mon names
                  # external cluster can have numbers or hyphens in mon names, handling them in regex
                  # shellcheck disable=SC2001
                  mon_endpoints=$(echo "${endpoints}"| sed 's/[a-z0-9_-]\+=//g')
                  DATE=$(date)
                  echo "$DATE writing mon endpoints to ${CEPH_CONFIG}: ${endpoints}"
                    cat <<EOF > ${CEPH_CONFIG}
                [global]
                mon_host = ${mon_endpoints}
                [client.admin]
                keyring = ${KEYRING_FILE}
                EOF
                }
                # watch the endpoints config file and update if the mon endpoints ever change
                watch_endpoints() {
                  # get the timestamp for the target of the soft link
                  real_path=$(realpath ${MON_CONFIG})
                  initial_time=$(stat -c %Z "${real_path}")
                  while true; do
                    real_path=$(realpath ${MON_CONFIG})
                    latest_time=$(stat -c %Z "${real_path}")
                    if [[ "${latest_time}" != "${initial_time}" ]]; then
                      write_endpoints
                      initial_time=${latest_time}
                    fi
                    sleep 10
                  done
                }
                # create the keyring file
                cat <<EOF > ${KEYRING_FILE}
                [${ROOK_CEPH_USERNAME}]
                key = ${ROOK_CEPH_SECRET}
                EOF
                # write the initial config file
                write_endpoints
                # continuously update the mon endpoints if they fail over
                watch_endpoints
              |||,
              tty: true,
              stdin: true,
              securityContext: {
                runAsNonRoot: true,
                runAsUser: 2016,
                runAsGroup: 2016,
              },
              env_+: {
                ROOK_CEPH_USERNAME: {
                  secretKeyRef: {
                    name: "rook-ceph-mon",
                    key: "ceph-username",
                  },
                },
                ROOK_CEPH_SECRET: {
                  secretKeyRef: {
                    name: "rook-ceph-mon",
                    key: "ceph-secret",
                  },
                },
              },
              volumeMounts_+: {
                cfg: {mountPath: "/etc/ceph"},
                mons: {mountPath: "/etc/rook"},
              },
            },
          },
        },
      },
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

           CEPH_CONFIG="/etc/ceph/ceph.conf"
           MON_CONFIG="/etc/rook/mon-endpoints"
           KEYRING_FILE="/etc/ceph/keyring"

           # create a ceph config file in its default location so ceph/rados tools can be used
           # without specifying any arguments
           write_endpoints() {
             endpoints=$(cat ${MON_CONFIG})
             # filter out the mon names
             # external cluster can have numbers or hyphens in mon names, handling them in regex
             # shellcheck disable=SC2001
             mon_endpoints=$(echo "${endpoints}"| sed 's/[a-z0-9_-]\+=//g')
             DATE=$(date)
             echo "$DATE writing mon endpoints to ${CEPH_CONFIG}: ${endpoints}"
               cat <<EOF > ${CEPH_CONFIG}
           [global]
           mon_host = ${mon_endpoints}
           [client.admin]
           keyring = ${KEYRING_FILE}
           EOF
           }
           # watch the endpoints config file and update if the mon endpoints ever change
           watch_endpoints() {
             # get the timestamp for the target of the soft link
             real_path=$(realpath ${MON_CONFIG})
             initial_time=$(stat -c %Z "${real_path}")
             while true; do
               real_path=$(realpath ${MON_CONFIG})
               latest_time=$(stat -c %Z "${real_path}")
               if [[ "${latest_time}" != "${initial_time}" ]]; then
                 write_endpoints
                 initial_time=${latest_time}
               fi
               sleep 10
             done
           }
           # create the keyring file
           cat <<EOF > ${KEYRING_FILE}
           [${ROOK_CEPH_USERNAME}]
           key = ${ROOK_CEPH_SECRET}
           EOF
           # write the initial config file
           write_endpoints
           # continuously update the mon endpoints if they fail over
           watch_endpoints &

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
              cfg: kube.EmptyDirVolume(),
              scripts: kube.ConfigMapVolume(this.config) {
                configMap+: {
                  defaultMode: kube.parseOctal("0755"),
                },
              },
            },
            containers_+: {
              check: kube.Container("reboot-check") {
                image: $.cluster.spec.cephVersion.image,
                command: ["bash", "/scripts/status-check.sh"],
                env_+: {
                  ROOK_CEPH_USERNAME: {
                    secretKeyRef: {
                      name: "rook-ceph-mon",
                      key: "ceph-username",
                    },
                  },
                  ROOK_CEPH_SECRET: {
                    secretKeyRef: {
                      name: "rook-ceph-mon",
                      key: "ceph-secret",
                    },
                  },
                  NODE: kube.FieldRef("spec.nodeName"),
                },
                volumeMounts_+: {
                  cfg: {mountPath: "/etc/ceph"},
                  mons: {mountPath: "/etc/rook"},
                  scripts: {mountPath: "/scripts"},
                },
                securityContext: {
                  runAsNonRoot: true,
                  runAsUser: 2016,
                  runAsGroup: 2016,
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
