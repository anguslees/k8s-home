local kube = import "kube.libsonnet";

{
  namespace:: {metadata+: {namespace: "mail"}},

  ns: kube.Namespace($.namespace.metadata.namespace),

  svc: kube.Service("smtp") + $.namespace {
    spec+: {
      type: "ClusterIP",
      selector: {}, // using explicit Endpoints
      ports: [{port: 25, protocol: "TCP"}],
    },
  },

  // TODO: move this into k8s as a regular deployment
  endpoints: kube.Endpoints("smtp") + $.namespace {
    local this = self,
    subsets: [{
      addresses: [this.Ip("192.168.0.10")],
      ports: [this.Port(25)],
    }],
  },
}
