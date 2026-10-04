import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import path from 'node:path';

// Source-contract audit only. This does not compile or execute Swift/SwiftUI.
const repo = path.resolve(import.meta.dirname, '../..');
const read = relative => readFileSync(path.join(repo, relative), 'utf8');
const models = read('ios/FirasAI/Models/OmnixCloudModels.swift');
const store = read('ios/FirasAI/Stores/OmnixCloudStore.swift');
const sheet = read('ios/FirasAI/Features/Chat/OmnixCloudSheet.swift');
const api = read('ios/FirasAI/Networking/FirasAPI.swift');
const server = read('tools/omnix-cloud-tenants.mjs');
let checks = 0;
function check(value, message) { assert.ok(value, message); checks += 1; }
function body(source, from, until) {
  const start = source.indexOf(from);
  const end = source.indexOf(until, start + from.length);
  assert.ok(start >= 0 && end > start, `Missing audit boundary ${from}`);
  return source.slice(start, end);
}
const routes = body(api, 'func omnixCloudStatus()', 'func requestOmnixAccess(');
for (const suffix of ['/api/omnix/cloud', '/api/omnix/runs', '/cancel', '/reconcile', '/approval', '/api/omnix/files']) {
  check(routes.includes(suffix), `Native API includes ${suffix}`);
}
check(!/https?:|hf\.space|Authorization|gateway|workerURL|botToken/.test(routes), 'Client uses same-origin cookie routes without worker credentials');
check(read('ios/FirasAI/Networking/APIClient.swift').includes('HTTPCookieStorage.shared'), 'Website session cookies are shared');
check(read('ios/FirasAI/Networking/CloudEndpointPolicy.swift').includes('completionHandler(allowed ? request : nil)'), 'Foreign redirects are rejected');
const pointer = body(models, 'struct OmnixCloudPointer:', 'struct OmnixCloudLatest:');
const storedPointer = [...pointer.matchAll(/\bvar (\w+): String\?/g)].map(x => x[1]).sort();
check(JSON.stringify(storedPointer) === JSON.stringify(['jobId','requestKey','sessionId']), 'Durable pointers contain identifiers only');
const request = body(models, 'struct OmnixCloudRunRequest:', 'struct OmnixCloudApprovalRequest:');
const requestFields = [...request.matchAll(/\blet (\w+):/g)].map(x => x[1]).sort();
check(JSON.stringify(requestFields) === JSON.stringify(['product','requestKey','sessionId','text']), 'No caller UID, URL, provider or model in run payload');
check(request.includes('text.utf16.count <= 60_000') && server.includes('input.text.length > 60_000'), 'Swift and server preserve the same 60000 UTF16 brief limit');
check(server.includes('1,256') && models.includes('^[A-Za-z0-9_-]{1,256}$'), 'Approval identifier bound matches current server');
check(models.includes('["once", "deny"]') && !routes.includes('always'), 'Approval has only once/deny choices');
check(models.includes('latestJobs?[product.rawValue]') && server.includes('latestJobs[product]'), 'Web and native recover the same product-specific pointer');
check(store.includes('pointer?.requestKey != latest.requestKey'), 'An older latest job is not a receipt for an uncertain new request');
check(store.includes('firas.omnix.cloud.pointer.v1.\\($0).\\(product.rawValue)'), 'Pointers are scoped by authenticated account and product');
check(store.includes('generation &+= 1') && store.includes('ticket == generation, ownerID == owner'), 'Async results have account lifecycle guards');
const invalidation = body(store, 'func invalidate()', 'func bind(');
check(!/api\.|cancelOmnix|stop\(/.test(invalidation), 'Closing native UI never cancels cloud work');
const lifecycle = body(sheet, '.task(id:', 'private var taskControls:');
check(!/store\.(submit|approve|reconcile|stop)\(/.test(lifecycle), 'Task lifecycle only reads status; actions require buttons');
check(lifecycle.includes('openedOwner != owner') && lifecycle.includes('draft = ""; dismiss()'), 'A new account cannot inherit an old sheet draft');
check(sheet.includes('.onDisappear { store.invalidate(); draft = "" }'), 'Close clears temporary UI state');
check(store.includes('[401, 403].contains(status)') && store.includes('cloud = nil; job = nil; files = []'), 'Loss of access clears account details and invalidates pending results');
check(store.includes('files.contains(file)') && routes.includes('OmnixCloudPolicy.fileID(id)'), 'Downloads use validated opaque IDs from the authorized file list');
check(store.includes('.completeFileProtection') && store.includes('values.isExcludedFromBackup = true'), 'Export copies use private temporary storage excluded from backup');
check(models.includes('observed &&') && models.includes('seen.insert($0.id).inserted'), 'Step list only shows distinct observed events');
check(sheet.includes('Outcome unavailable') && !sheet.includes('withAnimation'), 'Unknown outcomes stay unknown; no custom motion introduced');
check(read('ios/FirasAI/Features/Code/CodeScreen.swift').includes('OmnixAccessSheet(product: .code, initialDraft: prompt)'), 'Code passes the actual Code draft');
check(read('ios/FirasAI/Features/Chat/ChatScreen.swift').includes('ModelSelectionSheet(initialDraft: draft)'), 'Chat passes the actual Chat draft');
check(read('ios/FirasAI/Features/Chat/ModelSelectionSheet.swift').includes('OmnixAccessSheet(product: .ai, initialDraft: initialDraft)'), 'Chat opens the AI product scope');
check(read('ios/FirasAI.xcodeproj/project.pbxproj').includes('PBXFileSystemSynchronizedRootGroup'), 'New scoped Swift files are included by the synchronized project group');
console.log(`PASS: ${checks} native Omnix source-contract checks (not a Swift build or runtime test)`);
