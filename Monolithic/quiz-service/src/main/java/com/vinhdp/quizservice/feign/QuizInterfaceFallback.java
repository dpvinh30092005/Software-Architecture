package com.vinhdp.quizservice.feign;

import com.vinhdp.quizservice.model.QuestionWrapper;
import com.vinhdp.quizservice.model.Response;
import io.github.resilience4j.bulkhead.BulkheadFullException;
import io.github.resilience4j.circuitbreaker.CallNotPermittedException;
import io.github.resilience4j.ratelimiter.RequestNotPermitted;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.cloud.openfeign.FallbackFactory;
import org.springframework.http.ResponseEntity;
import org.springframework.stereotype.Component;

import java.util.List;

@Component
public class QuizInterfaceFallback implements FallbackFactory<QuizInterface> {

    private static final Logger log = LoggerFactory.getLogger(QuizInterfaceFallback.class);

    private RuntimeException translate(Throwable cause) {
        if (cause instanceof CallNotPermittedException e) return e;   // breaker is OPEN
        if (cause instanceof RequestNotPermitted e)       return e;   // rate limit hit
        if (cause instanceof BulkheadFullException e)     return e;   // too many in flight
        return new QuestionServiceUnavailableException(cause);
    }

    @Override
    public QuizInterface create(Throwable cause) {
        log.warn("question-service call failed: {}", cause.toString());

        return new QuizInterface() {

            @Override
            public ResponseEntity<List<Integer>> getQuestionsForQuiz(String categoryName, Integer numQuestions) {
                throw translate(cause);
            }

            @Override
            public ResponseEntity<List<QuestionWrapper>> getQuestionsFromId(List<Integer> questionIds) {
                throw translate(cause);
            }

            @Override
            public ResponseEntity<Integer> getScore(List<Response> responses) {
                throw translate(cause);
            }
        };
    }
}
