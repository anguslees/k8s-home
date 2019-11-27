// external-dns.jsonnet SealedSecret

local all = import "all.jsonnet";
local really_secret = import "actual_secrets.jsonnet";

local ssecret = all.external_dns.secret;
ssecret.Secret_(really_secret.external_dns)
