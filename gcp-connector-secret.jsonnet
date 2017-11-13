// cloudprint.jsonnet SealedSecret

local all = import "all.jsonnet";
local really_secret = import "actual_secrets.jsonnet";

local ssecret = all.cloudprint.config;
ssecret.Secret_(really_secret.gcp_connector)
