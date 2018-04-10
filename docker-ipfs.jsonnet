local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";

{
  namespace:: {
    metadata+: {namespace: "ipfs"},
  },

  ipfsSvc:: error "need an ipfs service",

  svc: kube.Service("registry") + $.namespace {
    target_pod: $.registry.spec.template,
    spec+: {
      type: "NodePort",
      ports: [{
        name: "registry",
        targetPort: "registry",
        port: 5000,
        nodePort: 30508,
      }],
    },
  },

  registry: kube.Deployment("registry") + $.namespace {
    spec+: {
      template+: {
	spec+: {
          nodeSelector+: utils.archSelector("amd64"),
	  containers_+: {
	    registry: kube.Container("registry") {
	      image: "jvassev/ipfs-registry:0.0.4",
	      env_+: {
		IPFS_GATEWAY: $.ipfsSvc.http_url,
	      },
	      ports_+: {
		registry: {containerPort: 5000, protocol: "TCP"},
	      },
              readinessProbe: {
                httpGet: {path: "/", port: 5000},
              },
	    },
	  },
	},
      },
    },
  },
}
