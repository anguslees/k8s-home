local kube = import "kube.libsonnet";
local kubecfg = import "kubecfg.libsonnet";
local utils = import "utils.libsonnet";

// cupsd cares about which hostname you use in URLs, so this has to
// match cups config.
local cups_server = "mongrel";

{
  namespace:: {metadata+: {namespace: "printing"}},

  ns: kube.Namespace($.namespace.metadata.namespace),

  serviceAccount: kube.ServiceAccount("gcp-connector") + $.namespace,

  config: utils.SealedSecret("google-cloud-print-connector") + $.namespace {
    // If data_ is changed, reseal with ./seal.sh gcp-connector-secret.jsonnet
    data_+: {
      config:: {
        xmpp_jid: error "secret! xmpp_jid not overridden",
        robot_refresh_token: error "secret! robot_refresh_token not overridden",
        proxy_name: error "secret! proxy_name not overridden",

        local_printing_enable: false, // requires avahi
        cloud_printing_enable: true,

        copy_printer_info_to_display_name: false, // Use cups name as name
        printer_blacklist: ["pdfprint"],
        cups_vendor_ppd_options: ["all"],

        log_level: "INFO",
      },
      "gcp-cups-connector.config.json": kubecfg.manifestJson(self.config),
    },
    spec+: {
      data: "AgAqB19npYU6Upl60Iu+RCKe9oQka0yowEL4QUEGrfgh9RFzz7ROVfXulV/Q/oJJH1ZRSsiqyDnfqpQxoIfMWbx6ESlqf/Oab15KSUrMuUGzUsex1sufZqdBf+10CpLrew2/ZHyxaUBU0YJ8zZz2Dj3VtMCn03xFEf5pwMY981jG83SfdVba5encvllv+w4nlzz9/loNDyetpDnr9G+ww5+9HFS2mAU8ythi94BLkjdqXZmt6kKTG6mtxWNzI51IiABW4s8P7Xi9Lmm+uvqGzilbxD1EqiK4DZjnJjec72HbaET1Hpl26OD03DK6sUhIQmJ6p88IxQWprjeHxKFQ1bXSysCd/v9AJscveTy8s3iGC2/tpnq7hRZSZG4FOidlsyeiOk8oHzJaIFu+6yaBen7+IvwcTjT0b2T10Osoj3glPJtjAebDGL971U7rf5dlzhlz7eocyfJDys8O+s9nbt+KbDIsDNS8mofWdMtbNw3pBUpVfqmOuI4gmoMw0ZTK4buhuNrkhkurl5j95euXnd2dL9qMqyd+aAdMxBPbNp44jVqwWdLpcFLcmLAl3ZI9AT7MllKFbQdd4KBA593fpbV1oDSdMZkt2xKJL4v1AckdP6oOCBQljRJkgmn8pQxK7GsHf4+6MrxcOHq8FeVQuxDK3HjAzHtAGm80zSPVPNu2PABZDVtRsdGaXZNNEkBWB+l7fmadPG5kJMYMHH6FA7DknsZ+whYWZvLujcxzn1FE57wx6TdICERfeSAUbXYxhXGRV9RWY22CuRl+tsRoG9sT6SWMQWivgYcgM0yzp7q0+sEkPJL/TPnJmPJhBdVxmsDaLnQg11ZKvB0ipq8t6yvATu5ap8v34xH//edWelAcognjU/HWMqXEtN860QiHW/bxv1u4MN5efzcREoTIz3mrW0eQ74Y9NhVDZDacpGA9BdgxVuB5LHpzoJ2/LGNO1jiAPX1x+lFqICOSedW+YDfYDegxNsJSDd4rays7Kqu5/uwotDh2L4opk8E7/XpBNDcUnVaNj2BtilTbuFi6OiwEPPt2scffOD9DYTH+GJG/IeUW8gcIf1iQjLJnPmkpyRn1RYi5w/n/Bia4aZZLcs5Ay5bZ6LD3q9KZcrn6VDQgeDrZXCG8TNdwM/5iaj2VT+eUUGJ5wJKb7UEuF5iOUJbJOUtwwt2x8NfTXxdi5lWeefhOnthmJcbpGplKIaWkISy1IxHrxeEic9I71DgE1aiJSnQQctobqXuMM/Mqr7tHrHxdKfZBu1UPE/QMUdscyZae6iufKRlgv9ZPqzMzW0akg6FI01o1pw3lTURACKyg39ZLEs0D10sIWk/t3HHLK6ptBsmiPJ3ofqWxftxQa8gvxx6zGHfMoMsFGDLIW6Pvw9CeyTkVHThZSB/+c7CtCK+39UDbQSXwqO2/wtNLWMZYkspohqm6IL93V6DbEDksC8UtWHhmGv9HCnr13GJ5ZToyjGwujYlb0pC2XykYS3hakSqoIiViZFGjPizjrlp/K10IAXA93QGoQvKpXzu/9jnWVU1pjvkWMqrsqrdtN818/m/Om/ILseaH5I7w7TrBIHIme/8nfUbZnhpitJYK9xkKM5Iz5ib0t2djWez2/6yVAqGHT1gwRGYOF/9+mOpgD0D2w5Zvu6grZU66NoPgLozo9T4JPqc2xtwTvQbpw832q43evXldEAodAkjZwOnM1S7v8elqkaYfB3xEJcvssOz7mRSqEqOrt00g8o0K0uuBvVSdNXsvruQQTArz2CDyT3pSOWXiENnkYeNBxd5OXwpAwZnFw3J4foSbAC+fxa2IgDxvwf94M9s2k6Ur1k7Exb/rPJdAR8yUUKKI//QhJYom9M+WVmrHCUvU3I5D",
    },
  },

  connector: kube.Deployment("google-cloud-print-connector") + $.namespace {
    spec+: {
      template+: {
        spec+: {
          serviceAccountName: $.serviceAccount.metadata.name,
          nodeSelector+: utils.archSelector("amd64"),
          containers_+: {
            default: kube.Container("gcp-connector") {
              image: "tianon/google-cloud-print-connector:1.16",
              command: ["gcp-cups-connector"],
              args_+: {
                "log-to-console": true,
                "config-filename": "/config/gcp-cups-connector.config.json",
              },
              env_+: {
                CUPS_SERVER: cups_server,
              },
              volumeMounts_+: {
                config: {mountPath: "/config", readOnly: true},
              },
              resources: {
                requests: {cpu: "1m", memory: "9Mi"},
              },
            },
          },
          volumes_+: {
            config: kube.SecretVolume($.config),
          },
        },
      },
    },
  },
}
