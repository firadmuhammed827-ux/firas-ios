import SwiftUI

struct OmnixCloudSheet: View {
    let product: OmnixCloudProduct
    let initialDraft: String
    @Environment(SessionStore.self) private var session
    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.dismiss) private var dismiss
    @State private var store = OmnixCloudStore()
    @State private var draft = ""
    @State private var openedOwner: String?
    @State private var hasBoundOwner = false

    private var ar: Bool { preferences.language == .arabic }
    private var owner: String? { session.isAuthenticated ? session.identityID : nil }
    private var ownState: Bool { owner != nil && store.ownerID == owner && store.product == product }
    private var job: OmnixCloudJob? { ownState ? store.job : nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(verbatim: "omnix 1").font(.title2.bold()).environment(\.layoutDirection, .leftToRight)
                    Text(verbatim: ar ? "مهام السحابة وذاكرتها وملفاتها مرتبطة بحساب الموقع. يستمر التنفيذ عند إغلاق هذه النافذة." : "Cloud tasks, memory and files belong to your website account. Execution continues when you close this window.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(verbatim: statusText).font(.headline).accessibilityAddTraits(.updatesFrequently)
                    if ownState, let failure = store.failure { Text(verbatim: failureText(failure)).foregroundStyle(.red) }
                }
                if owner != nil, ownState {
                    taskControls
                    if let job {
                        if let approval = job.pendingApproval { approvalSection(approval) }
                        progressSection(job)
                        if job.isTerminal, let output = job.result?.output, !output.isEmpty {
                            Section {
                                Text(verbatim: output).textSelection(.enabled)
                            } header: { Text(verbatim: ar ? "النتيجة" : "Result") }
                        }
                    }
                    filesSection
                }
            }
            .navigationTitle(Text(verbatim: "omnix 1"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ar ? "إغلاق" : "Close") { dismiss() }.frame(minHeight: 44) } }
        }
        .environment(\.layoutDirection, preferences.language.layoutDirection)
        .task(id: "\(owner ?? "signed-out"):\(product.rawValue)") {
            if hasBoundOwner, openedOwner != owner { store.invalidate(); draft = ""; dismiss(); return }
            openedOwner = owner; hasBoundOwner = true
            store.bind(owner: owner, product: product)
            draft = initialDraft // A draft only. Never submit or persist it automatically.
            guard owner != nil else { return }
            await store.refresh()
            while !Task.isCancelled, store.ownerID == owner {
                do { try await Task.sleep(for: .seconds(2.5)) } catch { break }
                if store.hasLiveJob, !store.isWorking { await store.poll() }
            }
        }
        .onChange(of: owner) { old, new in
            if old != new { store.invalidate(); draft = ""; dismiss() }
        }
        .onDisappear { store.invalidate(); draft = "" }
    }

    private var taskControls: some View {
        Section {
            if !store.hasLiveJob || !draft.isEmpty {
                TextEditor(text: $draft).frame(minHeight: 140)
                    .accessibilityLabel(ar ? "طلب المهمة السحابية" : "Cloud task request")
                    .disabled(store.isWorking)
                Text(verbatim: "\(draft.utf16.count) / 60000").font(.caption).foregroundStyle(.secondary)
            }
            if !store.hasLiveJob {
                Button(ar ? "ابدأ المهمة" : "Start task") {
                    Task { if await store.submit(text: draft), ownState { draft = "" } }
                }
                .frame(minHeight: 44)
                .disabled(!store.isReady || store.isWorking || store.uncertain || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.utf16.count > 60_000)
            }
            Button(ar ? "تحديث الحالة" : "Refresh status") { Task { await store.refresh() } }
                .frame(minHeight: 44).disabled(store.isWorking)
            if let job, ["reserved", "submission_uncertain"].contains(job.state) {
                Button(ar ? "استرجع المهمة نفسها" : "Recover this task") { Task { await store.reconcile() } }
                    .frame(minHeight: 44).disabled(!store.isReady || store.isWorking)
                Text(verbatim: ar ? "يتحقق الخادم من المهمة نفسها؛ لا يُنشئ طلبًا جديدًا. قد يتعذر استرجاعها بعد انقطاع التنفيذ." : "The server checks this same task without creating a new request. Recovery may be unavailable after an interruption.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if store.hasLiveJob {
                Button(ar ? "أوقف المهمة" : "Stop task", role: .destructive) { Task { await store.stop() } }
                    .frame(minHeight: 44).disabled(!store.isReady || store.isWorking)
            }
            if store.isWorking { ProgressView() }
        }
    }

    private func approvalSection(_ approval: OmnixCloudApproval) -> some View {
        Section {
            Text(verbatim: approval.reason).textSelection(.enabled)
            Text(verbatim: approval.command).font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled).environment(\.layoutDirection, .leftToRight)
            ForEach(approval.choices, id: \.self) { choice in
                Button(choice == "once" ? (ar ? "اسمح لهذه المرة" : "Allow once") : (ar ? "ارفض الإجراء" : "Deny action")) {
                    Task { await store.approve(choice: choice) }
                }.frame(minHeight: 44).disabled(!store.isReady || store.isWorking || !store.approvalFresh)
            }
        } header: { Text(verbatim: ar ? "هذه الخطوة تحتاج موافقتك" : "This step needs your approval") }
    }

    private func progressSection(_ job: OmnixCloudJob) -> some View {
        Section {
            OmnixElapsedTime(startedAt: job.createdAt, endedAt: job.isTerminal ? job.updatedAt : nil)
            if let progress = job.progress, progress.engine == "omnix" {
                if !job.isTerminal, let speech = progress.says.last, !speech.isEmpty { Text(verbatim: speech).textSelection(.enabled) }
                ForEach(progress.observedSteps) { step in OmnixObservedStepRow(step: step, ar: ar) }
                if progress.capture?.complete != true || (progress.capture?.droppedSteps ?? 0) > 0 {
                    Text(verbatim: ar ? "بعض تفاصيل التقدم غير متاحة؛ نعرض أحدث الخطوات التي وصلت فعلًا." : "Some progress details are unavailable; these are the latest steps actually received.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Text(verbatim: ar ? "لم تصل تفاصيل الخطوات بعد. حالة المهمة تأتي من الخادم." : "Step details have not arrived. Task status comes from the server.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text(verbatim: ar ? "خطوات التنفيذ المسجلة" : "Observed execution steps") }
    }

    private var filesSection: some View {
        Section {
            Button(ar ? "تحديث الملفات" : "Refresh files") { Task { await store.refreshFiles() } }
                .frame(minHeight: 44).disabled(!store.isReady || store.isDownloading)
            ForEach(store.files) { file in
                Button { Task { await store.download(file) } } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: file.name).multilineTextAlignment(.leading)
                        Text(verbatim: ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                    }.frame(minHeight: 44)
                }.disabled(!store.isReady || store.isDownloading)
            }
            if store.isDownloading { ProgressView() }
            if let url = store.sharedFileURL { ShareLink(item: url) { Label(ar ? "حفظ الملف أو مشاركته" : "Save or share file", systemImage: "square.and.arrow.up") }.frame(minHeight: 44) }
        } header: { Text(verbatim: ar ? "ملفات حسابك السحابية" : "Your cloud files") }
    }

    private var statusText: String {
        guard owner != nil else { return ar ? "سجّل الدخول أولًا." : "Sign in first." }
        guard ownState, store.isReady else { return ar ? "بانتظار جاهزية مساحة حسابك السحابية." : "Waiting for your account’s cloud workspace to be ready." }
        if store.uncertain { return failureText(.uncertain) }
        guard let job else { return ar ? "مساحة حسابك جاهزة." : "Your workspace is ready." }
        switch job.state {
        case "completed": return ar ? "اكتملت المهمة" : "Task completed"
        case "failed": return ar ? "تعذّر إكمال المهمة" : "Task failed"
        case "interrupted": return ar ? "انقطع التنفيذ؛ لم يُعد تلقائيًا" : "Execution was interrupted; it was not restarted automatically"
        case "cancelled", "canceled": return ar ? "توقفت المهمة" : "Task stopped"
        case "waiting_for_approval": return ar ? "هذه الخطوة تحتاج موافقتك" : "This step needs your approval"
        case "stopping": return ar ? "طُلب الإيقاف؛ نتحقق من الحالة" : "Stop requested; checking the status"
        case "submission_uncertain": return failureText(.uncertain)
        default: return ar ? "المهمة قيد التنفيذ" : "Task in progress"
        }
    }

    private func failureText(_ failure: OmnixCloudFailure) -> String {
        switch failure {
        case .uncertain: return ar ? "لم نتأكد من استلام المهمة. حدّث الحالة لاسترجاعها دون إنشاء نسخة مكررة." : "Task receipt is unconfirmed. Refresh to recover it without creating a duplicate."
        case .rejected: return ar ? "لم يُقبل بدء المهمة. قد توجد مهمة أخرى قيد التنفيذ؛ حدّث الحالة." : "The task could not be started. Another task may be running; refresh the status."
        case .files: return ar ? "تعذّر تحميل الملف أو قائمة الملفات." : "Could not load the file or file list."
        case .refresh: return ar ? "تعذّر تأكيد الحالة. حدّثها قبل اتخاذ إجراء آخر." : "Could not confirm the status. Refresh before taking another action."
        }
    }
}

private struct OmnixObservedStepRow: View {
    let step: OmnixCloudStep
    let ar: Bool
    private var status: String {
        switch step.s {
        case "done": return ar ? "اكتملت" : "Completed"
        case "fail": return ar ? "أبلغت عن خطأ" : "Reported an error"
        case "run": return ar ? "قيد التنفيذ" : "Running"
        default: return ar ? "النتيجة غير متاحة" : "Outcome unavailable"
        }
    }
    var body: some View {
        DisclosureGroup {
            Text(verbatim: ar ? "سُجّلت هذه الخطوة من التنفيذ الفعلي." : "This step was observed during actual execution.")
                .font(.footnote).foregroundStyle(.secondary)
            if let duration = step.durationMs, duration.isFinite, duration >= 0 {
                Text(verbatim: "\((duration / 1000).formatted(.number.precision(.fractionLength(0...1)))) s").font(.caption).monospacedDigit()
            }
        } label: {
            HStack {
                Image(systemName: step.s == "done" ? "checkmark.circle" : step.s == "fail" ? "exclamationmark.circle" : "circle")
                    .accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text(verbatim: step.title).environment(\.layoutDirection, .leftToRight)
                    Text(verbatim: status).font(.caption).foregroundStyle(.secondary)
                }
            }.frame(minHeight: 44)
        }
    }
}

private struct OmnixElapsedTime: View {
    let startedAt: Int64
    let endedAt: Int64?
    var body: some View {
        Group {
            if let endedAt {
                Text(verbatim: "\(max(0, (endedAt - startedAt) / 1000)) s")
            } else {
                Text(Date(timeIntervalSince1970: Double(startedAt) / 1000), style: .timer)
            }
        }.font(.caption).monospacedDigit().foregroundStyle(.secondary).environment(\.layoutDirection, .leftToRight)
    }
}
