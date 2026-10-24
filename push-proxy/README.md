# SFAIT SIP Push Proxy

This directory contains the OpenSIPS configuration target for the Android
push mode.

## Target

OpenSIPS sits between Android clients and FusionPBX:

- Android registers to OpenSIPS over WSS.
- OpenSIPS forwards/throttles registrations to FusionPBX.
- FusionPBX sends inbound calls to OpenSIPS.
- OpenSIPS triggers the local FCM gateway, waits for Android to re-register,
  then relays the INVITE.

## Current LXC

- Host: `192.168.1.80`
- OS: Debian 12 `bookworm`
- Services:
  - `sfait-push-gateway` on `0.0.0.0:8088`
  - `opensips` on `192.168.1.80:5060/udp` and `192.168.1.80:5066/ws`

The official OpenSIPS APT landing page lists Debian 12 Bookworm as a supported
platform for OpenSIPS 3.6 stable/LTS packages, so the proxy runs on Debian 12
rather than Debian 13 nightly packages.

## aaPanel reverse proxy

The Flutter SIP stack uses WebSocket signaling. The recommended public path is
to keep TLS termination in aaPanel and proxy WSS traffic to OpenSIPS plain WS:

```nginx
location /appels-ws/ {
    proxy_pass http://192.168.1.80:5066;
    proxy_http_version 1.1;

    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host pbx.sfait.fr;

    proxy_read_timeout 86400;
    proxy_send_timeout 86400;
    proxy_buffering off;
}
```

Once this is active, Android clients can keep using
`wss://pbx.sfait.fr/appels-ws/`, but their SIP registration will go through
OpenSIPS instead of directly hitting FreeSWITCH.

## Files

- `opensips/opensips.cfg.template`: routing template for the proxy.

The deployed configuration is rendered from the template by replacing
`CHANGE_ME_API_KEY` with the local gateway `API_KEY`.
