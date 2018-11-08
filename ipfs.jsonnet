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
          Announce: [],
          NoAnnounce: [],
          Swarm: [
            "/ip4/0.0.0.0/tcp/4001",
            "/ip4/0.0.0.0/udp/4001/quic",
            "/ip6/::/tcp/4001",
            "/ip6/::/udp/4001/quic",
          ],
        },
        Bootstrap: [
          "/dnsaddr/bootstrap.libp2p.io/ipfs/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
          "/dnsaddr/bootstrap.libp2p.io/ipfs/QmQCU2EcMqAqQPR2i9bChDtGNJchTbq5TbXJJ16u19uLTa",
          "/dnsaddr/bootstrap.libp2p.io/ipfs/QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb",
          "/dnsaddr/bootstrap.libp2p.io/ipfs/QmcZf59bWwK5XFi76CZX8cbJ4BhTzzA3gU1ZjYZcYW3dwt",
          "/ip4/104.131.131.82/tcp/4001/ipfs/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ",
          "/ip4/104.236.179.241/tcp/4001/ipfs/QmSoLPppuBtQSGwKDZT2M73ULpjvfd3aZ6ha4oFGL1KrGM",
          "/ip4/128.199.219.111/tcp/4001/ipfs/QmSoLSafTMBsPKadTEgaXctDQVcqN88CNLHXMkTNwMKPnu",
          "/ip4/104.236.76.40/tcp/4001/ipfs/QmSoLV4Bbm51jM9C4gDYZQ9Cy3U6aXMJDAbzgu2fzaDs64",
          "/ip4/178.62.158.247/tcp/4001/ipfs/QmSoLer265NRgSp2LA3dPaeykiS1J6DifTC88f5uVQKNAd",
          "/ip6/2604:a880:1:20::203:d001/tcp/4001/ipfs/QmSoLPppuBtQSGwKDZT2M73ULpjvfd3aZ6ha4oFGL1KrGM",
          "/ip6/2400:6180:0:d0::151:6001/tcp/4001/ipfs/QmSoLSafTMBsPKadTEgaXctDQVcqN88CNLHXMkTNwMKPnu",
          "/ip6/2604:a880:800:10::4a:5001/tcp/4001/ipfs/QmSoLV4Bbm51jM9C4gDYZQ9Cy3U6aXMJDAbzgu2fzaDs64",
          "/ip6/2a03:b0c0:0:1010::23:1001/tcp/4001/ipfs/QmSoLer265NRgSp2LA3dPaeykiS1J6DifTC88f5uVQKNAd",
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
	      image: "ipfs/go-ipfs:v0.4.18",
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
                initialDelaySeconds: 1 * 60 * 60, // migration can take crazy-long
                timeoutSeconds: 30,
                failureThreshold: 5,
                periodSeconds: 60,
              },
            },
          },
	},
      },
    },
  },
}
