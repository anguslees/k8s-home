local kubecfg = import "kubecfg.libsonnet";

// renovate: depName=bitnami-labs/sealed-secrets datasource=github-releases
local upstream = importstr "https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.18.0/controller.yaml";

kubecfg.parseYaml(upstream)
