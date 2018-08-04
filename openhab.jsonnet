local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";

{
  namespace:: {metadata+: {namespace: "openhab"}},
  ns: kube.Namespace($.namespace.metadata.namespace),

  svc: kube.Service("openhab") + $.namespace {
    target_pod: $.deploy.spec.template,
    spec+: {
      ports: [
        {name: "http", port: 8080, targetPort: "http"},
        {name: "https", port: 8443, targetPort: "https"},
        {name: "console", port: 8101, targetPort: "console"},
      ],
    },
  },

  config: {
    items: utils.HashedConfigMap("openhab-items") + $.namespace {
      data+: {
        "senseme.items": std.join("\n", [
          'Switch LoungeFanPower "Fan Power" ["Switchable"] { channel="bigassfan:fan:20F85EDA6F34:fan-power" }',
          'Dimmer LoungeFanSpeed "Fan Speed" { channel="bigassfan:fan:20F85EDA6F34:fan-speed" }',
          'Switch LoungeFanAuto "Fan Auto"   { channel="bigassfan:fan:20F85EDA6F34:fan-auto" }',
          'Switch LoungeFanWhoosh "Fan Woosh" { channel="bigassfan:fan:20F85EDA6F34:fan-whoosh" }',
          'String LoungeFanSmartmode "Fan Smart mode" { channel="bigassfan:fan:20F85EDA6F34:fan-smartmode" }',
          'Dimmer LoungeFanSpeedMin "Fan Speed min" { channel="bigassfan:fan:20F85EDA6F34:fan-learn-minspeed" }',
          'Dimmer LoungeFanSpeedMax "Fan Speed max" { channel="bigassfan:fan:20F85EDA6F34:fan-learn-maxspeed" }',
          'String LoungeFanLightPresent { channel="bigassfan:fan:20F85EDA6F34:light-present" }',
          'Switch LoungeFanMotionSensor "Fan Motion sensor" { channel="bigassfan:fan:20F85EDA6F34:motion" }',
          'DateTime LoungeFanTime "Fan Time" { channel="bigassfan:fan:20F85EDA6F34:time" }',
        ]),
        "kodi.items": std.join("\n", [
          'Switch myKodi_mute          "Mute"                   { channel="kodi:kodi:myKodi:mute" }',
          'Dimmer myKodi_volume        "Volume [%d]"            { channel="kodi:kodi:myKodi:volume" }',
          'Player myKodi_control       "Control"                { channel="kodi:kodi:myKodi:control" }',
          'Switch myKodi_stop          "Stop"                   { channel="kodi:kodi:myKodi:stop" }',
          'String myKodi_title         "Title [%s]"             { channel="kodi:kodi:myKodi:title" }',
          'String myKodi_showtitle     "Show title [%s]"        { channel="kodi:kodi:myKodi:showtitle" }',
          'String myKodi_album         "Album [%s]"             { channel="kodi:kodi:myKodi:album" }',
          'String myKodi_artist        "Artist [%s]"            { channel="kodi:kodi:myKodi:artist" }',
          'String myKodi_playuri       "Play URI"               { channel="kodi:kodi:myKodi:playuri" }',
          'String myKodi_playfavorite  "Play favorite"          { channel="kodi:kodi:myKodi:playfavorite" }',
          'String myKodi_pvropentv     "Play PVR TV channel"    { channel="kodi:kodi:myKodi:pvr-open-tv" }',
          'String myKodi_pvropenradio  "Play PVR Radio channel" { channel="kodi:kodi:myKodi:pvr-open-radio" }',
          'String myKodi_pvrchannel    "PVR channel [%s]"       { channel="kodi:kodi:myKodi:pvr-channel" }',
          'String myKodi_notification  "Notification"           { channel="kodi:kodi:myKodi:shownotification" }',
          'String myKodi_input         "Input"                  { channel="kodi:kodi:myKodi:input" }',
          'String myKodi_inputtext     "Inputtext"              { channel="kodi:kodi:myKodi:inputtext" }',
          'String myKodi_systemcommand "Systemcommand"          { channel="kodi:kodi:myKodi:systemcommand" }',
          'String myKodi_mediatype     "Mediatype [%s]"         { channel="kodi:kodi:myKodi:mediatype" }',
          'Image  myKodi_thumbnail                              { channel="kodi:kodi:myKodi:thumbnail" }',
          'Image  myKodi_fanart                                 { channel="kodi:kodi:myKodi:fanart" }',
        ]),
        "xiaomivacuum.items": std.join("\n", [
          'Group  gVac     "Xiaomi Robot Vacuum"      <fan>',
          'Group  gVacStat "Status Details"           <status> (gVac)',
          'Group  gVacCons "Consumables Usage"        <line-increase> (gVac)',
          'Group  gVacDND  "Do Not Disturb Settings"  <moon> (gVac)',
          'Group  gVacHist "Cleaning History"         <calendar> (gVac)',

          'String actionControl  "Vacuum Control"          {channel="miio:vacuum:04EFDA6D:actions#control" }',
          'String actionCommand  "Vacuum Command"          {channel="miio:vacuum:04EFDA6D:actions#commands" }',

          'Number statusBat    "Battery Level [%1.0f%%]" <battery>   (gVac,gVacStat) {channel="miio:vacuum:04EFDA6D:status#battery" }',
          'Number statusArea    "Cleaned Area [%1.0fm²]" <zoom>   (gVac,gVacStat) {channel="miio:vacuum:04EFDA6D:status#clean_area" }',
          'Number statusTime    "Cleaning Time [%1.0f\']" <clock>   (gVac,gVacStat) {channel="miio:vacuum:04EFDA6D:status#clean_time" }',
          'String  statusError    "Error [%s]"  <error>  (gVac,gVacStat) {channel="miio:vacuum:04EFDA6D:status#error_code" }',
          'Number statusFanPow    "Fan Power [%1.0f %%]"  <signal>   (gVacStat) {channel="miio:vacuum:04EFDA6D:status#fan_power" }',
          'Number statusClean    "In Cleaning Status [%1.0f]"   <switch>  (gVacStat) {channel="miio:vacuum:04EFDA6D:status#in_cleaning" }',
          'Switch statusDND    "DND Activated"    (gVacStat) {channel="miio:vacuum:04EFDA6D:status#dnd_enabled" }',
          'Number statusStatus    "Status [%1.0f]"  <status>  (gVacStat) {channel="miio:vacuum:04EFDA6D:status#state"}',

          'Number consumableMain    "Main Brush [%1.0f]"    (gVacCons) {channel="miio:vacuum:04EFDA6D:consumables#main_brush_time"}',
          'Number consumableSide    "Side Brush [%1.0f]"    (gVacCons) {channel="miio:vacuum:04EFDA6D:consumables#side_brush_time"}',
          'Number consumableFilter    "Filter Time[%1.0f]"    (gVacCons) {channel="miio:vacuum:04EFDA6D:consumables#filter_time" }',
          'Number consumableSensor    "Sensor [%1.0f]"    (gVacCons) {channel="miio:vacuum:04EFDA6D:consumables#sensor_dirt_time"}',

          'Switch dndFunction   "DND Function" <moon>   (gVacDND) {channel="miio:vacuum:04EFDA6D:dnd#dnd_function"}',
          'String dndStart   "DND Start Time [%s]" <clock>   (gVacDND) {channel="miio:vacuum:04EFDA6D:dnd#dnd_start"}',
          'String dndEnd   "DND End Time [%s]"   <clock-on>  (gVacDND) {channel="miio:vacuum:04EFDA6D:dnd#dnd_end"}',

          'Number historyArea    "Total Cleaned Area [%1.0fm²]" <zoom>    (gVacHist) {channel="miio:vacuum:04EFDA6D:history#total_clean_area"}',
          'String historyTime    "Total Clean Time [%s]"   <clock>     (gVacHist) {channel="miio:vacuum:04EFDA6D:history#total_clean_time"}',
          'Number historyCount    "Total # Cleanings [%1.0f]"  <office>  (gVacHist) {channel="miio:vacuum:04EFDA6D:history#total_clean_count"}',

          'Switch actionVacuum "Vacuum" (gVac) <fan> {channel="miio:vacuum:04EFDA6D:actions#vacuum"} ["Switchable"]',
        ]),
      },
    },

    sitemaps: utils.HashedConfigMap("openhab-sitemaps") + $.namespace {
      data+: {
        "senseme.sitemap": |||
          sitemap senseme label="LoungeFan" {
            Frame label="Control Lounge Fan" {
              Switch item=LoungeFanPower label="Fan Power [%s]"
              Slider item=LoungeFanSpeed label="Fan Speed [%s %%]"
            }
          }
        |||,
        "kodi.sitemap": |||
          sitemap kodi label="myKodi" {
            Frame label="Kodi" {
              Switch    item=myKodi_mute
              Slider    item=myKodi_volume
              Selection item=myKodi_control mappings=[PLAY='Play', PAUSE='Pause', NEXT='Next', PREVIOUS='Previous', FASTFORWARD='Fastforward', REWIND='Rewind']
              Default   item=myKodi_control
              Switch    item=myKodi_stop
              Text      item=myKodi_title
              Text      item=myKodi_showtitle
              Text      item=myKodi_album
              Text      item=myKodi_artist
              Selection item=myKodi_pvropentv
              Selection item=myKodi_pvropenchannel
              Text      item=myKodi_pvrchannel
              Selection item=myKodi_input mappings=[Up='Up', Down='Down', Left='Left', Right='Right', Select='Select', Back='Back', Home='Home', ContextMenu='ContextMenu', Info='Info']
              Selection item=myKodi_systemcommand mappings=[Shutdown='Herunterfahren', Suspend='Bereitschaft', Reboot='Neustart']
              Text      item=myKodi_mediatype
              Image     item=myKodi_thumbnail
              Image     item=myKodi_fanart
            }
          }
        |||,
      },
    },

    things: utils.HashedConfigMap("openhab-things") + $.namespace {
      data+: {
        "senseme.things": |||
          bigassfan:fan:20F85EDA6F34 [label="Lounge Fan", ipAddress="192.168.0.100", macAddress="20:F8:5E:DA:6F:34"]
        |||,
        "kodi.things": |||
          Thing kodi:kodi:myKodi "Kodi" @ "Living Room" [ipAddress="tellymonster.lan", port=9090] {
            Channels:
            Type pvr-open-tv : pvr-open-tv [
              group="All channels"
            ]
          }
        |||,
      },
    },

    services: utils.HashedConfigMap("openhab-services") + $.namespace {
      data+: {
        "runtime.cfg": std.join("\n", [
          "discovery.bigassfan:background=false",
          "binding.chromecast:callbackUrl=http://%s/" % $.ing.host,
        ]),
        // NB: Only honoured on first start
        addons_:: {
          package: "standard",
          binding_:: ["bigassfan", "kodi", "chromecast"],
          binding: std.join(",", self.binding_),
          ui_:: ["basic", "paper"],
          ui: std.join(",", self.ui_),
          transformation_:: ["exec", "jsonpath", "map", "regex", "scale"],
          transformation: std.join(",", self.transformation_),
          misc_:: ["openhabcloud", "market"],
          misc: std.join(",", self.misc_),
        },
        "addons.cfg": std.join("\n", [
          "%s = %s" % kv for kv in kube.objectItems(self.addons_)])
      },
    },
  },

  ing: utils.Ingress("openhab") + $.namespace {
    host: "openhab.k.lan",
    target_svc: $.svc,
  },

  deploy: kube.StatefulSet("openhab") + $.namespace {
    spec+: {
      replicas: 1,
      volumeClaimTemplates_: {
        userdata: {
          // legacy omitempty annotation workaround - remove when permitted.
          metadata+: {annotations+: {"kubecfg.ksonnet.io/avoid-omitempty": ""}},
          storage: "10G",
        },
      },
      podManagementPolicy: "Parallel",
      template+: {
        spec+: {
          nodeSelector+: utils.archSelector("amd64"),
          terminationGracePeriodSeconds: 5*60,
          // Various UPnP and discovery things assume this.  Would be
          // nice to properly sandbox it, but that means giving all
          // the IoT dongles static addresses :(
          hostNetwork: true,
          volumes_+: {
            //usbacm: kube.HostPathVolume("/dev/ttyACM0"),
            conf_items: kube.ConfigMapVolume($.config.items),
            conf_sitemaps: kube.ConfigMapVolume($.config.sitemaps),
            conf_things: kube.ConfigMapVolume($.config.things),
            conf_services: kube.ConfigMapVolume($.config.services),
            conf: kube.EmptyDirVolume(),
            addons: kube.EmptyDirVolume(),
          },
          securityContext+: {
            // does various setup as root before su'ing to 9001 itself
            //runAsUser: 9001, // openhab
            fsGroup: 9001, // openhab
          },
          initContainers_+: {
            // openhab container entrypoint.sh wants to chmod -R
            // /openhab, so /openhab/conf has to be writeable
            conf: utils.shcmd("conf") {
              shcmd: |||
                find /config /openhab -print || :
                for d in items sitemaps things services; do
                  mkdir -p /openhab/conf/$d
                  cp -v /config/$d/* /openhab/conf/$d/
                  # hey emacs: */
                done
              |||,
              volumeMounts_+: {
                conf_items: {mountPath: "/config/items", readOnly: true},
                conf_sitemaps: {mountPath: "/config/sitemaps", readOnly: true},
                conf_things: {mountPath: "/config/things", readOnly: true},
                conf_services: {mountPath: "/config/services", readOnly: true},
                conf: {mountPath: "/openhab/conf"},
              },
            },
          },
          containers_+: {
            openhab: kube.Container("openhab") {
              image: "openhab/openhab:2.2.0-amd64-alpine",
              command: ["/entrypoint.sh", "su-exec", "openhab", "./start.sh", "run"],
              tty: true,  // Required for odd kafka console thing
              stdin: true,
              ports_+: {
                http: {containerPort: 8080},
                https: {containerPort: 8443},
                // access console via (default user:pass is openhab:habopen):
                //  kubectl exec -ti -n openhab openhab-0 /openhab/runtime/bin/client
                console: {containerPort: 8101},
                lsp: {containerPort: 5007},
              },
              env_+: {
                CRYPTO_POLICY: "unlimited",
                LANGUAGE: "en_AU.UTF-8",
                LANG: self.LANGUAGE,
              },
              volumeMounts_+: {
                //usbacm: {mountPath: "/dev/ttyACM0"},
                conf: {mountPath: "/openhab/conf"},
                userdata: {mountPath: "/openhab/userdata"},
                addons: {mountPath: "/openhab/addons"},
                //.karaf, .java
              },
              readinessProbe: {
                httpGet: {path: "/", port: "http"},
                timeoutSeconds: 5,
                periodSeconds: 30,
              },
              livenessProbe: self.readinessProbe {
                initialDelaySeconds: 10*60, // Loong startup (entrypoint, Java, etc)
              },
            },
          },
        },
      },
    },
  },
}
