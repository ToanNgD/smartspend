# SmartSpend – mã nguồn

Ứng dụng quản lý và tối ưu chi tiêu cá nhân thông minh tích hợp AI.

| Thư mục | Nội dung | Công nghệ |
|---|---|---|
| `app/` | Ứng dụng di động | Flutter 3 + Dart, Provider, Dio |
| `server/` | API (máy chủ) | Dart + Shelf, PostgreSQL (thư viện `postgres`), JWT, bcrypt |
| `database/schema.sql` | Lược đồ CSDL (giống file trong thư mục `csdl/`) | PostgreSQL 15+ |
| `API.md` | Danh sách API | |

Phần bảo mật, quy tắc nghiệp vụ và luồng xử lý được làm theo tài liệu đặc tả `CN.docx` và `Dac_ta_use_case.docx`.

---

## 1. Cài đặt lần đầu

Cần cài trước:

- Flutter SDK (đã có Dart đi kèm).
- PostgreSQL 15 trở lên.
- VS Code với extension Flutter.
- Android Studio, để có Android SDK và máy ảo. Có thể dùng điện thoại thật thay cho máy ảo.

### 1.1. Tạo cơ sở dữ liệu

```bash
# Tạo database rồi nạp lược đồ (dùng psql, hoặc mở file trong pgAdmin rồi bấm Execute)
createdb -U postgres smartspend
psql -U postgres -d smartspend -f database/schema.sql
```

### 1.2. Chạy server

```bash
cd server
copy .env.example .env        # macOS/Linux: cp .env.example .env
# Mở .env, sửa DB_PASSWORD cho đúng mật khẩu PostgreSQL trên máy
# và đặt JWT_SECRET là một chuỗi ngẫu nhiên dài tối thiểu 32 ký tự
dart pub get
dart run bin/server.dart
```

Khi chạy được, server in ra: `SmartSpend API chạy tại http://0.0.0.0:8080/api/v1`.

Tạo tài khoản demo có sẵn khoảng 6 tuần dữ liệu (mở một cửa sổ terminal khác, giữ server đang chạy):

```bash
cd server
dart run tool/seed_demo.dart          # tài khoản: demo@smartspend.vn / demo1234
```

### 1.3. Chạy app

```bash
cd app
flutter pub get
flutter run                                   # máy ảo Android tự trỏ tới 10.0.2.2:8080
flutter run --dart-define=API_URL=http://192.168.1.10:8080/api/v1   # điện thoại thật
```

Khi dùng điện thoại thật:

- `192.168.1.10` là IP máy tính trong mạng Wi-Fi. Xem bằng lệnh `ipconfig` trên Windows.
- Điện thoại và máy tính phải dùng cùng một mạng Wi-Fi.
- Windows Firewall phải cho phép cổng 8080.

Bản debug được gọi server bằng HTTP. Bản phát hành bắt buộc dùng HTTPS (xem mục 4).

---

## 2. Kiểm thử

```bash
# Server: chạy server trước, sau đó chạy lệnh dưới. Có 20 nhóm ca kiểm thử,
# gồm cả các ca bảo mật như IDOR, khóa đăng nhập, refresh token bị dùng lại, tệp giả dạng ảnh, EXIF.
cd server
dart test

# App: kiểm thử đơn vị và giao diện (định dạng tiền, khóa PIN và mã hóa, xử lý ảnh, bàn phím PIN)
cd app
flutter test
```

Lưu ý: khi chạy `dart test`, nên đặt `REGISTER_PER_IP_PER_HOUR=1000` trong `.env`, vì bộ test đăng ký rất nhiều tài khoản.

---

## 3. Các phần nhóm cần tự làm (không bắt buộc để demo)

App vẫn chạy đầy đủ khi chưa làm các bước dưới đây:

- **Chưa có Gemini key:** server dùng bộ phân tích dự phòng chạy ngay trên server. Bộ này hiểu được câu như "trưa nay ăn phở 50k, cà phê 25k" và vẫn tạo được thẻ gợi ý từ thống kê.
- **Chưa cấu hình Firebase:** cảnh báo vẫn xem được trong màn hình Cảnh báo, chỉ không có thông báo đẩy.

### 3.1. Bật AI thật (Gemini)

1. Vào https://aistudio.google.com và chọn **Get API key**.
2. Dán key vào file `server/.env`: `GEMINI_API_KEY=...`
3. Khởi động lại server. Màn hình Cài đặt của app sẽ hiện "Đã kết nối dịch vụ AI".

Lưu ý về gói miễn phí: Google có thể dùng dữ liệu của gói miễn phí để huấn luyện mô hình. Điều này trái với yêu cầu ở mục 6.1 của đặc tả ("chọn cấu hình không dùng dữ liệu để huấn luyện"). Vì vậy:

- Khi demo với gói miễn phí, chỉ dùng **dữ liệu mẫu**.
- Khi phát hành thật, phải dùng gói trả phí, vì gói này không dùng dữ liệu để huấn luyện.

Có thể đổi model bằng biến `GEMINI_MODEL`. Mặc định là `gemini-3.6-flash`; nếu Google đổi tên model, xem tên mới tại https://ai.google.dev/gemini-api/docs/models.

### 3.2. Bật thông báo đẩy (Firebase Cloud Messaging)

1. Tạo project tại https://console.firebase.google.com.
2. Thêm ứng dụng Android với package name `vn.smartspend.smartspend`.
3. Trong thư mục `app/`, chạy `dart pub global activate flutterfire_cli`, sau đó chạy `flutterfire configure`. Lệnh này sẽ tự ghi đè file `lib/firebase_options.dart` và thêm `google-services.json`.
4. Lấy khóa cho server:
   - Vào Firebase Console, chọn Project settings, rồi Service accounts, rồi **Generate new private key**.
   - Lưu file JSON vào thư mục `server/`. **Không commit file này lên git.**
   - Ghi đường dẫn file vào `.env`: `FCM_SERVICE_ACCOUNT=./service-account.json`.

### 3.3. Thử trên điện thoại thật

Có ba tính năng chỉ chạy trên máy thật:

- **Camera kiểu Locket.** Máy ảo có camera giả, chỉ thử được một phần.
- **Vân tay / Face ID.**
- **Thông báo đẩy.**

---

## 4. Ghi chú khi triển khai thật

- **Bắt buộc dùng HTTPS.** Đặt server sau một reverse proxy có TLS, ví dụ Caddy: `caddy reverse-proxy --from api.tenmien.vn --to localhost:8080`. Khi build app, truyền `--dart-define=API_URL=https://api.tenmien.vn/api/v1`.
- Thư mục ảnh (`UPLOAD_DIR`) phải nằm ngoài thư mục web công khai. Ảnh chỉ tải được qua API có kiểm tra token.
- Không đưa các file sau lên git: `server/.env`, file service account Firebase, thư mục `server/storage/`.
- Giới hạn tần suất hiện được đếm trong bộ nhớ, đủ cho một server. Nếu chạy nhiều server thì chuyển sang Redis.

---

## 5. Cấu trúc mã và đối chiếu với use case

### Server (`server/lib/src/`)

| Use case | File |
|---|---|
| UC01, UC02 Đăng ký, đăng nhập, phiên | `routes/auth_routes.dart`, `core/security.dart` |
| UC04 Ví | `routes/wallet_routes.dart` |
| UC05 Danh mục | `routes/category_routes.dart` |
| UC06, UC07, UC08 Giao dịch; UC06.1 Ảnh | `routes/transaction_routes.dart`, `services/storage_service.dart` |
| UC09 Ngân sách | `routes/budget_routes.dart`, `services/budget_service.dart` |
| UC10, UC13 Cảnh báo, dự báo, bất thường | `services/alert_service.dart`, `services/push_service.dart`, `routes/alert_routes.dart` |
| UC11, UC12 AI | `services/ai_service.dart`, `services/gemini_client.dart`, `services/vn_text.dart`, `routes/ai_routes.dart` |
| UC14 Báo cáo | `routes/report_routes.dart` |
| Bảo mật chung | `core/middleware.dart` (token, giới hạn tần suất, lỗi), `core/validate.dart` (kiểm tra, làm sạch dữ liệu) |

### App (`app/lib/`)

| Use case | File |
|---|---|
| UC01, UC02 | `screens/auth_screens.dart`, `state/session.dart`, `core/api_client.dart`, `core/token_store.dart` |
| UC03 Khóa app (PIN, sinh trắc học) | `screens/lock_screens.dart`, `core/vault.dart`, `core/secure_cache.dart` |
| UC04, UC05 | `screens/wallet_screens.dart`, `screens/category_screens.dart` |
| UC06, UC07, UC08 | `screens/tx_form_screen.dart`, `screens/transaction_screens.dart`, `widgets/tx_editor.dart` |
| UC06.1 Chụp ảnh kiểu Locket | `screens/camera_screen.dart`, `core/images.dart`, `widgets/secure_image.dart` |
| UC09, UC10 | `screens/budget_screens.dart`, `screens/alerts_screen.dart`, `core/push.dart` |
| UC11 Nhập bằng câu, "chụp trước, nhập sau" | `screens/ai_input_screen.dart`, `screens/camera_screen.dart` |
| UC12, UC13 | `screens/ai_screen.dart` |
| UC14 | `screens/overview_screen.dart`, `screens/report_screen.dart` |

### Quản lý trạng thái

App dùng **Provider** với ba lớp:

- `Session`: đăng nhập và khóa app.
- `AppData`: dữ liệu dùng chung.
- `ApiClient`: gọi API.

Nếu thầy yêu cầu Riverpod, chỉ cần đổi phần cung cấp trạng thái trong `main.dart` và các lệnh `context.watch`/`context.read`. Phần logic không phải sửa.
