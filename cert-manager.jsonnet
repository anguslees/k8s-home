local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";
local kubecfg = import "kubecfg.libsonnet";

local email = "guslees+letsencrypt@gmail.com";

// renovate: depName=cert-manager registryUrl=https://charts.jetstack.io
local chartData = importbin "https://charts.jetstack.io/charts/cert-manager-v1.19.1.tgz";

{
  namespace:: {metadata+: {namespace: "cert-manager"}},

  ns: kube.Namespace($.namespace.metadata.namespace),

  chart: kubecfg.parseHelmChart(
    chartData,
    "cert-manager",
    $.namespace.metadata.namespace,
    {
      global: {
        leaderElection: {namespace: $.namespace.metadata.namespace},
        logLevel: 2,
      },
      installCRDs: true,
      ingressShim: {
        defaultIssuerName: "letsencrypt-prod",
        defaultIssuerKind: "ClusterIssuer",
        defaultIssuerGroup: "v1",
      },
      extraArgs_:: {
      },
      extraArgs: ["--%s=%s" % kv for kv in kube.objectItems(self.extraArgs_)],
      startupapicheck: {
        enabled: false,
      },
    }),

  crds:: {[c.spec.names.kind]: c for c in $.chart["cert-manager/templates/crds.yaml"]},

  Certificate:: utils.crdNew($.crds.Certificate, "v1"),
  Issuer:: utils.crdNew($.crds.Issuer, "v1"),
  ClusterIssuer:: utils.crdNew($.crds.ClusterIssuer, "v1"),

  secret: utils.SealedSecret("digitalocean") + $.namespace {
    // If data_ is changed, reseal with ./seal.sh cert-manager-secret.jsonnet
    data_:: {
      // digitalocean API token
      token: error "secret! token value not overridden",
    },
    spec+: {
      data: "AgCQX2SYGmsAFwXalT1IWoT2Jj0clFCDuT/tEH2yv6Fmq9bap7ImlYjDYoz00z5j29jojzaN9FH/oN3Fvv24TuAVixqau2hDr3XnH0DpF2QFosNgfl3E8dD2S4gFtlQHtOko193JYBbFFVkKoQbKkAJxif+9rgvfVOvETwFigfcarXcBiYYOzC39048NRM9CUzbZfCB2wdtIPyds6Tal4z1BXe12rq9SM/6t455ZUKK6I/Fjq+aQxj4P3OocJzREiCKR9ePAvesRt1ctVz+pT6N8+1RpTwsA4LPUEzeMYaiIjDUDMLPn9j5oWleKtNbEJJk7rtmTtoBjCrHGLjS3vZ422UbQ379EMlsSx2pYGKlj9QNC1CwUu+jnJUwGZRL6CuY2MJ8iPbgYHXl+rsUPKt73/Le96Foqv6fArwc8zHGHsNlg52MctmUCxfPVM83Gq8fgPASTNNRfz70He3pLOXT6h8C9+9OjtkJx9diUCtJmKsuSJQrxcr7XMkd35AfeMHrUfOT8CYGURiiBY1IeZaN0F9YZbsHHWuY+x96Tk5HD4CFNUCLNtSCyqRs/gw8feTgYaNtI9WoNw7TzwQB9Klcbqgj6pAJF8o7+vhbL6xbxVs9qKgF/JASntNZbnibnV8VvOVs+llINfQXJ4YQSF1yi7pRLHLDAP/hKjH3YJrx5aQ9cKcBT+im6vWi9KECrfQy9lehjOP2ZayrAVZIiTysiH34WulOZpNp7L3R+96y3DUGk6AB6yUKYd2bPTlOe5sSkWIU3lOaBIX/CYzlSGFAQbO8Oi9QtmBYLfhgnPHbjVGyfjs+6X0jXeDPQH/Ir6f+LZdlBnc8BJnKfTbc5eO2AJxKfAb3rPvrg5s3BOmrdS2RguIk7G2kWgxFafdiP2Msh31YVlHDx5d9ngIqyP/45kEAY4mXBlRvo+JIXMu9UHMNx8XRJAHxVkxXPr+CABGtyRap5DfpQgX9BaeykK1EKbX5K9nDBXokZPahabb5iW/sHrp82/yxCReTt6URbXNPsCeXLel+Dc7w3hC9xrf3sRKscqW+WUgrWvsxttOwQTDs3JPCrTuVW",
    },
  },

  letsencryptStaging: $.ClusterIssuer("letsencrypt-staging") {
    local this = self,
    spec+: {
      acme+: {
        server: "https://acme-staging-v02.api.letsencrypt.org/directory",
        email: email,
        privateKeySecretRef: {name: this.metadata.name},
        solvers: [{
          selector: {
            dnsZones: ["oldmacdonald.farm"],
          },
          dns01: {
            digitalocean: {
              tokenSecretRef: {
                name: $.secret.metadata.name,
                key: "token",
                assert std.objectHas($.secret.data_, self.key),
              },
            },
          },
        }],
      },
    },
  },

  letsencryptProd: $.letsencryptStaging {
    metadata+: {name: "letsencrypt-prod"},
    spec+: {
      acme+: {
        server: "https://acme-v02.api.letsencrypt.org/directory",
      },
    },
  },
}
