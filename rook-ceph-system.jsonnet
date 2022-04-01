local kube = import "kube.libsonnet";
local kubecfg = import "kubecfg.libsonnet";
local utils = import "utils.libsonnet";

// Needs at least 1.3.8 to avoid chart syntax error
// -> https://github.com/rook/rook/pull/5660

// renovate: depName=rook-ceph datasource=helm versioning=semver
local chartData = importbin "https://charts.rook.io/release/rook-ceph-v1.3.9.tgz";

local convertCrd(o) = o + {
  assert super.apiVersion == "apiextensions.k8s.io/v1beta1",
  assert super.kind == "CustomResourceDefinition" : "kind is %s" % super.kind,
  apiVersion: "apiextensions.k8s.io/v1",
  [if std.objectHas(o.spec, "version") then "spec"]+: {
    version:: null,
    additionalPrinterColumns:: [],
    validation:: null,
    versions: [{
      name: o.spec.version,
      served: true,
      storage: true,
      [if std.objectHas(o.spec, "additionalPrinterColumns") then "additionalPrinterColumns"]: [
        c + {
          JSONPath:: null,
          jsonPath: c.JSONPath,
        }
        for c in o.spec.additionalPrinterColumns
      ],
      schema: if std.objectHas(o.spec, "validation")
      then o.spec.validation + {
        local recurse(o) = {
          nullable: true,
          type: if "properties" in self then "object" else if "items" in self then "array" else "object",
        } + o + {
          [if "properties" in o then "properties"]: {
            [k]: if k == "storageClassDeviceSets" then {
              type: "array",
              nullable: true,
            } else recurse(o.properties[k])
            for k in std.objectFields(o.properties)
          },
        },
        openAPIV3Schema: recurse(super.openAPIV3Schema) { nullable: false },
      }
      else {
        openAPIV3Schema: {
          type: "object",
          "x-kubernetes-preserve-unknown-fields": true,
        },
      },
    }],
  },
} + {
  local sspec = {
    subresources: null,
    additionalPrinterColumns: [],
    validation: {
      openAPIV3Schema: {
        type: "object",
        "x-kubernetes-preserve-unknown-fields": true,
      },
    },
  } + super.spec,
  spec+: {
    versions: [{
      subresources: sspec.subresources,
      additionalPrinterColumns: [c + {
        JSONPath:: null,
        jsonPath: c.JSONPath,
      } for c in sspec.additionalPrinterColumns],
      schema: sspec.validation,
    } + v for v in super.versions],
    subresources:: null,
    additionalPrinterColumns:: null,
    validation:: null,
  },
};

{
  namespace:: {metadata+: {namespace: "rook-ceph"}},

  chart: kubecfg.parseHelmChart(
    chartData,
    "rook-ceph",
    $.namespace.metadata.namespace,
    {
      nodeSelector: {"kubernetes.io/arch": "amd64"},
      resources: {
        requests: {cpu: "100m", memory: "128Mi"},
      },
      mon: {
        healthCheckInterval: "45s",
        monOutTimeout: "20m", // default 10m
      },
      discover: {nodeAffinity: "kubernetes.io/arch=amd64"},
      enableFlexDriver: true,
      enableDiscoveryDaemon: true,
      agent: {
        flexVolumeDirPath: "/var/lib/kubelet/volumeplugins",
        mountSecurityMode: "Any",
      },
      enableSelinuxRelabeling: false,
    },
  ) + {
    "rook-ceph/templates/deployment.yaml": [o + {
      spec+: {
        template+: {
          spec+: {
            priorityClassName: "high",
            containers: [
              if c.name == "rook-ceph-operator" then c + {
                env+: [
                  {name: "ROOK_ENABLE_FSGROUP", value: "false"},
                ]
              } else c,
              for c in super.containers
            ],
          },
        },
      },
    } for o in super["rook-ceph/templates/deployment.yaml"]],
    "rook-ceph/templates/resources.yaml": [
      convertCrd(o) for o in super["rook-ceph/templates/resources.yaml"]
    ],
  } + {
    [f]: [
      o + {
        [if o.apiVersion == "rbac.authorization.k8s.io/v1beta1" then "apiVersion"]: "rbac.authorization.k8s.io/v1",
      } for o in super[f]
    ]
    for f in [
      "rook-ceph/templates/clusterrole.yaml",
      "rook-ceph/templates/clusterrolebinding.yaml",
      "rook-ceph/templates/role.yaml",
      "rook-ceph/templates/rolebinding.yaml",
    ]
  },

  // Used by rook-ceph.system reboot scripts
  operatorImage:: $.chart["rook-ceph/templates/deployment.yaml"][0].spec.template.spec.containers[0].image,

  local crds = {[c.spec.names.kind]: c for c in $.chart["rook-ceph/templates/resources.yaml"]},
  CephCluster:: utils.crdNew(crds.CephCluster, "v1"),
  CephFilesystem:: utils.crdNew(crds.CephFilesystem, "v1"),
  CephObjectStore:: utils.crdNew(crds.CephObjectStore, "v1"),
  CephObjectStoreUser:: utils.crdNew(crds.CephObjectStoreUser, "v1"),
  CephBlockPool:: utils.crdNew(crds.CephBlockPool, "v1"),
  Volume:: utils.crdNew(crds.Volume, "v1alpha2"),
  CephNFS:: utils.crdNew(crds.CephNFS, "v1"),
  ObjectBucket:: utils.crdNew(crds.ObjectBucket, "v1alpha1"),
  ObjectBucketClaims:: utils.crdNew(crds.ObjectBucketClaims, "v1alpha1"),
}
