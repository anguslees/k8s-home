local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";

{
  namespace:: {
    metadata+: {namespace: "ipfs"},
  },

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
              image: "anguslees/ipdr:latest", // renovate
              command: ["ipdr", "server"],
              args_+: {
                // Unsupported - despite docs
                //"ipfs-gateway": "http://api.ipfs:5001/",
              },
	      ports_+: {
		registry: {containerPort: 5000, protocol: "TCP"},
	      },
              readinessProbe: {
                httpGet: {path: "/health", port: 5000},
              },
              livenessProbe: self.readinessProbe,
	    },
	  },
	},
      },
    },
  },
}
