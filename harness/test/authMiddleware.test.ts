// authMiddleware.test.ts — HTTP-слой авторизации: bearer vs cookie vs bad_token,
// 401 vs 403, break-glass, checkOrigin (CSRF).

import { describe, it, expect } from "vitest";
import { openDb } from "../src/store/db.js";
import { UsersRepo } from "../src/store/usersRepo.js";
import { AuthService } from "../src/auth/authService.js";
import { requireUser, requireAdmin, SESSION_COOKIE } from "../src/http/authMiddleware.js";
import { checkOrigin } from "../src/http/routes.auth.js";

const TOKEN = "break-glass-token";

async function ctx(): Promise<{ auth: AuthService; adminTok: string; userTok: string; adminId: string }> {
  const auth = new AuthService(new UsersRepo(openDb(":memory:")), "");
  const admin = await auth.createUser("owner", "password1"); // первый = админ
  await auth.createUser("tester", "password2");
  const adminTok = auth.createSession(admin.id).token;
  const row = (await auth.verifyLogin("tester", "password2"))!;
  const userTok = auth.createSession(row.id).token;
  return { auth, adminTok, userTok, adminId: admin.id };
}

/** Мок FastifyRequest: cookie подписи нет — unsignCookie отдаёт value как есть. */
function req(opts: { bearer?: string; sid?: string }): any {
  return {
    headers: opts.bearer ? { authorization: "Bearer " + opts.bearer } : {},
    cookies: opts.sid ? { [SESSION_COOKIE]: opts.sid } : {},
    unsignCookie: (v: string) => ({ valid: true, value: v, renew: false }),
  };
}

async function run(hook: (req: any, reply: any) => Promise<void>, r: any): Promise<{ ok: boolean; status?: number; principal?: any }> {
  try {
    await hook(r, {});
    return { ok: true, principal: r.principal };
  } catch (e: any) {
    return { ok: false, status: e.httpStatus };
  }
}

describe("requireUser", () => {
  it("валидная cookie-сессия → пускает, principal.user есть", async () => {
    const c = await ctx();
    const res = await run(requireUser(TOKEN, c.auth), req({ sid: c.userTok }));
    expect(res.ok).toBe(true);
    expect(res.principal.user.username).toBe("tester");
  });
  it("без авторизации → 401", async () => {
    const c = await ctx();
    expect((await run(requireUser(TOKEN, c.auth), req({}))).status).toBe(401);
  });
  it("только bearer (без cookie) НЕ пускает на user-эндпоинт → 401", async () => {
    const c = await ctx();
    expect((await run(requireUser(TOKEN, c.auth), req({ bearer: TOKEN }))).status).toBe(401);
  });
  it("неверный bearer → 401 (не проваливаемся в cookie)", async () => {
    const c = await ctx();
    expect((await run(requireUser(TOKEN, c.auth), req({ bearer: "wrong", sid: c.userTok }))).status).toBe(401);
  });
});

describe("requireAdmin", () => {
  it("админ-сессия → пускает", async () => {
    const c = await ctx();
    const res = await run(requireAdmin(TOKEN, c.auth), req({ sid: c.adminTok }));
    expect(res.ok).toBe(true);
    expect(res.principal.isAdmin).toBe(true);
  });
  it("обычный юзер → 403", async () => {
    const c = await ctx();
    expect((await run(requireAdmin(TOKEN, c.auth), req({ sid: c.userTok }))).status).toBe(403);
  });
  it("break-glass bearer → пускает", async () => {
    const c = await ctx();
    expect((await run(requireAdmin(TOKEN, c.auth), req({ bearer: TOKEN }))).ok).toBe(true);
  });
  it("аноним → 401", async () => {
    const c = await ctx();
    expect((await run(requireAdmin(TOKEN, c.auth), req({}))).status).toBe(401);
  });
});

describe("checkOrigin (CSRF)", () => {
  it("нет Origin (curl) → пропускает", () => {
    expect(() => checkOrigin({ headers: { host: "x" } })).not.toThrow();
  });
  it("Origin совпадает с Host → пропускает", () => {
    expect(() => checkOrigin({ headers: { origin: "https://h.example", host: "h.example" } })).not.toThrow();
  });
  it("Origin != Host → бросает", () => {
    expect(() => checkOrigin({ headers: { origin: "https://evil.example", host: "h.example" } })).toThrow();
  });
});
