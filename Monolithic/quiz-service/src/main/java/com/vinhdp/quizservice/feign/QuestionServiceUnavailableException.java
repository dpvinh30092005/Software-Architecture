package com.vinhdp.quizservice.feign;

public class QuestionServiceUnavailableException extends RuntimeException{

    public QuestionServiceUnavailableException (Throwable cause){
        super("question-service unavailable", cause);
    }

}
