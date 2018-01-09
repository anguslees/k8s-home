local kube = import "kube.libsonnet";

{
  namespace:: {metadata+: {namespace: "webcache"}},

  ns: kube.Namespace($.namespace.metadata.namespace),

  svc: kube.Service("proxy") + $.namespace {
    spec+: {
      type: "ClusterIP",
      selector: {}, // using explicit Endpoints
      ports: [{port: 80, protocol: "TCP"}],
    },
  },

  // TODO: move this into k8s as a regular deployment
  endpoints: kube.Endpoints("proxy") + $.namespace {
    local this = self,
    subsets: [{
      addresses: [this.Ip("192.168.0.10")],
      ports: [this.Port(3128)],
    }],
  },
}
