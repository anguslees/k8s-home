local kube = import "kube.libsonnet";
local kubecfg = import "kubecfg.libsonnet";
local utils = import "utils.libsonnet";

// https://github.com/kubernetes-sigs/kube-storage-version-migrator/tree/master/manifests

local crds = kubecfg.parseYaml(|||
   apiVersion: apiextensions.k8s.io/v1
   kind: CustomResourceDefinition
   metadata:
     name: storageversionmigrations.migration.k8s.io
     annotations:
       "api-approved.kubernetes.io": "https://github.com/kubernetes/community/pull/2524"
   spec:
     group: migration.k8s.io
     names:
       kind: StorageVersionMigration
       listKind: StorageVersionMigrationList
       plural: storageversionmigrations
       singular: storageversionmigration
     scope: Cluster
     preserveUnknownFields: false
     versions:
     - name: v1alpha1
       served: true
       storage: true
       subresources:
         status: {}
       schema:
         openAPIV3Schema:
           description: StorageVersionMigration represents a migration of stored data
             to the latest storage version.
           type: object
           properties:
             apiVersion:
               description: 'APIVersion defines the versioned schema of this representation
                 of an object. Servers should convert recognized schemas to the latest
                 internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources'
               type: string
             kind:
               description: 'Kind is a string value representing the REST resource this
                 object represents. Servers may infer this from the endpoint the client
                 submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds'
               type: string
             metadata:
               type: object
             spec:
               description: Specification of the migration.
               type: object
               required:
               - resource
               properties:
                 continueToken:
                   description: The token used in the list options to get the next chunk
                     of objects to migrate. When the .status.conditions indicates the
                     migration is "Running", users can use this token to check the progress
                     of the migration.
                   type: string
                 resource:
                   description: The resource that is being migrated. The migrator sends
                     requests to the endpoint serving the resource. Immutable.
                   type: object
                   properties:
                     group:
                       description: The name of the group.
                       type: string
                     resource:
                       description: The name of the resource.
                       type: string
                     version:
                       description: The name of the version.
                       type: string
             status:
               description: Status of the migration.
               type: object
               properties:
                 conditions:
                   description: The latest available observations of the migration's
                     current state.
                   type: array
                   items:
                     description: Describes the state of a migration at a certain point.
                     type: object
                     required:
                     - status
                     - type
                     properties:
                       lastUpdateTime:
                         description: The last time this condition was updated.
                         type: string
                         format: date-time
                       message:
                         description: A human readable message indicating details about
                           the transition.
                         type: string
                       reason:
                         description: The reason for the condition's last transition.
                         type: string
                       status:
                         description: Status of the condition, one of True, False, Unknown.
                         type: string
                       type:
                         description: Type of the condition.
                         type: string
   ---
   apiVersion: apiextensions.k8s.io/v1
   kind: CustomResourceDefinition
   metadata:
     annotations:
       api-approved.kubernetes.io: https://github.com/kubernetes/enhancements/pull/747
     name: storagestates.migration.k8s.io
   spec:
     group: migration.k8s.io
     names:
       kind: StorageState
       listKind: StorageStateList
       plural: storagestates
       singular: storagestate
     preserveUnknownFields: false
     scope: Cluster
     versions:
     - name: v1alpha1
       schema:
         openAPIV3Schema:
           description: The state of the storage of a specific resource.
           properties:
             apiVersion:
               description: 'APIVersion defines the versioned schema of this representation
                 of an object. Servers should convert recognized schemas to the latest
                 internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources'
               type: string
             kind:
               description: 'Kind is a string value representing the REST resource this
                 object represents. Servers may infer this from the endpoint the client
                 submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds'
               type: string
             metadata:
               properties:
                 name:
                   description: name must be "<.spec.resource.resouce>.<.spec.resource.group>".
                   type: string
               type: object
             spec:
               description: Specification of the storage state.
               properties:
                 resource:
                   description: The resource this storageState is about.
                   properties:
                     group:
                       description: The name of the group.
                       type: string
                     resource:
                       description: The name of the resource.
                       type: string
                   type: object
               type: object
             status:
               description: Status of the storage state.
               properties:
                 currentStorageVersionHash:
                   description: The hash value of the current storage version, as shown
                     in the discovery document served by the API server. Storage Version
                     is the version to which objects are converted to before persisted.
                   type: string
                 lastHeartbeatTime:
                   description: LastHeartbeatTime is the last time the storage migration
                     triggering controller checks the storage version hash of this resource
                     in the discovery document and updates this field.
                   format: date-time
                   type: string
                 persistedStorageVersionHashes:
                   description: The hash values of storage versions that persisted instances
                     of spec.resource might still be encoded in. "Unknown" is a valid
                     value in the list, and is the default value. It is not safe to upgrade
                     or downgrade to an apiserver binary that does not support all versions
                     listed in this field, or if "Unknown" is listed. Once the storage
                     version migration for this resource has completed, the value of
                     this field is refined to only contain the currentStorageVersionHash.
                     Once the apiserver has changed the storage version, the new storage
                     version is appended to the list.
                   items:
                     type: string
                   type: array
               type: object
           type: object
       served: true
       storage: true
       subresources:
         status: {}
   ...
|||);

{
  namespace:: {metadata+: {namespace: "storage-version-migrator"}},
  ns: kube.Namespace($.namespace.metadata.namespace),

  crds: crds,

  /*  Duplicates trigger functionality ??
  initializer: {
    sa: kube.ServiceAccount("initializer") + $.namespace,

    role: kube.ClusterRole("storage-version-migrator-initializer") {
      rules: [
        {
          apiGroups: ["migration.k8s.io"],
          resources: ["storageversionmigrations"],
          verbs: ["create"],
        },
        {
          apiGroups: ["apiregistration.k8s.io"],
          resources: ["apiservices"],
          verbs: ["list"],
        },
      ],
    },

    binding: kube.ClusterRoleBinding("storage-version-migrator-initializer") {
      subjects_+: [$.initializer.sa],
      roleRef_: $.initializer.role,
    },

    crdCreator: kube.ClusterRole("storage-version-migrator-crd-creator") {
      rules: [{
        apiGroups: ["apiextensions.k8s.io"],
        resources: ["customresourcedefinitions"],
        verbs: ["create", "delete", "get", "list"]
      }],
    },

    crdCreatorBinding: kube.ClusterRoleBinding("storage-version-migrator-crd-creator") {
      subjects_+: [$.initializer.sa],
      roleRef_: $.initializer.crdCreator,
    },

    job: kube.Job("initializer") + $.namespace {
      spec+: {
        template+: {
          spec+: {
            nodeSelector+: utils.archSelector("amd64"),
            restartPolicy: "Never",
            serviceAccountName: $.initializer.sa.metadata.name,
            containers_+: {
              initializer: kube.Container("initializer") {
                image: "registry.k8s.io/storage-migrator/storage-version-migration-initializer:v0.0.5", // renovate
              },
            },
          },
        },
      },
    },
  },
  */

  trigger: {
    sa: kube.ServiceAccount("trigger") + $.namespace,

    role: kube.ClusterRole("storage-version-migrator-trigger") {
      rules: [
        {
          apiGroups: ["migration.k8s.io"],
          resources: ["storagestates"],
          verbs: ["watch", "get", "list", "delete", "create", "update"],
        },
        {
          apiGroups: ["migration.k8s.io"],
          resources: ["storagestates/status"],
          verbs: ["update"],
        },
        {
          apiGroups: ["migration.k8s.io"],
          resources: ["storageversionmigrations"],
          verbs: ["watch", "get", "list", "delete", "create"],
        },
      ],
    },

    binding: kube.ClusterRoleBinding("storage-version-migrator-trigger") {
      subjects_+: [$.trigger.sa],
      roleRef_: $.trigger.role,
    },

    deploy: kube.Deployment("trigger") + $.namespace {
      spec+: {
        template+: {
          spec+: {
            serviceAccountName: $.trigger.sa.metadata.name,
            nodeSelector+: utils.archSelector("amd64"),
            containers_+: {
              trigger: kube.Container("trigger") {
                image: "registry.k8s.io/storage-migrator/storage-version-migration-trigger:v0.0.5", // renovate
                livenessProbe: {
                  httpGet: {path: "/healthz", port: 2113, scheme: "HTTP"},
                  initialDelaySeconds: 10,
                  failureThreshold: 3,
                  timeoutSeconds: 60,
                },
              },
            },
          },
        },
      },
    },
  },

  migrator: {
    sa: kube.ServiceAccount("migrator") + $.namespace,

    binding: kube.ClusterRoleBinding("storage-version-migrator-migrator") {
      subjects_+: [$.migrator.sa],
      roleRef: {
        kind: "ClusterRole",
        name: "cluster-admin",  // eek.
        apiGroup: "rbac.authorization.k8s.io",
      },
    },

    deploy: kube.Deployment("migrator") + $.namespace {
      spec+: {
        template+: {
          spec+: {
            nodeSelector+: utils.archSelector("amd64"),
            serviceAccountName: $.migrator.sa.metadata.name,
            containers_+: {
              migrator: kube.Container("migrator") {
                image: "registry.k8s.io/storage-migrator/storage-version-migration-migrator:v0.0.5", // renovate
                command: ["/migrator"],
                args_+: {
                  v: 2,
                  logtostderr: true,
                  "kube-api-qps": 40,
                  "kube-api-burst": 1000,
                },
                livenessProbe: {
                  httpGet: {path: "/healthz", port: 2112, scheme: "HTTP"},
                  initialDelaySeconds: 10,
                  timeoutSeconds: 60,
                  failureThreshold: 3,
                },
              },
            },
          },
        },
      },
    },
  },
}
