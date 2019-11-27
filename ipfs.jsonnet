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
	      image: "ipfs/go-ipfs:v0.4.22",
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
