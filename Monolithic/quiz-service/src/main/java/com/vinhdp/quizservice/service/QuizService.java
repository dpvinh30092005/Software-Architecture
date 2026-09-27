package com.vinhdp.quizservice.service;

import com.vinhdp.quizservice.dao.QuizDao;
import com.vinhdp.quizservice.feign.QuizInterface;
import com.vinhdp.quizservice.model.QuestionWrapper;
import com.vinhdp.quizservice.model.Quiz;
import com.vinhdp.quizservice.model.Response;
import io.github.resilience4j.bulkhead.BulkheadFullException;
import io.github.resilience4j.bulkhead.annotation.Bulkhead;
import io.github.resilience4j.circuitbreaker.CallNotPermittedException;
import io.github.resilience4j.ratelimiter.RequestNotPermitted;
import io.github.resilience4j.ratelimiter.annotation.RateLimiter;
import io.github.resilience4j.retry.annotation.Retry;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.cache.annotation.CacheEvict;
import org.springframework.cache.annotation.Cacheable;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.stereotype.Service;

import java.util.List;

@Service
public class QuizService {

    private static final String CLIENT = "QUESTION-SERVICE";

    @Autowired
    QuizDao quizDao;

    @Autowired
    QuizInterface quizInterface;

    @Retry(name = CLIENT, fallbackMethod = "createQuizFallback")
    @RateLimiter(name = CLIENT)
    @Bulkhead(name = CLIENT)
    public ResponseEntity<String> createQuiz(String category, int numQ, String title) {

        List<Integer> questionIds = quizInterface.getQuestionsForQuiz(category, numQ).getBody();

        Quiz quiz = new Quiz();
        quiz.setTitle(title);
        quiz.setQuestions(questionIds);
        quizDao.save(quiz);

        return new ResponseEntity<>("Success", HttpStatus.CREATED);
    }


    private ResponseEntity<String> createQuizFallback(String category, int numQ, String title, Throwable ex) {

        if (ex instanceof RequestNotPermitted) {
            return new ResponseEntity<>("Rate limit exceeded, try again shortly",
                    HttpStatus.TOO_MANY_REQUESTS);                       // 429 - our own limit
        }
        if (ex instanceof BulkheadFullException) {
            return new ResponseEntity<>("Too many concurrent requests, try again shortly",
                    HttpStatus.TOO_MANY_REQUESTS);                       // 429 - our own limit
        }
        if (ex instanceof CallNotPermittedException) {
            return new ResponseEntity<>("Question service is down, circuit is open",
                    HttpStatus.SERVICE_UNAVAILABLE);                     // 503 - their outage
        }
        return new ResponseEntity<>("Question service unavailable after retries, quiz not created",
                HttpStatus.SERVICE_UNAVAILABLE);                         // 503 - their outage
    }


    @Cacheable(cacheNames = "questions", key = "#id", unless = "#result == null")
    @Retry(name = CLIENT, fallbackMethod = "getQuizQuestionFallback")
    @RateLimiter(name = CLIENT)
    @Bulkhead(name = CLIENT)
    public ResponseEntity<List<QuestionWrapper>> getQuizQuestion(Integer id) {
        Quiz quiz = quizDao.findById(id).orElseThrow();
        return quizInterface.getQuestionsFromId(quiz.getQuestions());
    }

    private ResponseEntity<List<QuestionWrapper>> getQuizQuestionFallback(Integer id, Throwable ex) {
        // A read may degrade to an empty body - nothing is persisted, nothing is lost.
        return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).build();
    }

    @CacheEvict(cacheNames = "questions", key = "#id")
    public void evictQuizQuestions(Integer id) {
        // annotation does the work
    }

    @Retry(name = CLIENT, fallbackMethod = "calculateResultFallback")
    @RateLimiter(name = CLIENT)
    @Bulkhead(name = CLIENT)
    public ResponseEntity<Integer> calculateResult(Integer id, List<Response> responses) {
        return quizInterface.getScore(responses);
    }

    private ResponseEntity<Integer> calculateResultFallback(Integer id, List<Response> responses, Throwable ex) {
        return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).build();
    }
}
