# SFAIT Push Gateway

Small HTTP gateway used by SFAIT Softphone to wake Android devices through Firebase Cloud Messaging before an incoming SIP call is presented.

## Endpoints

- `GET /health`
- `POST /v1/register`
- `POST /v1/unregister`
- `POST /v1/push/incoming-call`
- `POST /v1/push/incoming-call-wait`
- `POST /v1/push/sip-wake`
- `POST /v1/push/call-ended`
- `GET /v1/devices`

`POST /v1/register` and `POST /v1/unregister` require:

```http
x-api-key: <REGISTRATION_KEY>
```

`POST /v1/push/incoming-call`, `POST /v1/push/incoming-call-wait`,
`POST /v1/push/sip-wake`, `POST /v1/push/call-ended`, and
`GET /v1/devices` require:

```http
x-api-key: <API_KEY>
```

## Firebase

Create a Firebase service account JSON file and place it at:

```text
/etc/sfait-push-gateway/firebase-service-account.json
```

or set `FCM_SERVICE_ACCOUNT_FILE` in `/etc/sfait-push-gateway.env`.

## Android app build

The Android app registers its FCM token with the gateway when the SIP account
is registered. Build it with:

```bash
flutter build apk --debug \
  --dart-define=SFAIT_PUSH_GATEWAY_URL=http://192.168.1.80:8088 \
  --dart-define=SFAIT_PUSH_REGISTRATION_KEY=<REGISTRATION_KEY>
```

## Example

```bash
curl -s http://127.0.0.1:8088/health
```

```bash
curl -s \
  -H "content-type: application/json" \
  -H "x-api-key: $API_KEY" \
  -d '{"extension":"101","caller":"0621191214"}' \
  http://127.0.0.1:8088/v1/push/incoming-call
```

Use the blocking wake endpoint from FusionPBX before dialing the Android
extension. The response is delayed by `waitMs` milliseconds, defaulting to
`DEFAULT_WAKE_WAIT_MS` or 4000 ms.

```bash
curl -s \
  -H "content-type: application/json" \
  -H "x-api-key: $API_KEY" \
  -d '{"extension":"101","caller":"0621191214","waitMs":4000}' \
  http://127.0.0.1:8088/v1/push/incoming-call-wait
```

```bash
curl -s \
  -H "content-type: application/json" \
  -H "x-api-key: $API_KEY" \
  -d '{"extension":"101","caller":"0621191214"}' \
  http://127.0.0.1:8088/v1/push/sip-wake
```

OpenSIPS can also target the device id carried in the SIP Contact URI
`pn-prid` parameter:

```bash
curl -s \
  -H "content-type: application/json" \
  -H "x-api-key: $API_KEY" \
  -d '{"pn-prid":"android-123","pn-param":"101","caller":"0621191214"}' \
  http://127.0.0.1:8088/v1/push/sip-wake
```

```bash
curl -s \
  -H "content-type: application/json" \
  -H "x-api-key: $API_KEY" \
  -d '{"extension":"101","caller":"0621191214"}' \
  http://127.0.0.1:8088/v1/push/call-ended
```
