import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const root = path.resolve(import.meta.dirname, "..");
const app = path.join(root, "FirasAI");

const productFiles = [
  "Stores/BrainStore.swift",
  "Stores/CodeStore.swift",
  "Features/Brain/BrainDocumentExtractor.swift",
  "Features/Brain/BrainScreen.swift",
  "Features/Brain/BrainStrings.swift",
  "Features/Code/CodeScreen.swift",
  "Features/Code/CodeStrings.swift",
  "Models/IntentModels.swift",
  "Models/OmnixModels.swift",
  "Stores/OmnixAccessStore.swift",
  "Models/OmnixCloudModels.swift",
  "Stores/OmnixCloudStore.swift",
  "Features/Chat/OmnixCloudSheet.swift",
  "Stores/ChatStore.swift",
  "Models/CommonModels.swift",
  "Networking/FirasAPI.swift",
  "Networking/APIClient.swift",
  "Networking/CloudEndpointPolicy.swift",
  "App/AppConfiguration.swift",
  "Features/Chat/OmnixAccessSheet.swift",
  "Features/Chat/ModelSelectionSheet.swift",
  "App/FirasAIApp.swift",
  "Features/Shell/FirasAppShell.swift",
  "Features/Shell/ShellSidebar.swift",
  "Notifications/NotificationCoordinator.swift",
  "Notifications/FirasAppDelegate.swift",
];

function fail(message) {
  throw new Error(message);
}

function source(relativePath) {
  const absolutePath = path.join(app, relativePath);
  if (!fs.existsSync(absolutePath)) fail(`Missing ${relativePath}`);
  return fs.readFileSync(absolutePath, "utf8");
}

function requireFragments(relativePath, fragments) {
  const value = source(relativePath);
  for (const fragment of fragments) {
    if (!value.includes(fragment)) {
      fail(`${relativePath} is missing contract fragment: ${fragment}`);
    }
  }
}

function auditSwiftStructure(relativePath) {
  const value = source(relativePath);
  const stack = [];
  let blockCommentDepth = 0;
  let lineComment = false;
  let stringEnd = null;

  for (let index = 0; index < value.length; index += 1) {
    if (lineComment) {
      if (value[index] === "\n") lineComment = false;
      continue;
    }

    if (blockCommentDepth > 0) {
      if (value.startsWith("/*", index)) {
        blockCommentDepth += 1;
        index += 1;
      } else if (value.startsWith("*/", index)) {
        blockCommentDepth -= 1;
        index += 1;
      }
      continue;
    }

    if (stringEnd !== null) {
      if (value.startsWith(stringEnd, index)) {
        index += stringEnd.length - 1;
        stringEnd = null;
      } else if (value[index] === "\\" && !stringEnd.endsWith("#")) {
        index += 1;
      }
      continue;
    }

    if (value.startsWith("//", index)) {
      lineComment = true;
      index += 1;
      continue;
    }
    if (value.startsWith("/*", index)) {
      blockCommentDepth = 1;
      index += 1;
      continue;
    }

    const stringStart = value.slice(index).match(/^(#+)?("""|")/);
    if (stringStart) {
      const hashes = stringStart[1] ?? "";
      const quote = stringStart[2];
      stringEnd = quote + hashes;
      index += hashes.length + quote.length - 1;
      continue;
    }

    const character = value[index];
    if ("([{".includes(character)) stack.push(character);
    if (")]}".includes(character)) {
      const expected = { ")": "(", "]": "[", "}": "{" }[character];
      const actual = stack.pop();
      if (actual !== expected) {
        fail(`${relativePath} has an unmatched ${character} at byte ${index}`);
      }
    }
  }

  if (lineComment) lineComment = false;
  if (blockCommentDepth !== 0) fail(`${relativePath} has an open block comment`);
  if (stringEnd !== null) fail(`${relativePath} has an open string literal`);
  if (stack.length !== 0) fail(`${relativePath} has unclosed delimiters: ${stack.join("")}`);
}

function auditCatalog(product) {
  const stringsPath = `Features/${product}/${product}Strings.swift`;
  const catalogPath = path.join(app, `Features/${product}/${product}.xcstrings`);
  const catalog = JSON.parse(fs.readFileSync(catalogPath, "utf8"));
  const keys = Array.from(
    source(stringsPath).matchAll(/LocalizedStringResource\("([^"]+)"/g),
    (match) => match[1],
  );

  for (const key of keys) {
    const localizations = catalog.strings?.[key]?.localizations;
    if (!localizations?.ar?.stringUnit?.value) fail(`${product}: ${key} has no Arabic value`);
    if (!localizations?.en?.stringUnit?.value) fail(`${product}: ${key} has no English value`);
  }
}

// Cover the entire target, including design, shell, settings and newly added files.
// Delimiter checks are a fast preflight, never a substitute for an Xcode build.
const swiftFiles = fs.readdirSync(app, { recursive: true })
  .filter(file => file.endsWith(".swift"))
  .map(file => file.replaceAll(path.sep, "/"));
for (const file of swiftFiles) auditSwiftStructure(file);
for (const file of productFiles) source(file);
for (const product of ["Brain", "Code"]) auditCatalog(product);

// Agent is retired from both mobile apps by the owner's instruction. Legacy
// history/backup flags remain readable; the product and submission enums cannot
// represent a retired runtime destination. Old push payloads are ignored.
for (const file of ["Models/AgentModels.swift", "Stores/AgentStore.swift",
  "Features/Agent/AgentScreen.swift", "Features/Agent/AgentStrings.swift",
  "Features/Agent/Agent.xcstrings"]) {
  if (fs.existsSync(path.join(app, file))) fail(`Retired Agent source returned: ${file}`);
}
for (const file of swiftFiles) {
  const value = source(file);
  for (const forbidden of ["AgentStore", "AgentScreen", "AgentArtifactDownload",
    "agentJobStatus(", "agentArtifact(", '"/api/agent/',
    "kind: .agentRun", "chargeUsage(product: .agent", "ProductKind.agent",
    "case .agent:", "case .ai, .agent:", "case agentRun"]) {
    if (value.includes(forbidden)) fail(`${file} reintroduces Agent: ${forbidden}`);
  }
}
requireFragments("Features/Shell/ShellSidebar.swift", [
  "private let products: [ProductKind] = [.ai, .code, .brain]",
  "guard !conversation.agent else { return false }",
]);
const commonProducts = source("Models/CommonModels.swift").split("enum ProductKind:")[1];
if (!commonProducts || /case\s+agent\b/.test(commonProducts)) {
  fail("Retired Agent must not be representable by the native product enum");
}
requireFragments("Notifications/NotificationCoordinator.swift", [
  "static func isRetiredProduct(userInfo:", 'return product == "agent"',
  "guard !isRetiredProduct(userInfo: userInfo) else { return nil }",
  "let product = ProductKind(rawValue: productValue)",
]);
requireFragments("Notifications/FirasAppDelegate.swift", [
  "guard !NotificationDestination.isRetiredProduct(", "else { return [] }",
]);
requireFragments("Networking/FirasAPI.swift", ["guard product == .code else {"]);
const account = source("Features/Settings/AccountSettingsView.swift");
if (/usage\.agent|product\.agent|ShellStrings\.productTitle\(\.agent\)/.test(account)) {
  fail("Retired Agent quota is visible in account settings");
}
const shellCatalog = JSON.parse(fs.readFileSync(path.join(app, "Features/Shell/Shell.xcstrings"), "utf8"));
if (Object.keys(shellCatalog.strings).some(key => key.startsWith("product.agent."))) {
  fail("Retired Agent labels returned to the shell catalog");
}
const sharedCatalog = JSON.parse(fs.readFileSync(path.join(app, "Resources/Localizable.xcstrings"), "utf8"));
if (["nav.agent", "settings.quota.agent"].some(key => key in sharedCatalog.strings)) {
  fail("Retired Agent navigation or quota label returned to the shared catalog");
}
const common = source("Models/CommonModels.swift");
if ((common.match(/struct ArtifactDownload\b/g) ?? []).length !== 1) fail("Shared artifact DTO must remain available to media and Omnix");
const mediaFixtures = fs.readFileSync(path.join(root, "scripts/media-store-test-fixtures.swift"), "utf8");
if (/struct ArtifactDownload\b/.test(mediaFixtures)) fail("Media tests must use the production shared artifact DTO");
requireFragments("Stores/CodeStore.swift", [
  "chargeUsage(product: .code",
  "kind: initialPointer.replyOnly == true ? .chat : .codeBuild",
  "if initialPointer.replyOnly != true",
  "decision.permitsBrowserBuild",
  "classifyIntent(text: cleanPrompt",
  "prompt: cleanPrompt",
  "ownerID: pointer.ownerID",
  "ownerDirectory(ownerID)",
  "chatJobStatus(id:",
  "CodeProject.decode(fromJobText:",
  "firas.ios.code-builds.v1",
  "scheduleLocalFallbackIfNeeded",
]);
requireFragments("Stores/BrainStore.swift", [
  "brainDocuments()",
  "uploadBrainDocument",
  "deleteBrainDocument",
  "searchBrain",
  "brainPassage",
  "let maximumCharacters = 680_000",
  "let maximumRecords = 950",
  "docId: documentID",
  "ocr: index == 0 ? extracted.ocrPages : nil",
  "documentID = response.id",
]);

for (const store of ["Stores/CodeStore.swift"]) {
  const value = source(store);
  for (const forbidden of ["cancelChatJob", "onDisappear", "owningTask?.cancel()"] ) {
    if (value.includes(forbidden)) fail(`${store} contains forbidden lifecycle cancellation: ${forbidden}`);
  }
}

console.log(`CLEAN: ${swiftFiles.length} Swift files, 2 product catalogs, durable products and Agent retirement (source checks only)`);
