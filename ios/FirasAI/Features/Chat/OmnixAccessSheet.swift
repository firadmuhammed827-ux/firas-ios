import SwiftUI

struct OmnixAccessSheet: View {
    let product: OmnixCloudProduct
    let initialDraft: String
    @Environment(SessionStore.self) private var session
    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.dismiss) private var dismiss
    @State private var store = OmnixAccessStore()
    @State private var reason = ""
    @State private var showsCloud = false

    init(product: OmnixCloudProduct = .ai, initialDraft: String = "") {
        self.product = product; self.initialDraft = initialDraft
    }

    private var ar: Bool { preferences.language == .arabic }
    private var owner: String? { session.isAuthenticated ? session.identityID : nil }
    private var record: OmnixAccessRecord? { store.ownerID == owner ? store.record : nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(verbatim: "omnix 1").font(.title2.bold()).environment(\.layoutDirection, .leftToRight)
                    Text(verbatim: ar ? "نفس حساب الموقع ونفس طلب الموافقة والذاكرة والملفات السحابية، عند تفعيل الخدمة." : "The same website account, approval, cloud memory and files when the service is enabled.")
                    Text(verbatim: ar ? "الموافقة على الطلب لا تفعّل التشغيل قبل جاهزية الخدمة المعزولة لكل حساب." : "Approval does not enable execution until the service is ready with isolation for each account.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if owner == nil {
                    Text(verbatim: ar ? "سجّل الدخول إلى حسابك أولًا من قائمة الحساب." : "Sign in from the account menu first.")
                } else {
                    Section {
                        Text(verbatim: statusText)
                        if record?.status == "approved", store.cloud?.canRun == true {
                            Button(ar ? "افتح omnix 1 في السحابة" : "Open omnix 1 in the cloud") { showsCloud = true }
                                .frame(minHeight: 44).disabled(store.isWorking || store.failed)
                        }
                        if let record, !record.reason.isEmpty, !record.acceptsRequest {
                            Text(verbatim: record.reason).font(.subheadline).textSelection(.enabled)
                        }
                        if record?.acceptsRequest == true {
                            TextEditor(text: $reason).frame(minHeight: 130)
                                .accessibilityLabel(ar ? "سبب طلب الوصول" : "Reason for requesting access")
                            Text(verbatim: "\(reason.utf16.count) / 1200").font(.caption).foregroundStyle(.secondary)
                            Button(ar ? "إرسال الطلب" : "Submit request") {
                                Task { await store.submit(reason: reason, owner: owner) }
                            }
                            .disabled(store.isWorking || store.mustRefresh || !OmnixAccessRequest(reason: reason).isValid)
                        }
                        if store.failed {
                            Text(verbatim: ar ? "تعذّر تأكيد الحالة. حدّثها قبل المحاولة مجددًا." : "The result could not be confirmed. Refresh before trying again.")
                                .foregroundStyle(.red)
                        }
                        Button(ar ? "تحديث الحالة" : "Refresh status") {
                            Task { await store.refresh(owner: owner) }
                        }.disabled(store.isWorking)
                        if store.isWorking { ProgressView() }
                    }
                }
            }
            .navigationTitle(Text(verbatim: "omnix 1"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ar ? "إغلاق" : "Close") { dismiss() } } }
        }
        .environment(\.layoutDirection, preferences.language.layoutDirection)
        .sheet(isPresented: $showsCloud) { OmnixCloudSheet(product: product, initialDraft: initialDraft) }
        .task(id: owner) { store.invalidate(); reason = ""; showsCloud = false; await store.refresh(owner: owner) }
        .onDisappear { store.invalidate(); reason = "" }
    }

    private var statusText: String {
        guard let record else { return ar ? "بانتظار قراءة حالة الطلب" : "Waiting for request status" }
        switch record.status {
        case "pending": return ar ? "طلبك بانتظار المراجعة" : "Your request is awaiting review"
        case "approved": return ar ? "تمت الموافقة على الطلب" : "Your request is approved"
        case "rejected": return ar ? "لم تتم الموافقة؛ يمكنك إرسال طلب جديد" : "Not approved; you can submit a new request"
        case "revoked": return ar ? "أُلغي الوصول؛ يمكنك إرسال طلب جديد" : "Access was revoked; you can submit a new request"
        default: return ar ? "اكتب سبب رغبتك باستخدام اومنكس، من 20 إلى 1200 حرف" : "Describe why you want access, in 20–1200 characters"
        }
    }
}
