package com.vinhdp.quizservice.service;

import com.vinhdp.quizservice.dao.QuizDao;
import com.vinhdp.quizservice.feign.QuizInterface;
import com.vinhdp.quizservice.model.QuestionWrapper;
import com.vinhdp.quizservice.model.Quiz;
import com.vinhdp.quizservice.model.Response;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.stereotype.Service;

import java.util.List;

@Service
public class QuizService {

    @Autowired
    QuizDao quizDao;

    @Autowired
    QuizInterface quizInterface;

//    @Autowired
//    QuestionDao questionDao;

    public ResponseEntity<String> createQuiz(String category, int numQ, String title) {

//        List<Integer> questionList = // call the generate url = REST Template http://localhost:8080/question/generate
//
//        Quiz quiz = new Quiz();
//        quiz.setTitle(title);
//        quiz.setQuestions(questionList);
//        quizDao.save(quiz);

        List<Integer> question = quizInterface.getQuestionsForQuiz(category, numQ).getBody();
        Quiz quiz = new Quiz();
        quiz.setTitle(title);
        quiz.setQuestions(question);
        quizDao.save(quiz);

        return new ResponseEntity<>("Success", HttpStatus.CREATED);
    }

    public ResponseEntity<List<QuestionWrapper>> getQuizQuestion(Integer id) {
//        List<Question> questionsFromDb = quiz.get().getQuestions();
//        List<QuestionWrapper> questionForUser = new ArrayList<>();
//
//        for (Question question : questionsFromDb) {
//            QuestionWrapper questionWrapper = new QuestionWrapper();
//
//            questionWrapper.setId(question.getId());
//            questionWrapper.setQuestionTitle(question.getQuestionTitle());
//            questionWrapper.setOption1(question.getOption1());
//            questionWrapper.setOption2(question.getOption2());
//            questionWrapper.setOption3(question.getOption3());
//            questionWrapper.setOption4(question.getOption4());
//
//            questionForUser.add(questionWrapper);
//        }
        Quiz quiz = quizDao.findById(id).get();
        List<Integer> questionIds = quiz.getQuestions();
        ResponseEntity<List<QuestionWrapper>> questions = quizInterface.getQuestionsFromId(questionIds);

        return questions;
    }

    public ResponseEntity<Integer> calculateResult(Integer id, List<Response> responses) {

        ResponseEntity<Integer> score = quizInterface.getScore(responses);
        return score;
    }
}
