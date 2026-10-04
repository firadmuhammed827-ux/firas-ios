import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const read = path => readFileSync(new URL('../FirasAI/' + path, import.meta.url), 'utf8');
const models = read('Models/MediaStudioModels.swift'), api = read('Networking/FirasAPI.swift');
const store = read('Stores/MediaStudioStore.swift'), screen = read('Features/Media/MediaStudioScreen.swift');
const chat = read('Stores/ChatStore.swift');
const chatScreen = read('Features/Chat/ChatScreen.swift');
const transport = read('Networking/APIClient.swift');
let checks = 0;
function check(condition, label) { assert.ok(condition, label); checks++; }
function block(source, anchor) {
  const at = source.indexOf(anchor); assert.ok(at >= 0, anchor);
  assert.equal(source.indexOf(anchor, at + anchor.length), -1, 'unique anchor: ' + anchor);
  const start = source.indexOf('{', at); let depth = 1, end = start + 1;
  for (; depth && end < source.length; end++) depth += source[end] === '{' ? 1 : source[end] === '}' ? -1 : 0;
  assert.equal(depth, 0, 'balanced source block: ' + anchor); return source.slice(start + 1, end - 1);
}
for (const kind of ['Image', 'Video', 'Music']) {
  const dto = block(models, `struct Media${kind}JobRequest:`);
  for (const field of ['cid', 'chatId', 'tier', 'lang']) {
    check(new RegExp(`let ${field}: String(?:\\s|$)`).test(dto), `${kind} binding ${field} is required on the actual DTO`);
  }
  const endpoint = block(api, `func start${kind}Job(`);
  check(endpoint.includes('try requireMediaBinding(binding)') && endpoint.includes(`path: "/api/${kind.toLowerCase()}/job"`), `${kind} validates binding and uses the shipping route`);
  check(endpoint.includes('cid: binding.cid, chatId: binding.chatID, tier: tier, lang: languageCode'), `${kind} emits captured wire identity`);
}
const receipt = block(api, 'func mediaJobReceipt(');
check(receipt.includes('.get') && receipt.includes('URLQueryItem(name: "cid", value: cid)') && !receipt.includes('.post'), 'uncertain recovery uses receipt GET only');
const dispatch = block(store, 'private func enqueueOrResume(');
const fenceAt = dispatch.indexOf('$0.startAttempted = true'), sendAt = dispatch.indexOf('try await start(initial)');
check(fenceAt >= 0 && sendAt > fenceAt && dispatch.slice(fenceAt, sendAt).includes('guard persistCurrentHistory()'), 'durable dispatch fence is successfully persisted before the render call');
check((dispatch.match(/try await start\(/g) || []).length === 1, 'enqueue has one paid dispatch even when receipt GETs are retried');
check(dispatch.includes('initial.startAttempted == false') && dispatch.includes('jobID: nil'), 'existing/uncertain attempts reconnect by receipt');
check(dispatch.includes('legacy_media_binding_missing'), 'legacy unbound records cannot auto-submit');
const start = block(store, 'private func start(');
check(dispatch.indexOf('guard freshInputs[creationID] != nil') >= 0 &&
  dispatch.indexOf('guard freshInputs[creationID] != nil') < fenceAt && dispatch.includes('media_resume_requires_receipt') &&
  start.indexOf('freshInputs.removeValue(forKey: creation.id)') >= 0 &&
  start.indexOf('freshInputs.removeValue(forKey: creation.id)') < start.indexOf('switch creation.kind') &&
  !dispatch.includes('let input = freshInputs'),
  'restored unattempted history cannot dispatch without an explicit in-memory input permit');
const accepts = block(store, 'private func accepts(');
check(accepts.includes('ownerGeneration == ticket') && accepts.includes('session.identityGeneration == adoptedIdentityGeneration') && accepts.includes('session.isAuthenticated'), 'store fences owner and identity epoch');
const hydrate = block(store, 'private func hydrateCompletedCreation(');
check((hydrate.match(/accepts\(ticket, ownerID: current.ownerID\)/g) || []).length >= 4, 'artifact hydration checks ownership before and after transport/write');
const tap = block(screen, 'private func create(');
check(tap.indexOf('let identityGeneration = session.identityGeneration') < tap.indexOf('creationTask = Task'), 'tap captures session epoch before task scheduling');
check(tap.includes('expectedIdentityGeneration: identityGeneration') && tap.includes('expectedOwnerGeneration: ownerGeneration'), 'UI passes captured preparation and render epochs');
const prepare = block(chat, 'func prepareMediaTurn(');
check(prepare.includes('var conversation = try await api.chat(id: selectedID)') && prepare.indexOf('try await api.updateMediaChat(') >= 0 &&
  prepare.indexOf('try await api.updateMediaChat(') < prepare.indexOf('return MediaTurnBinding('), 'bound assistant is persisted to authoritative current Chat before admission');
check(prepare.includes('role: .assistant, content: ""') && prepare.includes('cid: cid'), 'actual preparation creates the server-required assistant CID');
check(store.includes('code != 408 && code != 409'), 'ambiguous HTTP outcomes do not authorize paid Retry');
check(store.includes('active + Array(finished.prefix('), 'history cap retains all unresolved receipt pointers');
check(!screen.includes('if creation.canRetry {') && !screen.includes('private func retry('), 'history receipts do not expose a new paid Retry');
check(!api.includes('MediaRequestText.clamped') && !store.includes('MediaRequestText.clamped') &&
  models.includes('media_brief_too_large'), 'native media validates the full UTF16 brief without silent truncation');
const restore = block(store, 'private func resumeLoadedCreations(');
check(!restore.includes('beginHydration('), 'opening Studio does not download the completed library in bulk');
const pointer = block(store, 'private static func receiptOnly(');
check(pointer.includes('prompt: ""') && !pointer.includes('lyrics:') && !pointer.includes('sourceImage:'), 'stored receipt pointers omit replayable private drafts/source');
const stop = block(store, 'private func stopKnown(');
check(stop.includes('api.cancelMediaJob(') && stop.includes('0..<3'), 'explicit media Stop targets the actual job with bounded recovery');
check(block(api, 'func cancelMediaJob(').includes('MediaRequestPolicy.cancellationID(kind: kind, key: jobID)'), 'media Stop uses the server product prefix and modern receipt key');
check(models.includes('case stopping') && models.includes('case stopped'), 'pending Stop and confirmed stopped are separate truthful phases');
check(block(api, 'func mediaAssetFile(').includes('client.mediaFile(') && !api.includes('func mediaAsset('), 'media assets have a dedicated file-backed transport');
const transfer = block(transport, 'class MediaFileTransfer:');
check(transfer.includes('URLSessionDataDelegate') || transport.includes('class MediaFileTransfer: NSObject, URLSessionDataDelegate'), 'actual media transfer handles URLSession chunks');
check(transfer.includes('file.write(contentsOf: data)') && transfer.includes('maximumBytes(kind) - received') &&
  !transfer.includes('data(for:') && !transfer.includes('Data(contentsOf:'), 'large assets stream to disk under an enforced cumulative byte limit');
check(transfer.includes('httpCookieStorage = nil') && transfer.includes('completionHandler(nil)'), 'file downloads cannot redirect credentials or update the shared account cookie jar');
const finalizeTransfer = block(transport, 'private func finish(');
check(finalizeTransfer.includes('try file.close()') && !finalizeTransfer.includes('try? file?.close()') &&
  finalizeTransfer.includes('if case .failure = outcome') && finalizeTransfer.includes('resume(with: completion.2)'),
  'download completion propagates file-close failure and removes failed staging bytes before returning');
check(transport.includes('currentCookieHeader() == credentials.cookieHeader') && transport.includes('request.httpShouldHandleCookies = false'), 'scoped requests use their frozen owned credentials');
check(prepare.includes('api.mediaCredentialSnapshot()') && prepare.includes('MediaCredentialScope.$current.withValue(credentials)'), 'Chat binding is saved under captured media credentials');
check(block(api, 'func updateMediaChat(').includes('maximumBodyBytes: 2_000_000'), 'complete serialized media Chat history is bounded before PUT');
const directStop = block(chatScreen, 'private func stop(');
check(directStop.includes('direct.preparationID == contextPreparationID') &&
  directStop.includes('direct.identityGeneration == session.identityGeneration') &&
  directStop.includes('$0.cid == direct.binding.cid') && directStop.includes('mediaStudioStore.stop(creation'),
  'explicit composer Stop addresses the current owned direct-media receipt');
check(!block(chatScreen, 'private func routeDirectMediaRequest(').includes('lyrics: message'),
  'direct music requests never turn user instructions into sung lyrics');
const directMedia = block(chatScreen, 'private func routeDirectMediaRequest(');
check(directMedia.indexOf('MediaRequestPolicy.validationProblem(') >= 0 &&
  directMedia.indexOf('MediaRequestPolicy.validationProblem(') < directMedia.indexOf('await chatStore.prepareMediaTurn('),
  'direct media rejects an invalid full brief before writing a bound Chat turn');
console.log(`CLEAN: ${checks} iOS media wire/lifecycle source contracts; Swift/device checks remain pending on macOS.`);
