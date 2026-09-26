package com.vinhdp.quizservice.feign;

import com.vinhdp.quizservice.model.QuestionWrapper;
import com.vinhdp.quizservice.model.Response;
import org.springframework.cloud.openfeign.FallbackFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.stereotype.Component;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;

import java.util.List;

@Component
public class QuizInterfaceFallback implements FallbackFactory<QuizInterface> {

    private static final org.slf4j.Logger log =
            org.slf4j.LoggerFactory.getLogger(QuizInterfaceFallback.class);

    @Override
    public QuizInterface create(Throwable cause) { //Fallback not know Throwable
        log.error(cause.getMessage(), cause);
        return new QuizInterface() {
            //WRITE: CANNOT RETURN EMPTY LIST
            //READ:  CAN RETURN EMPTY LIST
            @Override
            public ResponseEntity<List<Integer>> getQuestionsForQuiz
                    ( String categoryName, Integer numQuestions) {
                return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).build();
            }

            @Override
            public ResponseEntity<List<QuestionWrapper>> getQuestionsFromId
                    ( List<Integer> questionIds) {
                return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).build();
            }

            @Override
            public ResponseEntity<Integer> getScore(List<Response> responses) {
                return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).build();
            }
        };
    }

}
