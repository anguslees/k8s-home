// gitlab-runner.jsonnet SealedSecret

local all = import "all.jsonnet";
local really_secret = import "actual_secrets.jsonnet";

local ssecret = all.gitlab_runner.secret;
ssecret.Secret_(really_secret.gitlab_runner)
