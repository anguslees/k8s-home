// https://prometheus.io/docs/alerting/configuration/
{
  global: {
    resolve_timeout: "5m",

    smtp_smarthost: "smtp.mail:25",
    smtp_from: "alertmanager@mongrel.lan",
    smtp_hello: "alertmanager.monitoring.svc",
    smtp_require_tls: false,
  },

  //templates: []

  route: {
    group_by: ["alertname", "cluster", "service"],

    group_wait: "30s",

    group_interval: "5m",
    repeat_interval: "7d",

    receiver: "email",

    routes: [
    ],
  },

  inhibit_rules: [
    {
      source_match: {severity: "critical"},
      target_match: {severity: "warning"},
      equal: ["alertname", "cluster", "service"],
    },
  ],

  receivers_:: {
    email: {
      email_configs: [{to: "gus@mongrel.lan"}],
    },
  },
  receivers: [{name: k} + self.receivers_[k] for k in std.objectFields(self.receivers_)],
}
