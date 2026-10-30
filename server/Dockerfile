# Build server thành file chạy native rồi đóng gói vào image nhỏ gọn (dùng cho Render hoặc bất kỳ nơi nào chạy Docker).
FROM dart:stable AS build
WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get
COPY . .
RUN dart pub get --offline && dart compile exe bin/server.dart -o /app/server

FROM debian:bookworm-slim
# Chứng chỉ CA để gọi HTTPS tới Supabase, Gemini, Firebase; múi giờ cho PostgreSQL client.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home appuser
WORKDIR /home/appuser
COPY --from=build /app/server ./server
USER appuser
ENV PORT=8080
EXPOSE 8080
CMD ["./server"]
