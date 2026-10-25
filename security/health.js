'use strict';
const fs = require('fs');
const https = require('https');
const http = require('http');
const {X509Certificate} = require('crypto');

function check(client, options) {
  return new Promise((resolve, reject) => {
    const request = client.get(options, response => {
      response.resume();
      if (response.statusCode === 200) resolve();
      else reject(new Error('Service is not ready'));
    });
    request.setTimeout(2000, () => request.destroy(new Error('Health timeout')));
    request.on('error', reject);
  });
}

async function main() {
  const certificate = fs.readFileSync(process.env.SB_CERTIFICATE_FILE);
  const fingerprint = new X509Certificate(certificate).fingerprint256;
  await check(https, {
    host: process.env.SB_API_ADDRESS || '127.0.0.1',
    port: Number(process.env.SB_API_PORT),
    path: `/${process.env.SB_API_PREFIX}/server`,
    ca: certificate,
    checkServerIdentity: (_host, peer) => peer.fingerprint256 === fingerprint
      ? undefined : new Error('Certificate pin mismatch'),
  });
  await check(http, {host: '127.0.0.1', port: 9090, path: '/-/ready'});
}

main().catch(() => { process.exitCode = 1; });
