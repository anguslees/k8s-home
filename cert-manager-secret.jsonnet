// cert-manager.jsonnet SealedSecret

local all = import "all.jsonnet";
local really_secret = import "actual_secrets.jsonnet";

local ssecret = all.cert_manager.secret;
ssecret.Secret_(really_secret.cert_manager)
