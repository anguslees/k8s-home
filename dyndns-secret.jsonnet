// dyndns.jsonnet SealedSecret

local all = import "all.jsonnet";
local really_secret = import "actual_secrets.jsonnet";

local ssecret = all.dyndns.secret;
ssecret.Secret_(really_secret.dyndns)
