import { createSign, randomUUID } from 'node:crypto';
import { createServer } from 'node:http';
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';

const config = {
  bindHost: process.env.BIND_HOST || '0.0.0.0',
  port: Number(process.env.PORT || 8088),
  apiKey: process.env.API_KEY || '',
  registrationKey: process.env.REGISTRATION_KEY || process.env.API_KEY || '',
  dataDir: process.env.DATA_DIR || '/var/lib/sfait-push-gateway',
  defaultWakeWaitMs: Number(process.env.DEFAULT_WAKE_WAIT_MS || 4000),
  fcmServiceAccountFile:
    process.env.FCM_SERVICE_ACCOUNT_FILE ||
    '/etc/sfait-push-gateway/firebase-service-account.json',
};

const devicesFile = path.join(config.dataDir, 'devices.json');
const fcmScope = 'https://www.googleapis.com/auth/firebase.messaging';
let accessTokenCache = null;

function jsonResponse(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
  });
  res.end(payload);
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > 1024 * 128) {
        reject(new Error('Payload too large.'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (chunks.length === 0) {
        resolve({});
        return;
      }
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      } catch {
        reject(new Error('Invalid JSON payload.'));
      }
    });
    req.on('error', reject);
  });
}

function requireKey(req, expectedKey, missingMessage) {
  if (!expectedKey) {
    throw Object.assign(new Error(missingMessage), {
      status: 503,
    });
  }
  const header = req.headers['x-api-key'];
  if (header !== expectedKey) {
    throw Object.assign(new Error('Unauthorized.'), { status: 401 });
  }
}

function requireAdminAuth(req) {
  requireKey(req, config.apiKey, 'Gateway API key is not configured.');
}

function requireRegistrationAuth(req) {
  requireKey(
    req,
    config.registrationKey,
    'Gateway registration key is not configured.',
  );
}

async function loadDevices() {
  await mkdir(config.dataDir, { recursive: true });
  if (!existsSync(devicesFile)) {
    return {};
  }
  const raw = await readFile(devicesFile, 'utf8');
  return JSON.parse(raw || '{}');
}

async function saveDevices(devices) {
  await mkdir(config.dataDir, { recursive: true });
  const tmp = `${devicesFile}.${process.pid}.tmp`;
  await writeFile(tmp, `${JSON.stringify(devices, null, 2)}\n`, 'utf8');
  await rename(tmp, devicesFile);
}

function normalizeExtension(value) {
  let extension = String(value || '').trim();
  if (extension.startsWith('sip:')) {
    extension = extension.slice(4);
  }
  try {
    extension = decodeURIComponent(extension);
  } catch {
    // Keep the raw value; validation below will reject malformed input.
  }
  extension = extension.split(';')[0].split('@')[0].trim();
  extension = extension.replace(/^["']+|["']+$/g, '');
  const token = extension.match(/[0-9A-Za-z_.-]{1,32}/)?.[0] || '';
  if (token) {
    extension = token;
  }
  if (!/^[0-9A-Za-z_.-]{1,32}$/.test(extension)) {
    throw Object.assign(new Error('Invalid extension.'), { status: 400 });
  }
  return extension;
}

function normalizeFcmToken(value) {
  const token = String(value || '').trim();
  if (token.length < 32 || token.length > 4096) {
    throw Object.assign(new Error('Invalid FCM token.'), { status: 400 });
  }
  return token;
}

function normalizeWakeWaitMs(value) {
  const waitMs = Number(value || config.defaultWakeWaitMs);
  if (!Number.isFinite(waitMs)) {
    return config.defaultWakeWaitMs;
  }
  return Math.max(0, Math.min(10_000, Math.round(waitMs)));
}

function delay(ms) {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

function base64Url(input) {
  return Buffer.from(input)
    .toString('base64')
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replaceAll('=', '');
}

async function loadServiceAccount() {
  if (!existsSync(config.fcmServiceAccountFile)) {
    throw Object.assign(
      new Error(
        `Firebase service account missing at ${config.fcmServiceAccountFile}.`,
      ),
      { status: 503 },
    );
  }
  const raw = await readFile(config.fcmServiceAccountFile, 'utf8');
  return JSON.parse(raw);
}

async function getAccessToken() {
  const now = Math.floor(Date.now() / 1000);
  if (accessTokenCache && accessTokenCache.expiresAt - 60 > now) {
    return accessTokenCache.token;
  }

  const account = await loadServiceAccount();
  const header = base64Url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claim = base64Url(
    JSON.stringify({
      iss: account.client_email,
      scope: fcmScope,
      aud: account.token_uri || 'https://oauth2.googleapis.com/token',
      iat: now,
      exp: now + 3600,
    }),
  );
  const unsignedJwt = `${header}.${claim}`;
  const signature = createSign('RSA-SHA256')
    .update(unsignedJwt)
    .sign(account.private_key);
  const assertion = `${unsignedJwt}.${base64Url(signature)}`;

  const response = await fetch(
    account.token_uri || 'https://oauth2.googleapis.com/token',
    {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        assertion,
      }),
    },
  );
  const body = await response.json();
  if (!response.ok) {
    throw Object.assign(
      new Error(`Firebase auth failed: ${body.error || response.statusText}`),
      { status: 502 },
    );
  }

  accessTokenCache = {
    token: body.access_token,
    expiresAt: now + Number(body.expires_in || 3600),
  };
  return accessTokenCache.token;
}

async function sendFcmDataMessage(device, data) {
  const account = await loadServiceAccount();
  const token = await getAccessToken();
  const response = await fetch(
    `https://fcm.googleapis.com/v1/projects/${account.project_id}/messages:send`,
    {
      method: 'POST',
      headers: {
        authorization: `Bearer ${token}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        message: {
          token: device.fcmToken,
          data,
          android: {
            priority: 'HIGH',
            ttl: '30s',
          },
        },
      }),
    },
  );
  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw Object.assign(
      new Error(`FCM send failed: ${body.error?.message || response.statusText}`),
      { status: 502 },
    );
  }
  return body;
}

async function registerDevice(req, res) {
  requireRegistrationAuth(req);
  const body = await readJsonBody(req);
  const extension = normalizeExtension(body.extension);
  const fcmToken = normalizeFcmToken(body.fcmToken);
  const deviceId = String(body.deviceId || randomUUID()).trim();
  const platform = String(body.platform || 'android').trim();
  const now = new Date().toISOString();
  const devices = await loadDevices();
  devices[extension] ??= {};
  devices[extension][deviceId] = {
    deviceId,
    extension,
    platform,
    fcmToken,
    label: String(body.label || '').trim(),
    updatedAt: now,
  };
  await saveDevices(devices);
  jsonResponse(res, 200, { ok: true, extension, deviceId, updatedAt: now });
}

async function unregisterDevice(req, res) {
  requireRegistrationAuth(req);
  const body = await readJsonBody(req);
  const extension = normalizeExtension(body.extension);
  const deviceId = String(body.deviceId || '').trim();
  const devices = await loadDevices();
  if (deviceId && devices[extension]) {
    delete devices[extension][deviceId];
  } else {
    delete devices[extension];
  }
  await saveDevices(devices);
  jsonResponse(res, 200, { ok: true });
}

async function pushIncomingCall(req, res) {
  await pushCallEvent(req, res, {
    type: 'incoming_call',
    defaultCaller: 'Inconnu',
  });
}

async function pushIncomingCallAndWait(req, res) {
  const result = await pushCallEvent(req, res, {
    type: 'incoming_call',
    defaultCaller: 'Inconnu',
    respond: false,
  });
  const waitMs = normalizeWakeWaitMs(result.body.waitMs);
  if (result.ok && waitMs > 0) {
    await delay(waitMs);
  }
  jsonResponse(res, result.status, {
    ...result.responseBody,
    waitMs,
  });
}

async function pushCallEnded(req, res) {
  await pushCallEvent(req, res, {
    type: 'call_ended',
    defaultCaller: '',
  });
}

async function pushSipWake(req, res) {
  requireAdminAuth(req);
  const body = await readJsonBody(req);
  const extensionValue = String(
    body.extension || body.pnParam || body['pn-param'] || '',
  ).trim();
  const deviceId = String(
    body.deviceId || body.pnPrid || body['pn-prid'] || '',
  ).trim();
  const caller = String(
    body.caller || body.callerId || body.remoteIdentity || 'Inconnu',
  ).trim();
  const callId = String(body.callId || randomUUID()).trim();
  const devices = await loadDevices();
  let extension = '';
  if (extensionValue) {
    try {
      extension = normalizeExtension(extensionValue);
    } catch (error) {
      if (!deviceId) {
        throw error;
      }
    }
  }
  let targetDevices = [];

  if (deviceId) {
    for (const extensionDevices of Object.values(devices)) {
      for (const device of Object.values(extensionDevices)) {
        if (device.deviceId === deviceId) {
          targetDevices.push(device);
        }
      }
    }
  }

  if (targetDevices.length === 0 && extension) {
    targetDevices = Object.values(devices[extension] || {});
  }

  if (targetDevices.length > 0 && !extension) {
    extension = targetDevices[0].extension;
  }

  if (targetDevices.length === 0) {
    jsonResponse(res, 404, {
      ok: false,
      error: deviceId
        ? `No registered Android device for device ${deviceId}.`
        : `No registered Android device for extension ${extension || extensionValue}.`,
    });
    return;
  }

  const data = {
    type: 'sip_wake',
    extension,
    caller,
    callId,
    sentAt: new Date().toISOString(),
  };
  const results = await sendDataMessageToDevices(targetDevices, data);
  const ok = results.some((result) => result.ok);
  jsonResponse(res, ok ? 200 : 502, {
    ok,
    extension,
    callId,
    sent: results.filter((result) => result.ok).length,
    results,
  });
}

async function pushCallEvent(req, res, options) {
  requireAdminAuth(req);
  const body = await readJsonBody(req);
  const extension = normalizeExtension(body.extension);
  const caller = String(body.caller || body.callerId || options.defaultCaller).trim();
  const callId = String(body.callId || randomUUID()).trim();
  const devices = await loadDevices();
  const extensionDevices = Object.values(devices[extension] || {});
  if (extensionDevices.length === 0) {
    const responseBody = {
      ok: false,
      error: `No registered Android device for extension ${extension}.`,
    };
    if (options.respond !== false) {
      jsonResponse(res, 404, responseBody);
    }
    return { ok: false, status: 404, body, responseBody };
  }

  const data = {
    type: options.type,
    extension,
    caller,
    callId,
    sentAt: new Date().toISOString(),
  };
  const results = await sendDataMessageToDevices(extensionDevices, data);

  const ok = results.some((result) => result.ok);
  const status = ok ? 200 : 502;
  const responseBody = {
    ok: results.some((result) => result.ok),
    extension,
    callId,
    sent: results.filter((result) => result.ok).length,
    results,
  };
  if (options.respond !== false) {
    jsonResponse(res, status, responseBody);
  }
  return { ok, status, body, responseBody };
}

async function sendDataMessageToDevices(targetDevices, data) {
  const results = [];
  for (const device of targetDevices) {
    try {
      const fcmResult = await sendFcmDataMessage(device, data);
      results.push({ deviceId: device.deviceId, ok: true, fcmResult });
    } catch (error) {
      results.push({
        deviceId: device.deviceId,
        ok: false,
        error: error.message,
      });
    }
  }
  return results;
}

async function listDevices(req, res) {
  requireAdminAuth(req);
  const devices = await loadDevices();
  const sanitized = {};
  for (const [extension, extensionDevices] of Object.entries(devices)) {
    sanitized[extension] = Object.values(extensionDevices).map((device) => ({
      deviceId: device.deviceId,
      extension: device.extension,
      platform: device.platform,
      label: device.label,
      updatedAt: device.updatedAt,
      tokenPreview: `${device.fcmToken.slice(0, 12)}...`,
    }));
  }
  jsonResponse(res, 200, { ok: true, devices: sanitized });
}

async function route(req, res) {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  if (req.method === 'GET' && url.pathname === '/health') {
    jsonResponse(res, 200, {
      ok: true,
      service: 'sfait-push-gateway',
      fcmConfigured: existsSync(config.fcmServiceAccountFile),
    });
    return;
  }
  if (req.method === 'POST' && url.pathname === '/v1/register') {
    await registerDevice(req, res);
    return;
  }
  if (req.method === 'POST' && url.pathname === '/v1/unregister') {
    await unregisterDevice(req, res);
    return;
  }
  if (req.method === 'POST' && url.pathname === '/v1/push/incoming-call') {
    await pushIncomingCall(req, res);
    return;
  }
  if (req.method === 'POST' && url.pathname === '/v1/push/incoming-call-wait') {
    await pushIncomingCallAndWait(req, res);
    return;
  }
  if (req.method === 'POST' && url.pathname === '/v1/push/call-ended') {
    await pushCallEnded(req, res);
    return;
  }
  if (req.method === 'POST' && url.pathname === '/v1/push/sip-wake') {
    await pushSipWake(req, res);
    return;
  }
  if (req.method === 'GET' && url.pathname === '/v1/devices') {
    await listDevices(req, res);
    return;
  }
  jsonResponse(res, 404, { ok: false, error: 'Not found.' });
}

const server = createServer((req, res) => {
  route(req, res).catch((error) => {
    const status = Number(error.status || 500);
    console.error(error);
    jsonResponse(res, status, {
      ok: false,
      error: error.message || 'Internal server error.',
    });
  });
});

server.listen(config.port, config.bindHost, () => {
  console.log(
    `SFAIT Push Gateway listening on ${config.bindHost}:${config.port}`,
  );
});
