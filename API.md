# SmartSpend API (v1)

Địa chỉ gốc của mọi API: `/api/v1`. Dữ liệu gửi và nhận dạng JSON (UTF-8). Thời gian theo chuẩn ISO 8601 (UTC). Số tiền là số nguyên, đơn vị đồng.

Trừ các API `auth/*` và `health`, mọi API đều cần header `Authorization: Bearer <access_token>`. Server lấy mã người dùng từ token, không bao giờ lấy từ dữ liệu gửi lên.

Khi có lỗi, server trả về dạng: `{"error": {"code": "...", "message": "thông báo tiếng Việt"}}`. Các mã HTTP:

| Mã | Ý nghĩa |
|---|---|
| 400 | Dữ liệu không hợp lệ |
| 401 | Chưa đăng nhập hoặc token hết hạn |
| 404 | Không tìm thấy, hoặc dữ liệu thuộc người khác |
| 409 | Trùng lặp hoặc xung đột |
| 413 | Dữ liệu quá lớn |
| 415 | Sai loại tệp |
| 429 | Gọi quá nhiều lần |

## Tài khoản và phiên (UC01, UC02)
| Phương thức | Đường dẫn | Mô tả |
|---|---|---|
| GET | /health | Không cần token. Truy vấn thử CSDL rồi trả `{"status":"ok"}`. Dùng cho dịch vụ ping định kỳ (cron-job.org) và để kiểm tra server còn chạy. |
| POST | /auth/register | `{full_name, email, password}` trả về `{user, access_token, refresh_token, expires_in}`. Tự tạo 12 danh mục mặc định và ví "Tiền mặt". Mỗi IP chỉ được đăng ký một số lần nhất định. |
| POST | /auth/login | `{email, password}`. Sai 5 lần thì khóa 15 phút (mã 429 `login_locked`). Lỗi luôn trả thông báo chung, không cho biết email có tồn tại hay không. |
| POST | /auth/refresh | `{refresh_token}` trả về cặp token mới, token cũ bị vô hiệu. Nếu token cũ bị dùng lại thì hủy mọi phiên của tài khoản (`session_revoked`). |
| POST | /auth/logout | `{refresh_token, push_token?}` hủy phiên hiện tại và mã thiết bị. |
| GET | /me | Thông tin người dùng và các tính năng server đang bật (`features.ai`, `features.push`). |
| GET, PATCH | /settings | `{budget_alerts_enabled, smart_alerts_enabled, timezone}` |
| POST, DELETE | /devices | `{push_token, platform}` đăng ký hoặc hủy mã nhận thông báo đẩy. |

## Ví (UC04)
| Phương thức | Đường dẫn | Mô tả |
|---|---|---|
| GET | /wallets | `{items, total_balance}` |
| POST | /wallets | `{name, type: cash/bank/ewallet, initial_balance?}`. Số dư ban đầu được ghi thành một giao dịch "Số dư ban đầu". |
| PATCH | /wallets/:id | `{name?, type?}`. Không sửa trực tiếp số dư. |
| POST | /wallets/:id/adjust | `{balance}` tạo giao dịch điều chỉnh để số dư khớp với số dư thực tế. |
| POST | /wallets/:id/archive, /unarchive | Lưu trữ hoặc dùng lại ví. Luôn giữ ít nhất 1 ví đang dùng. |
| DELETE | /wallets/:id | Chỉ xóa được khi ví chưa có giao dịch nào và không phải ví cuối cùng. |

## Danh mục (UC05)
| Phương thức | Đường dẫn | Mô tả |
|---|---|---|
| GET | /categories?include_hidden=true | Danh sách danh mục. |
| POST | /categories | `{name, type, icon?, color?}`. Tên không trùng trong cùng loại. |
| PATCH | /categories/:id | `{name?, icon?, color?, is_hidden?}`. Danh mục mặc định chỉ được đổi `is_hidden`. |
| DELETE | /categories/:id?move_to=:id2 | Nếu danh mục đang có giao dịch thì bắt buộc gửi `move_to` (danh mục cùng loại) để chuyển giao dịch sang. Giao dịch đã xóa (không còn hiển thị) được chuyển theo; nếu chỉ còn loại này thì chuyển sang "Chi khác"/"Thu khác" mà không cần `move_to`. |

## Giao dịch (UC06, UC07, UC08)
| Phương thức | Đường dẫn | Mô tả |
|---|---|---|
| GET | /transactions | Tham số: `q` (tìm không dấu), `from`, `to`, `type`, `category_id`, `wallet_id`, `limit` (tối đa 50), `cursor`. Trả về `{items, next_cursor, totals}`. |
| POST | /transactions | `{idempotency_key, type, amount, category_id, wallet_id, occurred_at?, note?, source?}`. Gửi trùng `idempotency_key` thì trả lại giao dịch cũ. Có thể trả kèm `warnings: ["over_balance"]`. |
| GET | /transactions/:id | Chi tiết giao dịch, gồm danh sách ảnh. |
| PATCH | /transactions/:id | Sửa giao dịch. Server hoàn tác ảnh hưởng cũ rồi áp dụng giá trị mới lên số dư ví. |
| DELETE | /transactions/:id | Xóa mềm và hoàn lại số dư. |
| POST | /transactions/:id/restore | Hoàn tác thao tác xóa. |
| POST | /transactions/bulk-delete | `{ids: [...]}` xóa nhiều giao dịch (tối đa 100). |

## Ảnh giao dịch (UC06.1)
| Phương thức | Đường dẫn | Mô tả |
|---|---|---|
| POST | /transactions/:id/attachments | Body là bytes của ảnh (`application/octet-stream`), tối đa 5 MB, nhận JPEG/PNG/WebP. Server xác định loại tệp bằng nội dung, mã hóa lại thành JPEG (xóa EXIF, cạnh dài tối đa 1600 px). Mỗi giao dịch tối đa 3 ảnh. |
| GET | /transactions/:id/attachments | Danh sách ảnh của giao dịch. |
| GET | /attachments/:id | Tải ảnh. Chỉ chủ giao dịch mới tải được. |
| DELETE | /attachments/:id | Xóa ảnh. |

## Ngân sách và cảnh báo (UC09, UC10, UC13)
| Phương thức | Đường dẫn | Mô tả |
|---|---|---|
| GET | /budgets, /budgets/:id | Mỗi ngân sách gồm: `spent`, `remaining`, `percent`, `days_left`, `daily_allowance`, `status` (green/yellow/red). |
| POST | /budgets | `{name, amount_limit, period: week/month, scope: all/categories, category_ids?}`. Không tạo được hai ngân sách trùng phạm vi và chu kỳ. |
| PATCH, DELETE | /budgets/:id | Sửa hoặc xóa ngân sách. Xóa ngân sách không xóa giao dịch. |
| GET | /alerts | `{items, unread_count}` |
| POST | /alerts/:id/read, /alerts/read-all | Đánh dấu đã đọc. |
| POST | /alerts/:id/feedback | `{feedback: "normal"}`: lần sau không cảnh báo bất thường cho danh mục này nữa. |

## AI (UC11, UC12, UC13)
| Phương thức | Đường dẫn | Mô tả |
|---|---|---|
| POST | /ai/parse | `{text}` (tối đa 300 ký tự) trả về `{engine, items: [bản xem trước], remaining_today}`. API không tự lưu giao dịch. |
| GET | /ai/insights | Các thẻ gợi ý gần nhất (lấy từ cache). |
| POST | /ai/insights/analyze | Phân tích ngay. Mỗi ngày được gọi giới hạn số lần (`AI_ANALYZE_PER_DAY`). Tháng hiện tại chưa có khoản chi nào thì trả 400 `not_enough_data`, không trừ lượt và giữ nguyên thẻ cũ. |
| PATCH | /ai/insights/:id | `{status: acted/dismissed}` |
| GET | /ai/forecast | Dự báo cuối kỳ cho từng ngân sách. Cần ít nhất 2 tuần dữ liệu. |

## Báo cáo (UC14)
| Phương thức | Đường dẫn | Mô tả |
|---|---|---|
| GET | /reports/overview | Dữ liệu màn hình chính. |
| GET | /reports/summary | Tham số: `period` (week/month/year/custom), `offset`, `from`, `to`, `wallet_id`. Trả về thu, chi, chênh lệch và so sánh với kỳ trước. Nếu kỳ chưa kết thúc thì so với cùng số ngày của kỳ trước. |
| GET | /reports/categories | Thêm tham số `type`. Danh mục chiếm dưới 3% được gộp vào "Khác". |
| GET | /reports/trend | Thêm tham số `group` (day/week/month). |
