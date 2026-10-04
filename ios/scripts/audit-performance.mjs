import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

// These are source contracts. Execute the Swift race/renderer tests and the
// Simulator validation script on macOS before claiming runtime validation.
const root = path.resolve(import.meta.dirname, '..', 'FirasAI');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const chat = read('Stores/ChatStore.swift');
const screen = read('Features/Chat/ChatScreen.swift');
const row = read('Features/Chat/ChatMessageRow.swift');
const renderer = read('Features/Chat/ChatTextRenderer.swift');
const projection = read('Features/Chat/ChatViewProjection.swift');
const composer = read('Features/Chat/ChatComposer.swift');
const attachment = read('Features/Chat/ChatAttachmentProcessor.swift');
const brain = read('Stores/BrainStore.swift');
const code = read('Stores/CodeStore.swift');
const fixtures = fs.readFileSync(path.join(import.meta.dirname, 'chat-store-test-fixtures.swift'), 'utf8');
const models = read('Models/ChatModels.swift');
const intent = read('Models/IntentModels.swift');
const skills = read('Models/ChatSkillSelection.swift');
let checks = 0;
const check = (condition, message) => { assert.ok(condition, message); checks++; };
const stopBeforeID = chat.slice(chat.indexOf('guard let jobID = activeJobID else {'), chat.indexOf('pollTask?.cancel()', chat.indexOf('func stop()')));
check(!/activeCID = nil|stopRequestedCID = nil|pollTask = nil/.test(stopBeforeID), 'pending enqueue retains Stop intent and operation ownership');
const send = chat.slice(chat.indexOf('func send('));
check(send.indexOf('isSending = true') >= 0 && send.indexOf('await new(') > send.indexOf('isSending = true'), 'Send reservation precedes first-chat suspension');
check(!chat.includes('sanitizeConversationHistoryForInference'), 'request compaction does not erase visible attachment history');
check(chat.includes('reflectImmediately && didChange'), 'unchanged job status does not republish transcript');
check(chat.includes('selectionGeneration == generation'), 'chat selection has a stale-response guard');
check(screen.includes('nextFollow.geometryChanged(from: previous, to: current)') && projection.includes('followsLatestMessage && !isUserScrolling'), 'streaming respects user scroll intent');
const scrollTrigger = screen.slice(screen.indexOf('private var scrollTrigger:'), screen.indexOf('private func scrollToLatest'));
check(!scrollTrigger.includes('utf8.count') && !scrollTrigger.includes('jobPhase'), 'scroll trigger tracks rows/conversations rather than each answer/phase update');
check(screen.includes('viewportHeight: geometry.containerSize.height') && projection.includes('previous.viewportHeight != current.viewportHeight'), 'following reacts to actual viewport changes without observing content offsets');
check(projection.indexOf('previous.conversationID != current.conversationID') < projection.indexOf('current.messageCount > 0'), 'switching to an empty chat resets the previous scroll intent before the empty guard');
check(screen.includes('if nextFollow != scrollFollow { scrollFollow = nextFollow }'), 'unchanged scroll intent avoids publishing duplicate state');
check(composer.includes('ChatComposerContent.canSend(draft: draft, hasReadyContext: hasReadyContext)') && projection.includes('hasReadyContext || draft.unicodeScalars.contains') && !composer.includes('draft.trimmingCharacters'), 'composer boolean availability avoids constructing trimmed draft copies');
check(screen.includes('contextPreparationTask?.cancel()'), 'Stop cancels attachment preparation before submission');
check(screen.includes('session.identityID == ownerID'), 'attachment preparation is bound to its original account');
check(row.includes('ChatTextRenderer.shared.render(text)') && !row.includes('AttributedString(markdown:'), 'rich text parsing runs outside view construction');
check(renderer.includes('actor ChatTextRenderer'), 'formatting has independent actor isolation');
check(renderer.includes('maximumCachedBytes') && renderer.includes('maximumEntries'), 'rich text cache is bounded');
check(renderer.includes('let id: Int') && !renderer.includes('UUID'), 'text blocks use stable source offsets');
check(attachment.includes('CGImageSourceCreateThumbnailAtIndex'), 'camera images are downsampled during decode');
check(attachment.includes('worker.cancel()'), 'expensive attachment work propagates cancellation');
check(row.includes('maximumEdge: 360') && row.includes('guard !Task.isCancelled else { return }'), 'thumbnail decode is bounded and prevents stale publication');
for (const [name, value] of [['Brain', brain]]) {
  check(value.includes('func synchronizeOwner()'), `${name} clears its state on identity changes`);
  check(value.includes('ownerGeneration == generation'), `${name} rejects results from an older account generation`);
}
check(brain.includes('passageTicket == passageGeneration'), 'dismissed or superseded Brain passage stays dismissed');
check(!code.includes('await oldTask.value'), 'account library does not wait on old cloud tasks');
check(code.includes('ownerGeneration == generation'), 'Code rejects responses from retired account watchers');
check(code.includes('try? CodeProject.decode(fromJobText: text)') && code.includes('Task.detached(priority: .userInitiated)'), 'project result decoding stays off the main actor');
for (const file of ['Stores/ChatStore.swift', 'Stores/CodeStore.swift', 'Stores/MediaStudioStore.swift']) {
  check(read(file).includes('.skillValidation'), `${file} accounts for nonretryable validation errors`);
}
check(fixtures.includes('pendingStarts') && fixtures.includes('pendingCreations') && fixtures.includes('pendingChats'), 'race test harness controls actual asynchronous boundaries');
check(!screen.includes('detectMediaIntent'), 'paid-media routing does not infer intent from native keyword guesses');
check(screen.includes('await chatStore.classifyDraft') && screen.includes('prefetchedIntent: intent'), 'native screen passes its single authoritative classification to the job');
check(intent.includes('guard isValidated, !hasAttachedImage, !hasPriorImage, !hasFileContext'), 'new media routing preserves image references and file context');
check(models.includes('let skillIds: [String]?') && chat.includes('skillIDs: skillIDs'), 'selected account skills reach the actual durable job payload');
check(skills.includes('receipt == submission') && screen.includes('skillSelection.accept(receipt)'), 'pin consumption requires a matching accepted account and turn');
check(chat.includes('session.identityID != expectedOwnerID') && chat.includes('activeCID == cid'), 'queued sends and reservation release remain bound to their captured owner and operation');
check(chat.includes('consumeAcceptedDraft()') && chat.includes('composerDraft.accept(receipt, currentOwnerID: session.identityID, identityGeneration: session.identityGeneration)'), 'draft consumption uses the accepted turn and current account epoch');
check(screen.includes('snapshotDraft()') && screen.includes('beginDraftSubmission(cid: cid, snapshot: snapshot)'), 'Send captures an owned text/context revision before preparation');
check(screen.includes('retireDraftSubmission(expectedOwnerID:') && skills.includes('submissionRevision == snapshot.submissionRevision') && skills.includes('submissionRevision &+= 1'), 'leaving or stopping retires draft consumption, including late registration');
check(skills.includes('textRevision ==') && skills.includes('contextRevision =='), 'accepted sends consume only unchanged portions, preserving newer edits');
check(!screen.includes('draft = ""'), 'ordinary Send never clears editable input before admission');
console.log(`CLEAN: ${checks} iOS performance/lifecycle source contracts; Swift/runtime tests remain macOS-only`);
