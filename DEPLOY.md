# Đưa server SmartSpend lên cloud (chạy 24/7, miễn phí)

Sau khi làm xong, server có một địa chỉ cố định dạng `https://smartspend-api-xxxx.onrender.com`. App chỉ cần build một lần với địa chỉ này. Mang điện thoại đi đâu, dùng mạng nào, app cũng chạy được, không cần bật máy tính.

| Phần | Dịch vụ | Gói miễn phí |
|---|---|---|
| CSDL PostgreSQL | **Supabase** | 500 MB. Project bị tạm dừng nếu 1 tuần không có truy cập. |
| Ảnh giao dịch | **Supabase Storage** | 1 GB, dùng bucket riêng tư. |
| Server Dart | **Render** | 750 giờ mỗi tháng. Server "ngủ" nếu 15 phút không có ai gọi. |
| Giữ server thức | **cron-job.org** | Gọi server mỗi 10 phút để server và CSDL luôn hoạt động. |

Tổng thời gian khoảng 30–45 phút. Không cần thẻ ngân hàng.

---

## Bước 1: Supabase (CSDL và kho ảnh)

### 1.1. Tạo project

1. Vào https://supabase.com, chọn **Start your project** và đăng nhập bằng GitHub.
2. Chọn **New project**, rồi điền:
   - **Name:** `smartspend`
   - **Database Password:** đặt mật khẩu **chỉ gồm chữ và số** (không dùng ký tự đặc biệt, để khỏi lỗi khi ghép vào chuỗi kết nối). **Ghi lại mật khẩu này.**
   - **Region:** **Southeast Asia (Singapore)**
3. Bấm **Create new project** và chờ khoảng 2 phút.

### 1.2. Nạp lược đồ CSDL

1. Mở **SQL Editor** ở menu bên trái, chọn **New query**.
2. Mở file `database/schema.sql`, copy **toàn bộ** nội dung, dán vào ô truy vấn rồi bấm **Run**. Kết quả phải là `Success. No rows returned`.
3. Tạo một **query mới**, dán đoạn dưới rồi bấm **Run**:
   ```sql
   -- Chặn REST API tự động của Supabase truy cập các bảng.
   -- App chỉ đi qua server SmartSpend; server kết nối bằng user postgres (chủ bảng) nên không bị chặn.
   DO $$ DECLARE t text; BEGIN
     FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' LOOP
       EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
     END LOOP;
   END $$;
   ```

Nếu ở mục 2 báo lỗi liên quan đến `unaccent`, chạy đoạn dưới rồi chạy lại `schema.sql`:
```sql
DROP EXTENSION IF EXISTS unaccent CASCADE;
CREATE EXTENSION unaccent SCHEMA public;
```

### 1.3. Tạo kho ảnh

1. Mở **Storage**, chọn **New bucket**.
2. **Name** điền `attachments`. Để **tắt** mục **Public bucket** (bucket riêng tư).
3. Bấm **Save**.

### 1.4. Lấy ba thông tin cho server

1. **DATABASE_URL:**
   - Bấm nút **Connect** ở thanh trên cùng, sang tab **Connection String**.
   - Chọn kiểu **Session pooler** (đây là kiểu chạy được qua IPv4, Render cần kiểu này). Copy chuỗi có dạng:
     ```
     postgresql://postgres.abcdxyz:[YOUR-PASSWORD]@aws-0-ap-southeast-1.pooler.supabase.com:5432/postgres
     ```
   - Thay `[YOUR-PASSWORD]` bằng mật khẩu ở bước 1.1. **Bỏ luôn cặp dấu `[ ]`.**
2. **SUPABASE_URL:** vào **Project Settings → Data API** (hoặc mở hộp **Connect**), copy **Project URL** dạng `https://abcdxyz.supabase.co`.
3. **SUPABASE_SERVICE_KEY:**
   - Vào **Project Settings → API Keys**, copy **Secret key** (bắt đầu bằng `sb_secret_`).
   - Nếu chưa có thì bấm tạo mới. Dùng khóa cũ `service_role` cũng được.
   - **Khóa này là bí mật, chỉ dán vào Render, không gửi cho ai và không đưa vào app.**

---

## Bước 2: Render (chạy server)

1. Đẩy code mới nhất lên GitHub. Trong thư mục `SmartSpend` chạy:
   ```
   git add .
   git commit -m "Cau hinh trien khai cloud"
   git push
   ```
2. Vào https://render.com, chọn **Get Started** và đăng nhập bằng **GitHub**.
3. Chọn **New +**, rồi **Blueprint**, rồi chọn repo `smartspend`. Nếu không thấy repo, bấm **Configure account** để cấp quyền cho Render đọc repo.
4. Render đọc file `render.yaml` và hiện dịch vụ `smartspend-api`, kèm các ô cần điền:
   - `DATABASE_URL`: chuỗi ở bước 1.4.1.
   - `SUPABASE_URL`: địa chỉ ở bước 1.4.2.
   - `SUPABASE_SERVICE_KEY`: khóa ở bước 1.4.3.
   - `GEMINI_API_KEY`: để trống nếu chưa có key.
5. Bấm **Apply**. Lần build đầu mất khoảng 5–10 phút.
6. Khi trạng thái chuyển sang **Live**:
   - Copy địa chỉ dịch vụ ở góc trên, dạng `https://smartspend-api-xxxx.onrender.com`.
   - Mở thử `https://smartspend-api-xxxx.onrender.com/api/v1/health`. Thấy `{"status":"ok"}` là server đã chạy và kết nối được CSDL.

Nếu bị lỗi, mở tab **Logs** trên Render:
- `password authentication failed`: chuỗi `DATABASE_URL` sai mật khẩu, hoặc còn sót dấu `[ ]`.
- `Network is unreachable`: bạn đang dùng chuỗi "Direct connection". Hãy đổi sang chuỗi **Session pooler**.

---

## Bước 3: Giữ server luôn thức (cron-job.org)

1. Vào https://cron-job.org và tạo tài khoản miễn phí.
2. Chọn **Create cronjob**, rồi điền:
   - **URL:** `https://smartspend-api-xxxx.onrender.com/api/v1/health`
   - **Execution schedule:** mỗi **10 phút** (Every 10 minutes).
3. Bấm **Create**.

Mỗi lần gọi, server truy vấn CSDL một lần. Nhờ vậy Render không cho server ngủ và Supabase không tạm dừng project.

---

## Bước 4: Tạo dữ liệu demo trên server cloud (không bắt buộc)

Trong VS Code, PowerShell, chạy:
```
cd server
$env:API_URL="https://smartspend-api-xxxx.onrender.com/api/v1"
dart run tool/seed_demo.dart
```
Lệnh tạo tài khoản `demo@smartspend.vn` / `demo1234`. Mất khoảng 2–3 phút, vì server giới hạn số yêu cầu mỗi phút và script tự chờ khi bị giới hạn.

---

## Bước 5: Build app lần cuối với địa chỉ cloud

Server đã có HTTPS nên giờ build được **bản release**: nhẹ hơn, chạy mượt hơn, cài cho ai cũng được.

Địa chỉ server cloud đã ghi sẵn trong `app/lib/core/config.dart` (`cloudApiUrl`), nên không cần truyền thêm tham số. Nếu đổi sang server khác thì sửa dòng đó trước khi build.

**Android**, trong thư mục `app`:
```
flutter build apk --release --split-per-abi
```
File để gửi cho mọi người: `app\build\app\outputs\flutter-apk\app-arm64-v8a-release.apk`.

**iPhone:**
1. Vào GitHub, mở tab **Actions**, chọn **Build iOS (IPA chưa ký)**, bấm **Run workflow**. Ô địa chỉ API để trống để dùng địa chỉ server cloud mặc định.
2. Cài file IPA bằng Sideloadly như trước.

Từ giờ không phải bật server trên máy tính nữa.

---

## Ghi chú

- Mỗi lần `git push` lên nhánh `main`, Render tự build và cập nhật server (khoảng 5 phút).
- **Server cloud có CSDL riêng**, khác CSDL trên máy tính, nên tài khoản tạo ở một bên không có ở bên kia.
- **Ảnh** lưu trong Supabase Storage, bucket riêng tư. App vẫn chỉ tải ảnh được qua server có kiểm tra token, đúng như đặc tả.
- **Thông báo đẩy (chỉ Android):** trên Render, vào **Environment → Add**, thêm biến `FCM_SERVICE_ACCOUNT_JSON` và dán toàn bộ nội dung file khóa service account của Firebase (xem README mục 3.2). Lưu lại, server tự khởi động lại; log có dòng `Thông báo đẩy: bật` là được.
- **Gemini:** thêm biến `GEMINI_API_KEY` trên Render ở **Environment → Add**, lưu lại là server tự khởi động lại. Nhớ lưu ý: gói miễn phí của Gemini có thể bị dùng để huấn luyện, nên chỉ demo với dữ liệu mẫu.
- Hai nơi giữ thông tin bí mật là **Render → Environment** (biến môi trường) và file `.env` trên máy. Không có thông tin bí mật nào nằm trong code hay trong app.
