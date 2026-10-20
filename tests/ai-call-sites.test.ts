import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";

import ts from "typescript";
import { describe, expect, it } from "vitest";

// BYOK (결제 계약 6.2 · 16.1): 사용자 경로의 AI 호출은 모두 budgetFetch를 지난다. 그곳에서만 Lifetime 사용자의 키로 바꾸고(헤더 교체),
// 관리형 원가 장부에 쓸지를 정한다. 여기서 `llmConfigFromEnv()` 같은 설정(관리형 OPENROUTER_API_KEY가 든다)만 쓰고 fetch를 직접 두면
// 그 호출은 Lifetime 사용자의 것이어도 Taskforce의 키로 나간다. 그래서 설정을 만드는 호출 지점의 목록을 고정하고, 목록의 곳마다 짝을 확인한다.
// 짝은 "같은 파일에 budgetFetch가 있다"가 아니라 "그 설정에 넘기는 fetch가 실제로 budgetFetch다"이다(코드를 TypeScript 구문 트리로 읽어 따라간다):
//   { ...xConfigFromEnv(), fetch: budgetFetch(…) }            바로 넘김
//   const fetch = budgetFetch(…); { ...xConfigFromEnv(), fetch }   같은 범위의 변수(단축 속성)
//   const guarded = async (i, n) => { …; return budgetedFetch(i, n); }   budgetFetch로 만든 fetch를 부르는 함수로 감싼 것
// 목록에 없는 새 호출 지점은 이 시험이 막는다: 짝을 지은 뒤 목록에 더하거나, 사용자가 없는 관리형 작업이면 이유를 적어 EXEMPT에 더한다.

const ROOT = path.resolve(__dirname, "..");
const CONFIG_FUNCTION = /^(llm|jev|embed|generation)ConfigFromEnv$/;
const COMMENT = /^\s*(\/\/|\/?\*)/;

/** 사용자 없이 관리형 키로만 도는 작업. 사용자 호출이 아니므로 budgetFetch가 없다 */
const EXEMPT: Record<string, string> = {
  "src/lib/ai/budget.ts": "정산하지 못한 시도의 generation을 관리형 키로 찾는 sweep (BYOK 호출은 원가 장부 행이 없어 대상이 아니다)",
  "src/app/api/cron/execution-sweep/route.ts": "실행 영수증의 generation 비용을 관리형 키로 찾는 cron (사용자 호출이 아니다)",
};

/** 사용자 경로에서 설정을 만드는 파일 전부: 모두 넘기는 fetch가 budgetFetch여야 한다 */
const USER_PATH_SITES = [
  "src/app/api/v1/actions/route.ts",
  "src/lib/ai/handoff.ts",
  "src/lib/api/ask-store.ts",
  "src/lib/context/store.ts",
  "src/lib/conversation/store.ts",
  "src/lib/execution/wake.ts",
  "src/lib/sources/process.ts",
];

function walk(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, out);
    else if (/\.(ts|tsx)$/.test(entry.name) && !/\.test\.tsx?$/.test(entry.name)) out.push(full);
  }
  return out;
}

type Finding = { file: string; problem: string };

const parse = (file: string, text: string) => ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, file.endsWith("x") ? ts.ScriptKind.TSX : ts.ScriptKind.TS);

function visit(node: ts.Node, each: (node: ts.Node) => void) {
  each(node);
  ts.forEachChild(node, (child) => visit(child, each));
}

/** `xConfigFromEnv(…)` 호출 식 전부 (정의 · import · 주석 · 문자열은 호출 식이 아니라서 저절로 빠진다) */
function configCalls(sourceFile: ts.SourceFile): ts.CallExpression[] {
  const calls: ts.CallExpression[] = [];
  visit(sourceFile, (node) => {
    if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && CONFIG_FUNCTION.test(node.expression.text)) calls.push(node);
  });
  return calls;
}

const strip = (node: ts.Node): ts.Node => (ts.isParenthesizedExpression(node) || ts.isAsExpression(node) || ts.isNonNullExpression(node) || ts.isSatisfiesExpression(node) ? strip(node.expression) : node);

/** 이름 하나가 가리키는 선언: 사용처에서 바깥으로 나가며 가장 가까운 범위(블록 · 함수 · 파일)의 직접 선언을 찾는다 */
function declarationOf(identifier: ts.Identifier): ts.VariableDeclaration | ts.ParameterDeclaration | null {
  for (let scope: ts.Node | undefined = identifier.parent; scope; scope = scope.parent) {
    if (ts.isFunctionLike(scope)) {
      const parameter = scope.parameters.find((p) => ts.isIdentifier(p.name) && p.name.text === identifier.text);
      if (parameter) return parameter;
    }
    const statements = ts.isBlock(scope) || ts.isSourceFile(scope) || ts.isModuleBlock(scope) ? scope.statements : undefined;
    if (statements) {
      for (const statement of statements) {
        if (!ts.isVariableStatement(statement)) continue;
        const declaration = statement.declarationList.declarations.find((d) => ts.isIdentifier(d.name) && d.name.text === identifier.text);
        if (declaration) return declaration;
      }
    }
  }
  return null;
}

/** 이 식이 budgetFetch(…)로 만든 fetch(또는 그것을 부르는 함수)인가 */
function isBudgeted(node: ts.Node, depth = 0): boolean {
  if (depth > 8) return false;
  const expression = strip(node);
  if (ts.isCallExpression(expression)) return ts.isIdentifier(expression.expression) && expression.expression.text === "budgetFetch";
  if (ts.isIdentifier(expression)) {
    const declaration = declarationOf(expression);
    return !!declaration && ts.isVariableDeclaration(declaration) && !!declaration.initializer && isBudgeted(declaration.initializer, depth + 1);
  }
  if (ts.isArrowFunction(expression) || ts.isFunctionExpression(expression)) {
    let calls = false;
    visit(expression.body, (inner) => {
      if (ts.isCallExpression(inner) && ts.isIdentifier(inner.expression) && isBudgeted(inner.expression, depth + 1)) calls = true;
    });
    return calls;
  }
  return false;
}

function judge(call: ts.CallExpression): string | null {
  const spread = call.parent;
  if (!ts.isSpreadAssignment(spread) || !ts.isObjectLiteralExpression(spread.parent)) return "설정이 { ...설정(), fetch } 모양으로 쓰이지 않는다";
  const property = spread.parent.properties.find(
    (p) => (ts.isPropertyAssignment(p) || ts.isShorthandPropertyAssignment(p)) && ts.isIdentifier(p.name) && p.name.text === "fetch",
  );
  if (!property) return "설정에 fetch를 넘기지 않는다";
  const passed = ts.isPropertyAssignment(property) ? property.initializer : (property as ts.ShorthandPropertyAssignment).name;
  return isBudgeted(passed) ? null : "넘기는 fetch가 budgetFetch가 아니다";
}

/** files: 저장소 기준 경로 → 내용 (시험이 아닌 소스). 설정 호출이 있는 파일을 찾아 짝을 확인한다 */
function check(files: Record<string, string>, exempt: Record<string, string>): { sites: string[]; findings: Finding[] } {
  const sites: string[] = [];
  const findings: Finding[] = [];
  for (const [file, text] of Object.entries(files).sort(([a], [b]) => a.localeCompare(b))) {
    if (!/ConfigFromEnv/.test(text)) continue;
    const calls = configCalls(parse(file, text));
    if (calls.length === 0 || file in exempt) continue;
    sites.push(file);
    for (const call of calls) {
      const problem = judge(call);
      if (problem) findings.push({ file, problem });
    }
  }
  return { sites, findings };
}

describe("사용자 경로의 AI 호출은 budgetFetch와 짝이다", () => {
  const files = Object.fromEntries(walk(path.join(ROOT, "src")).map((file) => [path.relative(ROOT, file), readFileSync(file, "utf8")]));
  const result = check(files, EXEMPT);

  it("설정을 만드는 호출 지점의 목록이 고정돼 있다 (새 곳은 짝을 짓고 목록에 더한다)", () => {
    expect(result.sites).toEqual(USER_PATH_SITES);
  });

  it("목록의 곳마다 설정에 넘기는 fetch가 실제로 budgetFetch(또는 그것을 부르는 함수)다", () => {
    expect(result.findings).toEqual([]);
  });

  it("예외는 이유가 적혀 있고 실제로 설정을 만드는 곳이다 (쓰지 않는 예외를 남기지 않는다)", () => {
    for (const [file, reason] of Object.entries(EXEMPT)) {
      expect(reason.length, file).toBeGreaterThan(10);
      expect(files[file], file).toBeDefined();
      expect(configCalls(parse(file, files[file])).length, file).toBeGreaterThan(0);
    }
  });

  it("src 안에서 관리형 키(OPENROUTER_API_KEY)를 직접 읽는 곳은 설정 함수들뿐이다", () => {
    const readers = Object.entries(files)
      .filter(([, text]) => text.split("\n").some((line) => /process\.env\.OPENROUTER_API_KEY|env\.OPENROUTER_API_KEY/.test(line) && !COMMENT.test(line)))
      .map(([file]) => file);
    expect(readers).toEqual(["src/lib/ai/embed.ts", "src/lib/ai/generation.ts", "src/lib/ai/jev.ts", "src/lib/ai/llm.ts"]);
  });

  it("실제 호출 지점마다, budgetFetch를 다른 이름으로 바꾸면(짝을 깨면) 검사기가 그 파일을 잡는다", () => {
    for (const site of USER_PATH_SITES) {
      const broken = files[site].replace(/\bbudgetFetch\(/g, "notBudgetFetch(");
      expect(broken, site).not.toBe(files[site]);
      expect(check({ ...files, [site]: broken }, EXEMPT).findings.map((f) => f.file), site).toContain(site);
    }
  });

  it("실제 호출 지점마다, 넘기는 fetch를 전역 fetch로 바꾸면 budgetFetch 글자가 남아 있어도 잡는다", () => {
    let changed = 0;
    for (const site of USER_PATH_SITES) {
      // budgetFetch(…)로 만든 변수의 초기값만 전역 fetch로 바꾸고, budgetFetch 글자는 파일에 남겨 둔다("같은 파일에 있다"로는 통과하는 모양)
      const broken = files[site].replace(/\b(const|let) (fetch|budgetedFetch)\b([^=]*)=\s*budgetFetch\([^;]*;/, "$1 $2$3= globalThis.fetch; void budgetFetch;");
      if (broken === files[site]) continue; // 이 파일은 budgetFetch를 설정 객체 안에서 바로 넘긴다(위 시험이 덮는다)
      changed++;
      expect(broken, site).toContain("budgetFetch");
      expect(check({ ...files, [site]: broken }, EXEMPT).findings.map((f) => f.file), site).toContain(site);
    }
    expect(changed).toBeGreaterThanOrEqual(4);
  });

  // 검사기 자체: 짝을 깬 입력을 실제로 잡는다
  describe("검사기", () => {
    const flagged = (code: string) => check({ "src/x.ts": code }, {}).findings;
    const paired = "const fetch = budgetFetch(admin, userId);\nconst llm = { ...llmConfigFromEnv(), fetch };\n";

    it("짝이 맞으면 통과한다", () => {
      expect(check({ "src/x.ts": paired }, {})).toEqual({ sites: ["src/x.ts"], findings: [] });
    });
    it("budgetFetch 없이 설정만 만들면 잡는다", () => {
      expect(flagged("const llm = { ...llmConfigFromEnv(), fetch };\n")).toEqual([{ file: "src/x.ts", problem: "넘기는 fetch가 budgetFetch가 아니다" }]);
    });
    it("budgetFetch가 있어도 설정 호출이 fetch를 넘기지 않으면 잡는다", () => {
      expect(flagged("const fetch = budgetFetch(admin, userId);\nconst llm = llmConfigFromEnv();\nuse(fetch);\n")).toEqual([
        { file: "src/x.ts", problem: "설정이 { ...설정(), fetch } 모양으로 쓰이지 않는다" },
      ]);
      expect(flagged("const fetch = budgetFetch(admin, userId);\nconst llm = { ...llmConfigFromEnv(), deadline };\nuse(fetch);\n")).toEqual([
        { file: "src/x.ts", problem: "설정에 fetch를 넘기지 않는다" },
      ]);
    });
    it.each(["jev", "embed", "generation"])("%s 설정도 같다", (kind) => {
      expect(flagged(`const c = { ...${kind}ConfigFromEnv(), fetch };\n`)).toHaveLength(1);
      expect(flagged(`const fetch = budgetFetch(a, b);\nconst c = { ...${kind}ConfigFromEnv(), fetch };\n`)).toHaveLength(0);
    });
    it("정의 · import · 주석 · 문자열과 예외 파일은 세지 않는다", () => {
      const text = "import { llmConfigFromEnv } from './llm';\nexport function llmConfigFromEnv(env = process.env) {}\n// llmConfigFromEnv() 설명\n/* jevConfigFromEnv() */\nconst s = 'embedConfigFromEnv()';\n";
      expect(check({ "src/x.ts": text }, {})).toEqual({ sites: [], findings: [] });
      expect(check({ "src/y.ts": "const c = generationConfigFromEnv();\n" }, { "src/y.ts": "사용자가 없는 관리형 작업" })).toEqual({ sites: [], findings: [] });
    });

    describe("선언만 나란히 있는 것은 짝이 아니다 (넘기는 fetch가 실제로 budgetFetch여야 한다)", () => {
      it("budgetFetch를 만들어 놓고 다른 fetch를 넘기면 잡는다", () => {
        expect(flagged("const unused = budgetFetch(admin, userId);\nconst fetch = globalThis.fetch;\nconst llm = { ...llmConfigFromEnv(), fetch };\n")).toHaveLength(1);
        expect(flagged("const unused = budgetFetch(admin, userId);\nconst llm = { ...llmConfigFromEnv(), fetch: globalThis.fetch };\n")).toHaveLength(1);
        expect(flagged("const unused = budgetFetch(admin, userId);\nconst llm = { ...llmConfigFromEnv(), fetch: other };\n")).toHaveLength(1);
        expect(flagged("const unused = budgetFetch(admin, userId);\nfunction f(fetch) { return { ...llmConfigFromEnv(), fetch }; }\n")).toHaveLength(1);
      });
      it("다른 함수의 budgetFetch는 이 호출의 짝이 아니다", () => {
        expect(flagged("function a() { const fetch = budgetFetch(admin, userId); return fetch; }\nfunction b() { const fetch = globalThis.fetch; return { ...llmConfigFromEnv(), fetch }; }\n")).toHaveLength(1);
      });
      it("안쪽 범위가 이름을 가리면(shadow) 안쪽 선언을 따른다", () => {
        expect(flagged("const fetch = budgetFetch(admin, userId);\nfunction f() { const fetch = globalThis.fetch; return { ...llmConfigFromEnv(), fetch }; }\n")).toHaveLength(1);
        expect(flagged("const fetch = globalThis.fetch;\nfunction f() { const fetch = budgetFetch(admin, userId); return { ...llmConfigFromEnv(), fetch }; }\n")).toHaveLength(0);
      });
      it("올바른 짝은 통과한다: 바로 넘김 · 변수 · 감싼 함수 · 형 표기", () => {
        expect(flagged("const llm = { ...llmConfigFromEnv(), fetch: budgetFetch(admin, userId) };\n")).toHaveLength(0);
        expect(flagged("function f() { const fetch = budgetFetch(admin, userId); return { ...jevConfigFromEnv(), deadline, fetch }; }\n")).toHaveLength(0);
        expect(flagged("function f() { const fetch: typeof globalThis.fetch = budgetFetch(admin, userId); return { ...jevConfigFromEnv(), fetch }; }\n")).toHaveLength(0);
        expect(flagged("function f() { const b = budgetFetch(admin, userId); const guarded: typeof fetch = async (i, n) => { await gate(); return b(i, n); }; return { ...llmConfigFromEnv(), fetch: guarded }; }\n")).toHaveLength(0);
      });
      it("감싼 함수가 budgetFetch로 만든 fetch를 부르지 않으면 잡는다", () => {
        expect(flagged("function f() { const b = budgetFetch(admin, userId); const guarded: typeof fetch = async (i, n) => { await gate(); return globalThis.fetch(i, n); }; use(b); return { ...llmConfigFromEnv(), fetch: guarded }; }\n")).toHaveLength(1);
      });
      it("서로를 가리키는 선언이 돌고 돌아도 끝난다 (깊이 제한)", () => {
        expect(flagged("const a = b;\nconst b = a;\nconst llm = { ...llmConfigFromEnv(), fetch: a };\n")).toHaveLength(1);
      });
    });
  });
});
