local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";

{
  namespace:: { metadata+: { namespace: "dyndns" }},

  ns: kube.Namespace($.namespace.metadata.namespace),

  secret: utils.SealedSecret("dyndns") + $.namespace {
    // If data_ is changed, reseal with ./seal.sh dyndns-secret.jsonnet
    data_:: {
      // digitalocean API token
      token: error "secret! token value not overridden",
    },
    spec+: {
      data: "AgBV1xy8OSGr2jagx/8gYKeZ0NDfn6wIi6OJejCOYv+TYzqUjFEWJLYYCsaZJEkh1IpfHvaOmKW//Lla0JS/aErzROj3X4jAqa9GugO6TdCtEO50kLp/L5zZM/lFDaqTg8kJ3U6rjEoQQBwE8rhI9zT81A3Evz4BaNe65WuMisoKU7LdiODnlEfY5LcQc0HqggUhQHW8PudMd1kPiRnZQAIkKTc5UqwlKtjCAkVrB1Kwm5z4hprKJ0UfJOHHo19vjCAx9jhcixqSY/dK+4pBcn//qZ7Y55VGnZoqMN3tqjDCaz6UIQ5pcFzxgMP4TAhSqzP5WG3d6zHPhfAid8DBYBRj67fR9Aa4W/4f4/0q4FI0JX/ruSWBpBWS+mvcSgZrwDDNDLbFH8nXW/ZJzCMMc0vkHBCSgePNAo0ZvU/GHDZidqd3/HZ4qenuExwkUvy3Cdk3Gh/eq2wkc6B28riGPxjZbzx7JopOPFEKFRqigeIbeXlGKwEbtymu+PreMiU9BRBjWsBtoMM49Px0yxuphQayIbo2el413EPjdVVnrHeiIbcOd8o+5osn04bHMCi68LbZKKcjaMADG9txoBm+eXPK0XT39SpUYs1xQB2MS7VgobKbRn0qe6eVAmXL49rg1LLDChbIF8tQXjv5sMDLWMuboAAuKdYQa3OUmZAOxx+3LBmn+Qz3D+0i3nwbBnqm9LR+Ds2cF2fx0OBIH5lAtvVNnYX8OregueHixmgkJMNxL7Df1uJSo0zWk9IsogDA8pNwdErWaqr9bcq/HiCR/wqFD8izix8InU5vnWpxmIfTib3disjyalKUpJjHKKUmf8T0bRSEvVGHjVejib1quD0pSvDkYNyRYfcaN3gvpMD3hDooAryRvnqTLZTyJ8AFu5IUKQt5IRdrVC0W8ktuzYRJS0RjAK8r3K3E1CUvp+XJdv3ctd7cN5CE9clKQCsRoidSp8xP89Z89bIewX8+XqxteSvU435KtPswl+Xu3ipa2jxJdIt2S1O8+KiwEON/4eh0OE5Nca3PoBfdGxue+5XODZM3dwLA",
    },
  },

  deploy: kube.Deployment("dyndns") + $.namespace {
    spec+: {
      template+: {
        spec+: {
          automountServiceAccountToken: false,
          containers_+: {
            default: kube.Container("dyndns") {
              image: "tunix/digitalocean-dyndns",
              env_+: {
                DIGITALOCEAN_TOKEN: kube.SecretKeyRef($.secret, "token"),
                DOMAIN: "oldmacdonald.farm",
                NAME: "webhooks",
                SLEEP_INTERVAL: "600", // seconds
              },
            },
          },
        },
      },
    },
  },
}
