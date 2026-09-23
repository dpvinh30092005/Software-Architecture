<p align="center">
  <img src="assets/architecture.svg" alt="Monolith vs Microservices — Quiz App" width="100%">
</p>

# Software Architecture

Học kiến trúc phần mềm qua một ví dụ duy nhất: **Quiz App** viết bằng Spring Boot — bắt đầu từ một khối **Monolith**, rồi tách dần thành **Microservices**.

## Cấu trúc repo

| Thư mục | Nội dung |
|---|---|
| [`Monolithic/quiz-app`](Monolithic/quiz-app) | Quiz App dạng monolith: 1 app, 1 database |
| [`demo-app/quiz-app`](demo-app/quiz-app) | Bản nháp để thử nghiệm |

## Monolith

```
controller  →  service  →  dao  →  PostgreSQL (questiondb)
```

- `question` — ngân hàng câu hỏi
- `quiz` — bài quiz
- `quiz_questions` — bảng nối quiz ↔ question (`@ManyToMany`)

### API

| Method | Endpoint | Mô tả |
|---|---|---|
| GET | `/question/allQuestions` | Lấy tất cả câu hỏi |
| GET | `/question/category/{category}` | Lấy câu hỏi theo category |
| POST | `/question/add` | Thêm câu hỏi |
| POST | `/quiz/create?category=java&numQ=5&title=JQuiz` | Tạo quiz với `numQ` câu ngẫu nhiên |
| GET | `/quiz/get/{id}` | Lấy câu hỏi của quiz (ẩn đáp án) |
| GET | `/quiz/submit/{id}` | Nộp bài, trả về số câu đúng |

## Chạy thử

Yêu cầu: Java 21, PostgreSQL.

1. Tạo database `questiondb` trong PostgreSQL.
2. Đặt biến môi trường `DB_PASSWORD` là mật khẩu PostgreSQL (IntelliJ: *Run → Edit Configurations → Environment variables*).
3. Chạy:
   ```bash
   cd Monolithic/quiz-app
   DB_PASSWORD=mat_khau_cua_ban ./mvnw spring-boot:run
   ```

Hibernate (`ddl-auto: update`) sẽ tự tạo bảng khi app khởi động.

## Lộ trình

- [x] Monolith
- [ ] Tách `question-service` và `quiz-service`, mỗi service một DB
- [ ] Gọi nhau bằng OpenFeign
- [ ] Service registry (Eureka)
- [ ] API Gateway

## Tech stack

Java 21 · Spring Boot 4 · Spring Data JPA · PostgreSQL · Lombok · Maven
