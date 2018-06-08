local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";
local kubecfg = import "kubecfg.libsonnet";

{
  namespace:: {
    metadata+: {namespace: "ipfs"},
  },

  ns: kube.Namespace($.namespace.metadata.namespace),

  ing: utils.Ingress("gateway") + $.namespace {
    host: "ipfs.k.lan",
    target_svc: $.svc,
  },

  svc: kube.Service("gateway") + $.namespace {
    target_pod: $.ipfs.spec.template,
    spec+: {
      ports: [
	{name: "gateway", port: 8080},
	{name: "websocket", port: 8081},
      ],
    },
  },

  apiSvc: kube.Service("api") + $.namespace {
    target_pod: $.ipfs.spec.template,
    spec+: {
      ports: [
        {name: "api", port: 5001},
      ],
      // headless service, to try to encourage _some_ session affinity
      type: "ClusterIP",
      clusterIP: "None",  // headless
    },
  },

  ipfs: kube.StatefulSet("ipfs") + $.namespace {
    local this = self,
    spec+: {
      replicas: 1,
      volumeClaimTemplates_: {
        data: {storage: "100G"},
      },
      podManagementPolicy: "Parallel",
      template+: {
        metadata+: {
          annotations+: {
	    "prometheus.io/scrape": "true",
	    "prometheus.io/port": "5001",
	    "prometheus.io/path": "/debug/metrics/prometheus",
          },
        },
	spec+: {
          nodeSelector+: utils.archSelector("amd64"),
          terminationGracePeriodSeconds: 30, // does a clean shutdown on SIGTERM
          securityContext+: {
            // FIXME: ?
            runAsNonRoot: true,  // should run as ipfs
            fsGroup: 100, // "users"
            runAsUser: 1000, // "ipfs"
          },
          initContainers_+:: {
            config: kube.Container("config") {
              image: this.spec.template.spec.containers_.ipfs.image,
              command: ["sh", "-e", "-x", "-c", self.shcmd],
              shcmd:: std.join("; ", [
                "test -e /data/ipfs/config || ipfs init --bits 4096 --empty-repo",
                ] + [
                  "ipfs config %s -- %s %s" % [
                    if std.type(kv[1]) != "string" then "--json" else "",
                    std.escapeStringBash(kv[0]),
                    std.escapeStringBash(std.toString(kv[1]))]
                  for kv in kube.objectItems(self.opts)] + [
                    // FIXME: this is probably better handled with the
                    // correct podSecurity setup...
                    "test $(id -u) -ne 0 || chown -R ipfs /data/ipfs",
                  ]),
              opts:: {
                // Warning: API has no auth/authz!
                "Addresses.API": "/ip4/0.0.0.0/tcp/5001",
                "Addresses.Gateway": "/ip4/0.0.0.0/tcp/8080",
                "Addresses.Swarm": ["/ip4/0.0.0.0/tcp/4001", "/ip6/::/tcp/4001"],
                "Swarm.AddrFilters": [
                  // Everything that is *not* our local POD IP subnet..
	          //"/ip4/10.0.0.0/ipcidr/8",
	          "/ip4/100.64.0.0/ipcidr/10",
	          "/ip4/169.254.0.0/ipcidr/16",
	          "/ip4/172.16.0.0/ipcidr/12",
	          "/ip4/192.0.0.0/ipcidr/24",
	          "/ip4/192.0.0.0/ipcidr/29",
	          "/ip4/192.0.0.8/ipcidr/32",
	          "/ip4/192.0.0.170/ipcidr/32",
	          "/ip4/192.0.0.171/ipcidr/32",
	          "/ip4/192.0.2.0/ipcidr/24",
	          "/ip4/192.168.0.0/ipcidr/16",
	          "/ip4/198.18.0.0/ipcidr/15",
	          "/ip4/198.51.100.0/ipcidr/24",
	          "/ip4/203.0.113.0/ipcidr/24",
	          "/ip4/240.0.0.0/ipcidr/4",
                ],
                "Datastore.StorageMax": this.spec.volumeClaimTemplates_.data.storage,
                "Discovery.MDNS.Enabled": false, // alas :(
                "Gateway.Writable": false,
              },
              env_+: {
		IPFS_LOGGING: "debug",
                IPFS_PATH: "/data/ipfs",
              },
	      volumeMounts_+: {
		data: {mountPath: "/data/ipfs"},
              },
            },
          },
	  containers_+: {
	    ipfs: kube.Container("ipfs") {
	      image: "ipfs/go-ipfs:v0.4.14",
	      env_+: {
		//IPFS_LOGGING: "debug",
                IPFS_PATH: "/data/ipfs",
	      },
	      ports_+: {
		swarm: { containerPort: 4001, protocol: "TCP" },
		swarmu: { containerPort: 4002, protocol: "UDP" },
		// warning: api has no auth/authz!
		api: { containerPort: 5001, protocol: "TCP" },
		gateway: { containerPort: 8080, protocol: "TCP" },
		websocket: { containerPort: 8081, protocol: "TCP" },
	      },
	      volumeMounts_+: {
		data: {mountPath: "/data/ipfs"},
	      },
              readinessProbe: {
                tcpSocket: {port: 4001},
              },
	    },
	  },
	},
      },
    },
  },
}
