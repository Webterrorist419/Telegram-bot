use rusqlite::{Connection, params};
use std::{env, sync::{Arc, Mutex}};
use teloxide::{prelude::*, types::{InlineKeyboardButton, InlineKeyboardMarkup}};

type Db = Arc<Mutex<Connection>>;

#[derive(Clone, Copy, PartialEq)]
enum Lang { Ru, En }

impl Lang {
    fn parse(s: &str) -> Self { if s.eq_ignore_ascii_case("en") { Self::En } else { Self::Ru } }
    fn code(self) -> &'static str { match self { Self::Ru => "ru", Self::En => "en" } }
    fn pick(self, ru: &str, en: &str) -> String { match self { Self::Ru => ru, Self::En => en }.to_owned() }
}

fn db_init(db: &Db) -> rusqlite::Result<()> {
    let c = db.lock().unwrap();
    c.execute_batch("PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS users (telegram_id INTEGER PRIMARY KEY, lang TEXT NOT NULL DEFAULT 'ru', started_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
        CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS admin_state (telegram_id INTEGER PRIMARY KEY, action TEXT NOT NULL);")?;
    for (key, value) in [
        ("description_ru", "Добро пожаловать! Выберите нужную ссылку."), ("description_en", "Welcome! Choose a link."),
        ("button1_label_ru", "Ссылка 1"), ("button1_label_en", "Link 1"), ("button1_url", "https://example.com"), ("button1_enabled", "1"),
        ("button2_label_ru", "Ссылка 2"), ("button2_label_en", "Link 2"), ("button2_url", "https://example.com"), ("button2_enabled", "1"),
        ("button3_label_ru", "Ссылка 3"), ("button3_label_en", "Link 3"), ("button3_url", "https://example.com"), ("button3_enabled", "1"),
    ] { c.execute("INSERT OR IGNORE INTO settings(key,value) VALUES(?1,?2)", params![key, value])?; }
    Ok(())
}

fn get(db: &Db, key: &str) -> String {
    db.lock().unwrap().query_row("SELECT value FROM settings WHERE key=?1", [key], |r| r.get(0)).unwrap_or_default()
}
fn put(db: &Db, key: &str, value: &str) {
    let _ = db.lock().unwrap().execute("INSERT INTO settings(key,value) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value", params![key, value]);
}
fn user_lang(db: &Db, id: i64) -> Lang {
    db.lock().unwrap().query_row("SELECT lang FROM users WHERE telegram_id=?1", [id], |r| r.get::<_, String>(0)).map(|s| Lang::parse(&s)).unwrap_or(Lang::Ru)
}
fn record_user(db: &Db, id: i64) {
    let _ = db.lock().unwrap().execute("INSERT OR IGNORE INTO users(telegram_id) VALUES(?1)", [id]);
}
fn is_admin(id: i64, admin: i64) -> bool { admin > 0 && id == admin }

fn main_keyboard(db: &Db, lang: Lang, admin: bool) -> InlineKeyboardMarkup {
    let mut rows = Vec::new();
    for n in 1..=3 {
        if get(db, &format!("button{n}_enabled")) == "1" {
            let label = get(db, &format!("button{n}_label_{}", lang.code()));
            let url = get(db, &format!("button{n}_url"));
            if let Ok(parsed) = url::Url::parse(&url) {
                if parsed.scheme() == "https" || parsed.scheme() == "http" { rows.push(vec![InlineKeyboardButton::url(label, parsed)]); }
            }
        }
    }
    rows.push(vec![InlineKeyboardButton::callback(lang.pick("🌐 Язык: RU / EN", "🌐 Language: EN / RU"), "language")]);
    if admin { rows.push(vec![InlineKeyboardButton::callback(lang.pick("⚙️ Админ меню", "⚙️ Admin menu"), "admin")]); }
    InlineKeyboardMarkup::new(rows)
}

fn admin_keyboard(lang: Lang) -> InlineKeyboardMarkup {
    let ru = lang == Lang::Ru;
    let mut rows = Vec::new();
    for n in 1..=3 {
        let label = if ru { format!("Ссылка {n}: URL / текст / вкл-выкл") } else { format!("Link {n}: URL / label / on-off") };
        rows.push(vec![InlineKeyboardButton::callback(label, format!("button_{n}"))]);
    }
    rows.push(vec![InlineKeyboardButton::callback(if ru { "Описание бота" } else { "Bot description" }, "description")]);
    rows.push(vec![InlineKeyboardButton::callback(if ru { "📊 Статистика" } else { "📊 Statistics" }, "stats")]);
    rows.push(vec![InlineKeyboardButton::callback(if ru { "🗑 Сбросить статистику" } else { "🗑 Reset statistics" }, "reset"),
                   InlineKeyboardButton::callback(if ru { "↩️ В меню" } else { "↩️ Main menu" }, "home")]);
    rows.push(vec![InlineKeyboardButton::callback(if ru { "🌐 Язык: RU / EN" } else { "🌐 Language: EN / RU" }, "language")]);
    InlineKeyboardMarkup::new(rows)
}

fn button_keyboard(db: &Db, lang: Lang, n: &str) -> InlineKeyboardMarkup {
    let ru = lang == Lang::Ru;
    let enabled = get(db, &format!("button{n}_enabled")) == "1";
    InlineKeyboardMarkup::new(vec![
        vec![InlineKeyboardButton::callback(if ru { "Изменить URL" } else { "Change URL" }, format!("edit_url_{n}"))],
        vec![InlineKeyboardButton::callback(if ru { "Текст кнопки (RU)" } else { "Button text (RU)" }, format!("edit_label_{n}_ru"))],
        vec![InlineKeyboardButton::callback(if ru { "Текст кнопки (EN)" } else { "Button text (EN)" }, format!("edit_label_{n}_en"))],
        vec![InlineKeyboardButton::callback(if enabled { if ru { "🔴 Выключить" } else { "🔴 Disable" } } else if ru { "🟢 Включить" } else { "🟢 Enable" }, format!("toggle_{n}"))],
        vec![InlineKeyboardButton::callback(if ru { "↩️ Админ меню" } else { "↩️ Admin menu" }, "admin")],
        vec![InlineKeyboardButton::callback(if ru { "🌐 Язык: RU / EN" } else { "🌐 Language: EN / RU" }, "language")],
    ])
}

async fn send_home(bot: &Bot, db: &Db, id: i64, admin_id: i64, lang: Lang) -> ResponseResult<()> {
    let desc = get(db, &format!("description_{}", lang.code()));
    bot.send_message(ChatId(id), desc).reply_markup(main_keyboard(db, lang, is_admin(id, admin_id))).await?;
    Ok(())
}

async fn delete_callback_message(bot: &Bot, q: &CallbackQuery) {
    if let Some(message) = q.regular_message() {
        // Old or already removed Telegram messages can no longer be deleted.
        let _ = bot.delete_message(message.chat.id, message.id).await;
    }
}

async fn on_message(bot: Bot, msg: Message, db: Db, admin_id: i64) -> ResponseResult<()> {
    let Some(text) = msg.text() else { return Ok(()); };
    let id = msg.chat.id.0;
    let lang = user_lang(&db, id);
    if text.starts_with("/start") {
        if is_admin(id, admin_id) { let _ = db.lock().unwrap().execute("DELETE FROM admin_state WHERE telegram_id=?1", [id]); }
        record_user(&db, id);
        return send_home(&bot, &db, id, admin_id, user_lang(&db, id)).await;
    }
    if !is_admin(id, admin_id) { return Ok(()); }
    let action: Option<String> = db.lock().unwrap().query_row("SELECT action FROM admin_state WHERE telegram_id=?1", [id], |r| r.get(0)).ok();
    if let Some(action) = action {
        let mut reply = lang.pick("Сохранено.", "Saved.");
        if action.starts_with("url:") {
            let n = action.trim_start_matches("url:");
            if url::Url::parse(text).map(|u| u.scheme() == "https" || u.scheme() == "http").unwrap_or(false) { put(&db, &format!("button{n}_url"), text); }
            else { reply = lang.pick("Нужна ссылка с http:// или https://. Настройка не изменена.", "Enter a URL starting with http:// or https://. Setting unchanged."); }
        } else if action.starts_with("label:") {
            let mut p = action.split(':'); let _ = p.next(); let n = p.next().unwrap_or("1"); let lc = p.next().unwrap_or("ru");
            put(&db, &format!("button{n}_label_{lc}"), text);
        } else if action.starts_with("desc:") {
            let lc = action.trim_start_matches("desc:"); put(&db, &format!("description_{lc}"), text);
        }
        let _ = db.lock().unwrap().execute("DELETE FROM admin_state WHERE telegram_id=?1", [id]);
        bot.send_message(msg.chat.id, reply).await?;
        bot.send_message(msg.chat.id, lang.pick("Настройки сохранены.", "Settings saved.")).reply_markup(admin_keyboard(lang)).await?;
    } else {
        bot.send_message(msg.chat.id, lang.pick("Откройте админ меню кнопкой под сообщением.", "Open the admin menu with the button below.")).reply_markup(main_keyboard(&db, lang, true)).await?;
    }
    Ok(())
}

async fn on_callback(bot: Bot, q: CallbackQuery, db: Db, admin_id: i64) -> ResponseResult<()> {
    let data = q.data.as_deref().unwrap_or("");
    let id = q.from.id.0 as i64;
    let chat = ChatId(id);
    if data == "stats" && is_admin(id, admin_id) {
        let count: i64 = db.lock().unwrap().query_row("SELECT COUNT(*) FROM users", [], |r| r.get(0)).unwrap_or(0);
        let lang = user_lang(&db, id);
        let text = lang.pick(&format!("Пользователей: {count}"), &format!("Users: {count}"));
        bot.answer_callback_query(q.id.clone()).text(text).show_alert(true).await?;
        return Ok(());
    }
    bot.answer_callback_query(q.id.clone()).await?;
    if data == "language" {
        delete_callback_message(&bot, &q).await;
        let new_lang = if user_lang(&db, id) == Lang::Ru { "en" } else { "ru" };
        record_user(&db, id);
        let _ = db.lock().unwrap().execute("UPDATE users SET lang=?1 WHERE telegram_id=?2", params![new_lang, id]);
        return send_home(&bot, &db, id, admin_id, Lang::parse(new_lang)).await;
    }
    if !is_admin(id, admin_id) { return Ok(()); }
    delete_callback_message(&bot, &q).await;
    let lang = user_lang(&db, id);
    match data {
        "admin" => { bot.send_message(chat, lang.pick("Админ меню:", "Admin menu:")).reply_markup(admin_keyboard(lang)).await?; }
        "home" => { send_home(&bot, &db, id, admin_id, lang).await?; }
        "reset" => {
            db.lock().unwrap().execute("DELETE FROM users", []).ok();
            bot.send_message(chat, lang.pick("Статистика очищена. Пользователи будут учтены снова после /start.", "Statistics cleared. Users will be counted again when they send /start.")).reply_markup(admin_keyboard(lang)).await?;
        }
        "description" => {
            let _ = db.lock().unwrap().execute("INSERT INTO admin_state(telegram_id,action) VALUES(?1,?2) ON CONFLICT(telegram_id) DO UPDATE SET action=excluded.action", params![id, format!("desc:{}", lang.code())]);
            bot.send_message(chat, lang.pick("Отправьте новое описание на текущем языке:", "Send the new description in the current language:")).await?;
        }
        "button_1" | "button_2" | "button_3" => {
            let n = data.trim_start_matches("button_");
            bot.send_message(chat, lang.pick(&format!("Настройки кнопки {n}:",), &format!("Button {n} settings:"))).reply_markup(button_keyboard(&db, lang, n)).await?;
        }
        "toggle_1" | "toggle_2" | "toggle_3" => {
            let n = data.trim_start_matches("toggle_");
            let enabled = get(&db, &format!("button{n}_enabled")) == "1";
            put(&db, &format!("button{n}_enabled"), if enabled { "0" } else { "1" });
            bot.send_message(chat, lang.pick("Состояние кнопки сохранено.", "Button state saved.")).reply_markup(button_keyboard(&db, lang, n)).await?;
        }
        _ if data.starts_with("edit_url_") => {
            let n = data.trim_start_matches("edit_url_");
            let _ = db.lock().unwrap().execute("INSERT INTO admin_state(telegram_id,action) VALUES(?1,?2) ON CONFLICT(telegram_id) DO UPDATE SET action=excluded.action", params![id, format!("url:{n}")]);
            bot.send_message(chat, lang.pick("Отправьте новый URL (http:// или https://).", "Send a new URL (http:// or https://)." )).await?;
        }
        _ if data.starts_with("edit_label_") => {
            let mut p = data.trim_start_matches("edit_label_").split('_'); let n = p.next().unwrap_or("1"); let lc = p.next().unwrap_or("ru");
            let _ = db.lock().unwrap().execute("INSERT INTO admin_state(telegram_id,action) VALUES(?1,?2) ON CONFLICT(telegram_id) DO UPDATE SET action=excluded.action", params![id, format!("label:{n}:{lc}")]);
            bot.send_message(chat, lang.pick(&format!("Отправьте новый текст кнопки {n} на языке {}.", lc.to_uppercase()), &format!("Send new text for button {n} in {}.", lc.to_uppercase()))).await?;
        }
        _ => {}
    }
    Ok(())
}

#[tokio::main]
async fn main() {
    let _ = dotenvy::from_filename("config.env");
    let token = env::var("BOT_TOKEN").expect("BOT_TOKEN is missing in config.env");
    let admin_id: i64 = env::var("ADMIN_ID").expect("ADMIN_ID is missing in config.env").parse().expect("ADMIN_ID must be a Telegram numeric ID");
    let db_path = env::var("DATABASE_PATH").unwrap_or_else(|_| "bot.sqlite3".into());
    let db = Arc::new(Mutex::new(Connection::open(db_path).expect("Cannot open SQLite database")));
    db_init(&db).expect("Cannot initialize database");
    let bot = Bot::new(token);
    let handler = dptree::entry()
        .branch(Update::filter_message().endpoint(on_message))
        .branch(Update::filter_callback_query().endpoint(on_callback));
    Dispatcher::builder(bot, handler).dependencies(dptree::deps![db, admin_id]).enable_ctrlc_handler().build().dispatch().await;
}
