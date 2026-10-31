-- =====================================================================
-- Cơ sở dữ liệu: Ứng dụng quản lý và tối ưu chi tiêu cá nhân thông minh
-- Hệ quản trị: PostgreSQL 15+
-- Quy ước:
--   * Khóa chính dạng UUID (gen_random_uuid) để không đoán được mã bản ghi.
--   * Số tiền lưu kiểu BIGINT theo đơn vị đồng (VND không có phần lẻ).
--   * Thời gian lưu TIMESTAMPTZ (UTC), app hiển thị theo múi giờ người dùng.
--   * Giá trị liệt kê dùng VARCHAR + CHECK để dễ mở rộng.
--   * Ảnh giao dịch lưu ở kho tệp riêng tư; CSDL chỉ lưu thông tin về tệp.
--   * Bảng chứa dữ liệu của người dùng đều có cột user_id; khóa ngoại
--     ghép (id, user_id) bảo đảm ví/danh mục được tham chiếu thuộc
--     đúng người dùng đó ngay ở tầng CSDL.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Hàm bỏ dấu tiếng Việt dùng được trong chỉ mục (unaccent gốc không IMMUTABLE)
CREATE OR REPLACE FUNCTION f_unaccent(text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
AS $$ SELECT lower(public.unaccent('public.unaccent'::regdictionary, $1)) $$;

-- Tự cập nhật cột updated_at
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------
-- 1. users: tài khoản người dùng (UC01, UC02)
-- ---------------------------------------------------------------------
CREATE TABLE users (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  full_name           VARCHAR(100) NOT NULL,
  email               VARCHAR(255) NOT NULL,
  password_hash       TEXT         NOT NULL,             -- bcrypt/argon2, có salt
  failed_login_count  SMALLINT     NOT NULL DEFAULT 0,
  locked_until        TIMESTAMPTZ,                       -- khóa 15 phút sau 5 lần sai
  created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
  CONSTRAINT chk_users_email CHECK (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  CONSTRAINT chk_users_failed CHECK (failed_login_count >= 0)
);
CREATE UNIQUE INDEX uq_users_email ON users (lower(email));
CREATE TRIGGER trg_users_updated BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------
-- 2. user_settings: cài đặt đồng bộ theo tài khoản (UC10, UC13)
--    (Mã PIN và cờ khóa ứng dụng chỉ lưu trên thiết bị, không lưu server)
-- ---------------------------------------------------------------------
CREATE TABLE user_settings (
  user_id                UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  budget_alerts_enabled  BOOLEAN     NOT NULL DEFAULT TRUE,
  smart_alerts_enabled   BOOLEAN     NOT NULL DEFAULT TRUE,
  timezone               VARCHAR(50) NOT NULL DEFAULT 'Asia/Ho_Chi_Minh',
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_user_settings_updated BEFORE UPDATE ON user_settings
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------
-- 3. refresh_tokens: phiên đăng nhập, refresh token xoay vòng (UC02)
-- ---------------------------------------------------------------------
CREATE TABLE refresh_tokens (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  family_id    UUID        NOT NULL,                     -- chuỗi token của cùng một phiên
  token_hash   TEXT        NOT NULL UNIQUE,              -- chỉ lưu bản băm SHA-256
  replaced_by  UUID        REFERENCES refresh_tokens(id) ON DELETE SET NULL,
  device_name  VARCHAR(100),
  expires_at   TIMESTAMPTZ NOT NULL,
  revoked_at   TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_refresh_tokens_user   ON refresh_tokens (user_id);
CREATE INDEX ix_refresh_tokens_family ON refresh_tokens (family_id);

-- ---------------------------------------------------------------------
-- 4. device_tokens: mã thiết bị nhận thông báo đẩy (UC10, UC13)
-- ---------------------------------------------------------------------
CREATE TABLE device_tokens (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  push_token    TEXT        NOT NULL UNIQUE,
  platform      VARCHAR(10) NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_device_platform CHECK (platform IN ('android', 'ios'))
);
CREATE INDEX ix_device_tokens_user ON device_tokens (user_id);

-- ---------------------------------------------------------------------
-- 5. wallets: ví (UC04)
-- ---------------------------------------------------------------------
CREATE TABLE wallets (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name         VARCHAR(30) NOT NULL,
  type         VARCHAR(10) NOT NULL,
  balance      BIGINT      NOT NULL DEFAULT 0,          -- cập nhật cùng transaction với giao dịch
  is_archived  BOOLEAN     NOT NULL DEFAULT FALSE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_wallet_type CHECK (type IN ('cash', 'bank', 'ewallet')),
  CONSTRAINT uq_wallets_id_user UNIQUE (id, user_id)
);
CREATE UNIQUE INDEX uq_wallets_user_name ON wallets (user_id, lower(name));
CREATE TRIGGER trg_wallets_updated BEFORE UPDATE ON wallets
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------
-- 6. categories: danh mục thu/chi (UC05)
--    Bộ danh mục mặc định được sao chép cho từng người dùng khi đăng ký.
-- ---------------------------------------------------------------------
CREATE TABLE categories (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name        VARCHAR(30) NOT NULL,
  type        VARCHAR(10) NOT NULL,
  icon        VARCHAR(30) NOT NULL DEFAULT 'dots',
  color       CHAR(7)     NOT NULL DEFAULT '#8B9590',
  is_default  BOOLEAN     NOT NULL DEFAULT FALSE,      -- mặc định: chỉ ẩn, không xóa
  is_hidden   BOOLEAN     NOT NULL DEFAULT FALSE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_category_type  CHECK (type IN ('income', 'expense')),
  CONSTRAINT chk_category_color CHECK (color ~ '^#[0-9A-Fa-f]{6}$'),
  CONSTRAINT chk_category_name  CHECK (name !~ '[[:cntrl:]<>]'),
  CONSTRAINT uq_categories_id_user UNIQUE (id, user_id)
);
CREATE UNIQUE INDEX uq_categories_user_type_name ON categories (user_id, type, lower(name));
CREATE TRIGGER trg_categories_updated BEFORE UPDATE ON categories
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------
-- 7. transactions: giao dịch thu/chi (UC06, UC07, UC08, UC11)
-- ---------------------------------------------------------------------
CREATE TABLE transactions (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          UUID         NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  wallet_id        UUID         NOT NULL,
  category_id      UUID         NOT NULL,
  type             VARCHAR(10)  NOT NULL,
  amount           BIGINT       NOT NULL,
  occurred_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  note             VARCHAR(200),
  source           VARCHAR(10)  NOT NULL DEFAULT 'manual',
  idempotency_key  UUID         NOT NULL,              -- chống gửi trùng
  deleted_at       TIMESTAMPTZ,                         -- xóa mềm, hỗ trợ hoàn tác
  created_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
  CONSTRAINT chk_tx_type   CHECK (type IN ('income', 'expense')),
  CONSTRAINT chk_tx_amount CHECK (amount > 0 AND amount <= 10000000000),
  CONSTRAINT chk_tx_source CHECK (source IN ('manual', 'ai', 'system')),
  CONSTRAINT uq_tx_idempotency UNIQUE (user_id, idempotency_key),
  CONSTRAINT uq_tx_id_user UNIQUE (id, user_id),
  CONSTRAINT fk_tx_wallet   FOREIGN KEY (wallet_id, user_id)   REFERENCES wallets (id, user_id),
  CONSTRAINT fk_tx_category FOREIGN KEY (category_id, user_id) REFERENCES categories (id, user_id)
);
CREATE INDEX ix_tx_user_time     ON transactions (user_id, occurred_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX ix_tx_user_category ON transactions (user_id, category_id, occurred_at) WHERE deleted_at IS NULL;
CREATE INDEX ix_tx_wallet        ON transactions (wallet_id) WHERE deleted_at IS NULL;
CREATE INDEX ix_tx_note_search   ON transactions USING gin (f_unaccent(coalesce(note, '')) gin_trgm_ops);
CREATE TRIGGER trg_transactions_updated BEFORE UPDATE ON transactions
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Loại giao dịch phải trùng loại danh mục (khoản chi chỉ gắn danh mục chi)
CREATE OR REPLACE FUNCTION check_tx_category_type() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM categories c WHERE c.id = NEW.category_id AND c.type = NEW.type) THEN
    RAISE EXCEPTION 'Loại giao dịch (%) không khớp loại danh mục', NEW.type;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_tx_category_type BEFORE INSERT OR UPDATE OF category_id, type ON transactions
  FOR EACH ROW EXECUTE FUNCTION check_tx_category_type();

-- ---------------------------------------------------------------------
-- 8. transaction_attachments: ảnh giao dịch (món đồ đã mua hoặc hóa đơn) đính kèm giao dịch (UC06.1)
--    Tệp ảnh nằm trong kho lưu trữ riêng tư (Supabase Storage khi chạy cloud, thư mục server/storage khi chạy trên máy),
--    bảng này chỉ lưu khóa tệp và thông tin kiểm tra.
-- ---------------------------------------------------------------------
CREATE TABLE transaction_attachments (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID         NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  transaction_id  UUID         NOT NULL,
  storage_key     VARCHAR(255) NOT NULL UNIQUE,         -- tên tệp ngẫu nhiên trong kho, không phải đường dẫn công khai
  mime_type       VARCHAR(20)  NOT NULL,
  size_bytes      INTEGER      NOT NULL,
  width           SMALLINT,
  height          SMALLINT,
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  CONSTRAINT chk_att_mime CHECK (mime_type IN ('image/jpeg', 'image/png', 'image/webp')),
  CONSTRAINT chk_att_size CHECK (size_bytes > 0 AND size_bytes <= 5242880),   -- tối đa 5 MB
  CONSTRAINT chk_att_dim  CHECK ((width IS NULL OR width > 0) AND (height IS NULL OR height > 0)),
  CONSTRAINT fk_att_tx FOREIGN KEY (transaction_id, user_id)
    REFERENCES transactions (id, user_id) ON DELETE CASCADE
);
CREATE INDEX ix_att_transaction ON transaction_attachments (transaction_id);

-- Tối đa 3 ảnh cho mỗi giao dịch
CREATE OR REPLACE FUNCTION check_attachment_limit() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM transactions WHERE id = NEW.transaction_id FOR UPDATE;   -- tránh hai lượt tải đồng thời vượt giới hạn
  IF (SELECT count(*) FROM transaction_attachments WHERE transaction_id = NEW.transaction_id) >= 3 THEN
    RAISE EXCEPTION 'Mỗi giao dịch chỉ được đính kèm tối đa 3 ảnh';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_att_limit BEFORE INSERT ON transaction_attachments
  FOR EACH ROW EXECUTE FUNCTION check_attachment_limit();

-- ---------------------------------------------------------------------
-- 9. budgets: ngân sách (UC09)
-- ---------------------------------------------------------------------
CREATE TABLE budgets (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name          VARCHAR(40) NOT NULL,
  amount_limit  BIGINT      NOT NULL,
  period        VARCHAR(10) NOT NULL,
  scope         VARCHAR(10) NOT NULL DEFAULT 'all',     -- all: toàn bộ khoản chi
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_budget_limit  CHECK (amount_limit > 0),
  CONSTRAINT chk_budget_period CHECK (period IN ('week', 'month')),
  CONSTRAINT chk_budget_scope  CHECK (scope IN ('all', 'categories')),
  CONSTRAINT uq_budgets_id_user UNIQUE (id, user_id)
);
CREATE INDEX ix_budgets_user ON budgets (user_id);
-- Chỉ một ngân sách "toàn bộ" cho mỗi chu kỳ
CREATE UNIQUE INDEX uq_budgets_all_period ON budgets (user_id, period) WHERE scope = 'all';
CREATE TRIGGER trg_budgets_updated BEFORE UPDATE ON budgets
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------
-- 10. budget_categories: danh mục thuộc phạm vi ngân sách (UC09)
-- ---------------------------------------------------------------------
CREATE TABLE budget_categories (
  budget_id    UUID NOT NULL,
  category_id  UUID NOT NULL,
  user_id      UUID NOT NULL,
  PRIMARY KEY (budget_id, category_id),
  CONSTRAINT fk_bc_budget   FOREIGN KEY (budget_id, user_id)   REFERENCES budgets (id, user_id) ON DELETE CASCADE,
  CONSTRAINT fk_bc_category FOREIGN KEY (category_id, user_id) REFERENCES categories (id, user_id) ON DELETE CASCADE
);
CREATE INDEX ix_bc_category ON budget_categories (category_id);

-- ---------------------------------------------------------------------
-- 11. alerts: cảnh báo đã gửi (UC10, UC13)
--     dedupe_key bảo đảm mỗi sự kiện chỉ cảnh báo một lần,
--     vd 'budget:<id>:2026-10-01:80' hoặc 'anomaly:<transaction_id>'.
-- ---------------------------------------------------------------------
CREATE TABLE alerts (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID         NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  type            VARCHAR(20)  NOT NULL,
  budget_id       UUID         REFERENCES budgets(id) ON DELETE SET NULL,
  transaction_id  UUID         REFERENCES transactions(id) ON DELETE SET NULL,
  category_id     UUID         REFERENCES categories(id) ON DELETE SET NULL,
  dedupe_key      VARCHAR(120) NOT NULL,
  title           VARCHAR(100) NOT NULL,
  body            VARCHAR(255) NOT NULL,                -- không chứa số tiền cụ thể
  feedback        VARCHAR(10),                          -- 'normal' khi người dùng bấm "Bình thường"
  sent_at         TIMESTAMPTZ  NOT NULL DEFAULT now(),
  read_at         TIMESTAMPTZ,
  CONSTRAINT chk_alert_type     CHECK (type IN ('budget_80', 'budget_100', 'forecast', 'anomaly')),
  CONSTRAINT chk_alert_feedback CHECK (feedback IS NULL OR feedback = 'normal'),
  CONSTRAINT uq_alert_dedupe UNIQUE (user_id, dedupe_key)
);
CREATE INDEX ix_alerts_user_time ON alerts (user_id, sent_at DESC);

-- ---------------------------------------------------------------------
-- 12. ai_insights: kết quả phân tích và gợi ý của AI, dùng làm cache (UC12)
-- ---------------------------------------------------------------------
CREATE TABLE ai_insights (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID         NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  period_start  DATE         NOT NULL,
  period_end    DATE         NOT NULL,
  kind          VARCHAR(20)  NOT NULL,
  title         VARCHAR(200) NOT NULL,
  content       TEXT         NOT NULL,                  -- văn bản thuần, không render HTML
  action        JSONB,                                  -- hành động đi kèm, vd đặt ngân sách
  status        VARCHAR(10)  NOT NULL DEFAULT 'new',
  trigger_type  VARCHAR(10)  NOT NULL DEFAULT 'scheduled',
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
  CONSTRAINT chk_insight_kind    CHECK (kind IN ('trend', 'habit', 'saving', 'forecast', 'anomaly')),
  CONSTRAINT chk_insight_status  CHECK (status IN ('new', 'acted', 'dismissed')),
  CONSTRAINT chk_insight_trigger CHECK (trigger_type IN ('scheduled', 'manual')),
  CONSTRAINT chk_insight_period  CHECK (period_end >= period_start)
);
CREATE INDEX ix_insights_user_period ON ai_insights (user_id, period_start DESC);

-- ---------------------------------------------------------------------
-- 13. ai_usage: đếm lượt gọi AI mỗi ngày để giới hạn (UC11, UC12)
-- ---------------------------------------------------------------------
CREATE TABLE ai_usage (
  user_id     UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  usage_date  DATE        NOT NULL,
  feature     VARCHAR(20) NOT NULL,
  call_count  INTEGER     NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, usage_date, feature),
  CONSTRAINT chk_ai_feature CHECK (feature IN ('parse', 'analyze', 'phrase')),
  CONSTRAINT chk_ai_count   CHECK (call_count >= 0)
);

-- ---------------------------------------------------------------------
-- 14. audit_logs: nhật ký thay đổi dữ liệu (UC07)
-- ---------------------------------------------------------------------
CREATE TABLE audit_logs (
  id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id         UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  entity          VARCHAR(20) NOT NULL,
  entity_id       UUID        NOT NULL,
  action          VARCHAR(10) NOT NULL,
  changed_fields  TEXT[],                               -- chỉ tên trường, không lưu giá trị
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_audit_entity CHECK (entity IN ('transaction', 'attachment', 'wallet', 'category', 'budget')),
  CONSTRAINT chk_audit_action CHECK (action IN ('create', 'update', 'delete', 'restore'))
);
CREATE INDEX ix_audit_entity ON audit_logs (entity, entity_id);

-- ---------------------------------------------------------------------
-- Dữ liệu khởi tạo khi đăng ký (UC01): bộ danh mục mặc định + ví "Tiền mặt"
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION init_user_data(p_user UUID) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO user_settings (user_id) VALUES (p_user);
  INSERT INTO wallets (user_id, name, type) VALUES (p_user, 'Tiền mặt', 'cash');
  INSERT INTO categories (user_id, name, type, icon, color, is_default) VALUES
    (p_user, 'Ăn uống',  'expense', 'food',   '#D9822B', TRUE),
    (p_user, 'Đi lại',   'expense', 'car',    '#3B7DD8', TRUE),
    (p_user, 'Mua sắm',  'expense', 'bag',    '#B4508F', TRUE),
    (p_user, 'Hóa đơn',  'expense', 'bolt',   '#7A62C9', TRUE),
    (p_user, 'Nhà ở',    'expense', 'home',   '#5D7A6E', TRUE),
    (p_user, 'Giải trí', 'expense', 'play',   '#D1495B', TRUE),
    (p_user, 'Sức khỏe', 'expense', 'health', '#2A9D8F', TRUE),
    (p_user, 'Học tập',  'expense', 'book',   '#8A6D3B', TRUE),
    (p_user, 'Chi khác', 'expense', 'dots',   '#8B9590', TRUE),
    (p_user, 'Lương',    'income',  'wallet', '#1E8A5A', TRUE),
    (p_user, 'Thưởng',   'income',  'star',   '#C9A227', TRUE),
    (p_user, 'Thu khác', 'income',  'gift',   '#4C9F70', TRUE);
END $$;
