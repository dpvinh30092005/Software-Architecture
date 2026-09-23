<p align="center">
  <img src="assets/architecture.svg" alt="a nervous monolith next to a bunch of happy microservices" width="100%">
</p>

# Software Architecture

I'm learning software architecture the hard way: by building the same quiz app over and over until it stops being one big blob.

Step one is a **monolith**. One app, one database, one guy doing everything and sweating about it.
Step two is chopping it into **microservices**, which fixes some problems and invents a bunch of new ones. We'll get there.

## What's in here

| Folder | What it is |
|---|---|
| [`Monolithic/quiz-app`](Monolithic/quiz-app) | The big guy. Controller → Service → DAO → Postgres, all in one box. |
| [`demo-app/quiz-app`](demo-app/quiz-app) | My scratch copy where I break things before breaking the real one. |

## The monolith

Three tables, one database (`questiondb`):

- `question`: the question bank. Title, four options, the right answer, a category.
- `quiz`: a title and a bunch of questions.
- `quiz_questions`: the join table Hibernate made for me because of `@ManyToMany`. Thanks, Hibernate.

### Endpoints

| Method | Endpoint | Does |
|---|---|---|
| GET | `/question/allQuestions` | dumps every question |
| GET | `/question/category/{category}` | questions for one category (`java`, `python`, ...) |
| POST | `/question/add` | adds a question |
| POST | `/quiz/create?category=java&numQ=5&title=JQuiz` | grabs 5 random java questions and calls it a quiz |
| GET | `/quiz/get/{id}` | the quiz questions, without the answers (no cheating) |
| GET | `/quiz/submit/{id}` | send your answers, get your score |

The random part is literally `ORDER BY RANDOM() LIMIT :numQ` in a native query. Nothing fancy.

## Running it

You need Java 21 and PostgreSQL.

1. Create a database called `questiondb`.
2. Give the app your Postgres password through the `DB_PASSWORD` env variable. In IntelliJ that's *Run → Edit Configurations → Environment variables*.
3. Go:
   ```bash
   cd Monolithic/quiz-app
   DB_PASSWORD=your_password ./mvnw spring-boot:run
   ```

Hibernate creates the tables on startup (`ddl-auto: update`), so you don't have to write any `CREATE TABLE`.

## Where this is going

- [x] Monolith that works (mostly)
- [ ] Split into `question-service` and `quiz-service`, each with its own DB
- [ ] Make them talk to each other with OpenFeign
- [ ] Eureka, so they can find each other
- [ ] An API gateway in front so nobody has to remember port numbers

## Built with

Java 21, Spring Boot 4, Spring Data JPA, PostgreSQL, Lombok, Maven, and a lot of pausing a YouTube video to read code that ran off the edge of the screen.
