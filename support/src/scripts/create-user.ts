// create-user.ts — CLI для заведения пользователя веб-интерфейса напрямую в БД
// (закрытая регистрация; первый admin-аккаунт заводится так).
//
// Запуск на VPS:
//   node /opt/support-assistant/dist/scripts/create-user.js <username> <password> [--admin] [--email=a@b.c]
// Путь к БД берётся из SUPPORT_DB_PATH (как у сервиса). email связывает аккаунт
// с записью CRM (users.json) — по нему ассистент подтягивает тикеты клиента.

import { openDb } from "../store/db.js";
import { UsersRepo } from "../store/usersRepo.js";
import { AuthService } from "../auth/authService.js";

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const isAdmin = args.includes("--admin");
  const emailArg = args.find((a) => a.startsWith("--email="));
  const email = emailArg ? emailArg.slice("--email=".length) : "";
  const positional = args.filter((a) => !a.startsWith("--"));
  const [username, password] = positional;
  if (!username || !password) {
    console.error("Использование: create-user.js <username> <password> [--admin] [--email=a@b.c]");
    process.exit(2);
  }

  const dbPath = (process.env.SUPPORT_DB_PATH ?? "/opt/support-assistant/data/support.db").trim();
  const db = openDb(dbPath);
  const auth = new AuthService(new UsersRepo(db));
  try {
    const user = await auth.createUser(username, password, { email, isAdmin });
    console.log(
      `✓ Создан пользователь «${user.username}» (id=${user.id}, admin=${user.isAdmin}, email=${user.email || "—"}).`,
    );
  } catch (e) {
    console.error(`Ошибка: ${(e as Error).message}`);
    process.exit(1);
  } finally {
    db.close();
  }
}

main();
