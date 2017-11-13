#!/bin/sh

kubecfg show "$@" |
kubeseal --cert sealkey.crt
