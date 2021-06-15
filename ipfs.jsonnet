local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";
local kubecfg = import "kubecfg.libsonnet";

{
  namespace:: {
    metadata+: {namespace: "ipfs"},
  },

  ns: kube.Namespace($.namespace.metadata.namespace),

  // Also: there's a webui.  webui is hardcoded to use localhost (see
  // open issues), so works best with port-forward:
  //  kubectl -n ipfs port-forward ipfs-0 5001:5001
  //  sensible-browser http://localhost:5001/webui

  // NB: we run with Gateway.Writable=true, so ensure the
  // gateway port is not open to the public
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

  // To publish content to ipfs efficiently, your firewall should
  // port-forward 4001/tcp to this IP.
  swarmSvc: kube.Service("swarm") + $.namespace {
    metadata+: {
      annotations+: {
        "metallb.universe.tf/allow-shared-ip": "ipfs-swarm",
      },
    },
    target_pod: $.ipfs.spec.template,
    spec+: {
      type: "LoadBalancer",
      ports: [
        {name: "swarm", port: 4001, protocol: "TCP"},
      ],
    },
  },
  // "cannot create an external load balancer with mix protocols"
  swarmuSvc: kube.Service("swarmu") + $.namespace {
    metadata+: {
      annotations+: {
        "metallb.universe.tf/allow-shared-ip": "ipfs-swarm",
      },
    },
    target_pod: $.ipfs.spec.template,
    spec+: {
      type: "LoadBalancer",
      ports: [
        {name: "swarm", port: 4001, protocol: "UDP"},
      ],
    },
  },

  conf: utils.SealedSecret("ipfs") + $.namespace {
    // If data_ is changed, reseal with ./seal.sh ipfs-secret.jsonnet
    data_:: {
      conf:: {
        API: {
          HTTPHeaders: {},
        },
        Addresses: {
          API: "/ip4/0.0.0.0/tcp/5001",
          Gateway: "/ip4/0.0.0.0/tcp/8080",
          Announce: [
            "/dns4/%s/tcp/4001" % [$.swarmSvc.host],
            "/dns4/%s/udp/4001/quic" % [$.swarmuSvc.host],
            "/dns4/webhooks.oldmacdonald.farm/tcp/4001",
            "/dns4/webhooks.oldmacdonald.farm/udp/4001/quic",
            "/ip4/127.0.0.1/tcp/4001",
            "/ip4/127.0.0.1/udp/4001/quic",
          ],
          NoAnnounce: [],
          Swarm: [
            "/ip4/0.0.0.0/tcp/4001",
            "/ip4/0.0.0.0/udp/4001/quic",
            "/ip6/::/tcp/4001",
            "/ip6/::/udp/4001/quic",
          ],
        },
        Bootstrap: [
          "/dnsaddr/bootstrap.libp2p.io/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
          "/dnsaddr/bootstrap.libp2p.io/p2p/QmQCU2EcMqAqQPR2i9bChDtGNJchTbq5TbXJJ16u19uLTa",
          "/dnsaddr/bootstrap.libp2p.io/p2p/QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb",
          "/dnsaddr/bootstrap.libp2p.io/p2p/QmcZf59bWwK5XFi76CZX8cbJ4BhTzzA3gU1ZjYZcYW3dwt",
          "/ip4/104.131.131.82/tcp/4001/p2p/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ",
          "/ip4/104.236.179.241/tcp/4001/p2p/QmSoLPppuBtQSGwKDZT2M73ULpjvfd3aZ6ha4oFGL1KrGM",
          "/ip4/128.199.219.111/tcp/4001/p2p/QmSoLSafTMBsPKadTEgaXctDQVcqN88CNLHXMkTNwMKPnu",
          "/ip4/104.236.76.40/tcp/4001/p2p/QmSoLV4Bbm51jM9C4gDYZQ9Cy3U6aXMJDAbzgu2fzaDs64",
          "/ip4/178.62.158.247/tcp/4001/p2p/QmSoLer265NRgSp2LA3dPaeykiS1J6DifTC88f5uVQKNAd",
          "/ip4/104.131.131.82/udp/4001/quic/p2p/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ",
          "/ip6/2604:a880:1:20::203:d001/tcp/4001/p2p/QmSoLPppuBtQSGwKDZT2M73ULpjvfd3aZ6ha4oFGL1KrGM",
          "/ip6/2400:6180:0:d0::151:6001/tcp/4001/p2p/QmSoLSafTMBsPKadTEgaXctDQVcqN88CNLHXMkTNwMKPnu",
          "/ip6/2604:a880:800:10::4a:5001/tcp/4001/p2p/QmSoLV4Bbm51jM9C4gDYZQ9Cy3U6aXMJDAbzgu2fzaDs64",
          "/ip6/2a03:b0c0:0:1010::23:1001/tcp/4001/p2p/QmSoLer265NRgSp2LA3dPaeykiS1J6DifTC88f5uVQKNAd",
        ],
        Datastore: {
          BloomFilterSize: 0,
          GCPeriod: "1h",
          HashOnRead: false,
          Spec: {
            mounts: [
              {
                child: {
                  path: "blocks",
                  shardFunc: "/repo/flatfs/shard/v1/next-to-last/2",
                  sync: true,
                  type: "flatfs",
                },
                mountpoint: "/blocks",
                prefix: "flatfs.datastore",
                type: "measure",
              },
              {
                child: {
                  compression: "none",
                  path: "datastore",
                  type: "levelds",
                },
                mountpoint: "/",
                prefix: "leveldb.datastore",
                type: "measure",
              },
            ],
            type: "mount",
          },
          StorageGCWatermark: 90,
          StorageMax: "100G",
        },
        Discovery: {
          MDNS: {
            Enabled: false,
            Interval: 10,
          },
        },
        Experimental: {
          FilestoreEnabled: false,
          Libp2pStreamMounting: false,
          ShardingEnabled: false,
          UrlstoreEnabled: false,
          QUIC: true,
        },
        Gateway: {
          HTTPHeaders: {
            "Access-Control-Allow-Headers": [
              "X-Requested-With",
              "Range",
            ],
            "Access-Control-Allow-Methods": [
              "GET",
            ],
            "Access-Control-Allow-Origin": [
              "*",
            ],
          },
          PathPrefixes: [],
          RootRedirect: "",
          Writable: false,
        },
        Identity: {
          // PeerID is not secret, and is generated on the fly from
          // PrivKey.  Makes sense to keep the two together however.
          PeerID: error "secret! value not overridden",
          PrivKey: error "secret! value not overridden",
        },
        Ipns: {
          RecordLifetime: "",
          RepublishPeriod: "",
          ResolveCacheSize: 128,
        },
        Mounts: {
          FuseAllowOther: false,
          IPFS: "/ipfs",
          IPNS: "/ipns",
        },
        Reprovider: {
          Interval: "12h",
          Strategy: "all",
        },
        Routing: {
          Type: "",
        },
        Swarm: {
          AddrFilters: [
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
          ConnMgr: {
            GracePeriod: "1m",
            // High/Low water reduced to limit impact
            // on my slow ADSL connection :(
            HighWater: 300,
            LowWater: 100,
            Type: "basic",
          },
          DisableBandwidthMetrics: false,
          DisableNatPortMap: false,
          DisableRelay: false,
          EnableRelayHop: false
        },
      },
      config: kubecfg.manifestJson(self.conf),
    },
    spec+: {
      data: "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",
    },
  },

  ipfs: kube.StatefulSet("ipfs") + $.namespace {
    local this = self,
    spec+: {
      replicas: 1,
      volumeClaimTemplates_: {
        data: {
          storageClass: "ceph-block",
          storage: $.conf.data_.conf.Datastore.StorageMax,
        },
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
            runAsNonRoot: true,  // should run as ipfs
            fsGroup: 100, // "users"
            runAsUser: 1000, // "ipfs"
            sysctls_:: {
              // Required for decent QUIC performance
              //'net.core.rmem_default': 2 * 1024 * 1024, // bytes
              // Not on the default allowed list.  TODO: add .. or something.
              //'net.core.rmem_max': 2 * 1024 * 1024,
            },
            sysctls: [
              {name: kv[0], value: std.toString(kv[1])}
              for kv in kube.objectItems(self.sysctls_)
            ],
          },
          volumes_+: {
            conf: kube.SecretVolume($.conf),
          },
          initContainers_+:: {
            init: kube.Container("init") {
              image: this.spec.template.spec.containers_.ipfs.image,
              command: ["sh", "-x", "-e", "-c", self.shcmd],
              shcmd:: |||
                ls -l $IPFS_PATH
                if [ ! -e $IPFS_PATH/version ]; then
                  rm -f $IPFS_PATH/config
                  ipfs init --empty-repo
                fi
              |||,
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
	      image: "ipfs/go-ipfs:v0.7.0",
              command: ["start_ipfs", "daemon", "--migrate"],
	      env_+: {
		//IPFS_LOGGING: "debug",
                IPFS_PATH: "/data/ipfs",
	      },
	      ports_+: {
		swarm: { containerPort: 4001, protocol: "TCP" },
		swarmu: { containerPort: 4001, protocol: "UDP" },
		// warning: api has no auth/authz!
		api: { containerPort: 5001, protocol: "TCP" },
		gateway: { containerPort: 8080, protocol: "TCP" },
		websocket: { containerPort: 8081, protocol: "TCP" },
	      },
	      volumeMounts_+: {
                conf: {
                  mountPath: "/data/ipfs/config",
                  subPath: "config",
                  readOnly: true,
                },
		data: {mountPath: "/data/ipfs"},
	      },
              resources+: {
                requests: {cpu: "100m", memory: "700Mi"},
                limits: {cpu: "1", memory: "800Mi"},
              },
              readinessProbe: {
                tcpSocket: {port: 4001},
              },
              livenessProbe: self.readinessProbe {
                timeoutSeconds: 30,
                failureThreshold: 5,
                periodSeconds: 30,
              },
              startupProbe: self.livenessProbe {
                failureThreshold: 60 * 60 / self.periodSeconds, // migration can take crazy-long
              },
            },
          },
	},
      },
    },
  },
}
