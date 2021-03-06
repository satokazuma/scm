
'()
;;; (define Id Exp) | (define (Id Id* [. Id]) Body)
(define (my-define x env)
  (assert `("error define syntax: " ,x)
	  (and (list? x) (eq? (car x) 'define) (>= (length x) 3)))
  (cond
   ;; (define Id Exp)
   ((symbol? (cadr x))
    (let ((bound (get-bound (cadr x) env)))
      (cond
       ;; in case Id is defined as macro var
       ((and bound (macro-var? (car bound)))
	  (delete-macrodef!   (car bound))
	  (set-cdr!           bound (eval-exp (caddr x) env))
 	  (car                bound))
       ;; in case Id is defined
       (bound
	  (set-cdr! bound (eval-exp (caddr x) env))
	  (car bound))
       ;; otherwise
       (else
	(set! *global-env*
	      (cons (cons (cadr x) (eval-exp (caddr x) env))
		    *global-env*))
	(cadr x)))))
   ;; (define (var formals) body)  -> (define var (lambda (formals) body))
   ;; (define (var . formal) body) -> (define var (lambda formal body))
   ((and (pair? (cadr x)) (symbol? (caadr x)))
    (my-define 
     `(define ,(caadr x) (lambda ,(cdadr x) ,@(cddr x)))
     env))
   (else
    (abort `("define misc error: " ,x)))))

;;; (define (Id Id* [. Id]) Body) -> (define Id Exp)
(define (desugar-def def)
  (if (symbol? (cadr def))
      def
      `(define ,(caadr def) (lambda ,(cdadr def) ,@(cddr def)))))

;;; (define Id Exp) | (define (Id Id* [. Id]) Body) ???
(define (define? def)
  (if (and (list? def) (>= (length def) 3) (eq? (car def) 'define)
	   (or (symbol? (cadr def)) (and (pair? (cadr def)) (symbol? (caadr def)))))
      #t
      #f))

;;; (set! Id Exp)
(define (my-set! x env)
  (assert `("error set! syntax: " ,x) 
	  (and (list? x) (= (length x) 3) (eq? (car x) 'set!) (symbol? (cadr x))))
  (let* ((id (cadr x)) (exp (caddr x)) (bound (get-bound id env)))
    (cond
     ;; in case Id is defined as macro
     ((and bound (macro-var? id))
      (delete-macrodef! id)
      (set-cdr! bound (eval-exp exp env)))
     ;; in case Id is defined.
     (bound
      (set-cdr! bound (eval-exp exp env)))
     ;; in case Id is not defined.
     (else
      (abort `(,id " is not defined."))))))

(define (bindings? x)
  (cond
   ((null? x)
    #t)
   ((and (list? x) (list? (car x)) (= (length (car x)) 2))
    (bindings? (cdr x)))
   (else
    #f)))

;;; (let [Id] Bindings Body)
(define (my-let exp env)
  (assert `("error let syntax: " ,exp)
	  (and (list? exp) (>= (length exp) 3) (eq? (car exp) 'let)))
  (cond
   ;; named let
   ((symbol? (cadr exp))
    (my-namedlet exp env))
   ;; (let () Body)            -> (lambda () Body)
   ((null? (cadr exp))
    (eval-exp `((lambda () ,@(cddr exp))) env))
   ;; (let ((x a) (y b)) Body) -> ((lambda (x y) Body) a b)
   (else
    (assert `("error let syntax: " ,exp) (bindings? (cadr exp)))
    (eval-exp `((lambda ,(map car (cadr exp)) ,@(cddr exp)) ,@(map cadr (cadr exp)))
	      env))))

;;; (let Id Bindigs Body) -> (letrec ((Id (lambda (args) Body))) (Id actuals))
(define (my-namedlet exp env)
  (assert `("error named let syntax: " ,exp) 
	  (and (list? exp) (>= (length exp) 4) (bindings? (caddr exp))))
  (let ((id (cadr exp)) (bindings (caddr exp)) (body (cdddr exp)))
    (if (null? bindings)
	;; (let Id () Body)
	(my-letrec 
	 `(letrec ((,id (lambda () ,@body))) (,id)) env)
	;; (let Id ((x a) (y b) ..) Body)
	(my-letrec 
	 `(letrec ((,id (lambda ,(map car bindings) ,@body))) 
	    (,id ,@(map cadr bindings))) env))))

;;; (let* Bindings Body)
(define (my-let* exp env)
  (assert `("error let* syntax: " ,exp) 
	  (and (list? exp) (>= (length exp) 3) 
	       (eq? (car exp) 'let*) (bindings? (cadr exp))))
	        
  (let ((bindings (cadr exp)) (body (cddr exp)))
    (if (null? bindings)
	;; (let* () Body)
	(eval-exp `((lambda () ,@body)) env)
	;; (let* ((x a) (y b)) Body)
	(eval-exp
	 `((lambda (,(caar bindings)) (let* ,(cdr bindings) ,@body)) 
	   ,(cadar bindings)) 
	 env))))

;;; (letrec Bindings Body)
(define (my-letrec exp env)
  (assert `("error letrec syntax: " ,exp)
	  (and (list? exp) (>= (length exp) 3) 
	       (eq? (car exp) 'letrec) (bindings? (cadr exp))))
	       
  (if (null? (cadr exp))
      ;; (letrec () Body)
      (eval-exp `((lambda () ,@(cddr exp))) env)
      ;; (letrec ((x a) (y b)) Body)
      (my-let
       `(let ,(map (lambda (lst) (list (car lst) "<#undef#>")) (cadr exp))
	  ,@(map (lambda (lst) (cons 'set! lst)) (cadr exp)) ,@(cddr exp))
       env)))

;;; (if Exp Exp [Exp])
(define (my-if exp env)
  (assert `("error if syntax: " ,exp) 
	  (and (list? exp) 
	       (or (= (length exp) 3) (= (length exp) 4)) (eq? (car exp) 'if)))
  (if (eval-exp (cadr exp) env)
      (eval-exp (caddr exp) env)
      (if (null? (cdddr exp))
	  "<#undef#>"
	  (eval-exp (cadddr exp) env))))

;;; (cond (Exp Exp+)* [(else Exp+)])
(define (my-cond exp env)
  (define (cond? expr) 
    (cond ((null? expr)
	   #t)
	  ;; (Exp Exp+)*
	  ((and (list? (car expr)) (>= (length (car expr)) 2) 
		(not (eq? (caar expr) 'else)))		
	   (cond? (cdr expr)))
	  ;; (else Exp+)*
	  ((and (list? (car expr)) (>= (length (car expr)) 2)
		(eq? (caar expr) 'else) (null? (cdr expr)))
	   #t)
	  (else
	   #f)))
  (define (cond-sub expr env)
    (cond
     ((null? expr)
      "<#undef#>")
     ;; (else Exp+)
     ((eq? (caar expr) 'else)
      (eval-exp `(begin ,@(cdar expr)) env))
     ;; (Exp Exp+) 
     ((eval-exp (caar expr) env)
      (eval-exp `(begin ,@(cdar expr)) env))
     (else
      (cond-sub (cdr expr) env))))

  (assert `("error cond syntax: " ,exp)
	  (and (list? exp) (eq? (car exp) 'cond) (>= (length exp) 2) 
	       (list? (cadr exp)) (not (null? (cadr exp))) (cond? (cdr exp))))

  (cond-sub (cdr exp) env))

;;; (and Exp*)
(define (my-and exp env)
  (assert `("error and syntax: " ,exp) (and (list? exp) (eq? (car exp) 'and)))
  (letrec ((and-sub (lambda (expr env) (cond
				       ((null? expr)
					#t)
				       ((null? (cdr expr))
					(eval-exp (car expr) env))
				       ((not (eq? (eval-exp (car expr) env) #f))
					(and-sub (cdr expr) env))
				       (else
					#f)))))
    (and-sub (cdr exp) env)))

;;; (or Exp*)
(define (my-or exp env)
  (assert `("error or syntax: " ,exp) (and (list? exp) (eq? (car exp) 'or)))
  (letrec ((or-sub (lambda (expr env)   (cond
					((null? expr)
					 #f)
					((null? (cdr expr))
					 (eval-exp (car expr) env))
					;; 
					(else
					 (let ((val (eval-exp (car expr) env)))
					   (if val
					       val
					       (or-sub (cdr expr) env))))))))
    (or-sub (cdr exp) env)))

;;; (begin Exp*)
(define (my-begin exp env)
  (define (begin-sub e env)
    (cond
     ((null? e)
      "<#undef#>")
     ((null? (cdr e))
      (eval-exp (car e) env))
     (else
      (eval-exp (car e) env) (begin-sub (cdr e) env))))
  
  (assert `("error begin syntax: " ,exp) (and (list? exp) (eq? (car exp) 'begin)))  
  (begin-sub (cdr exp) env))

;;; (do ((Id Exp Exp)*) (Exp Exp*) Body)
(define (my-do exp env)
  (define (iter-specs? iter-specs)
    (cond ((null? iter-specs)
	   #t)
	  ((and (list? (car iter-specs)) (= (length (car iter-specs)) 3) 
		(symbol? (caar iter-specs)))
	   (iter-specs? (cdr iter-specs)))
	  (else
	   #f)))

  (define (step iter-specs ex-env)
    (let ((step-vals (map (lambda (iter-spec) (eval-exp (caddr iter-spec) ex-env))  
			  iter-specs)))
      (map 
       (lambda (iter-spec step-val) 
	 (set-cdr! (get-bound (car iter-spec) ex-env) step-val))
       iter-specs step-vals)))
    
  (assert `("error do syntax: " ,exp)
	  (and (list? exp) (eq? (car exp) 'do) (>= (length exp) 4)
	       (iter-specs? (cadr exp)) (list? (caddr exp)) 
	       (not (null? (caddr exp)))))
  
  (let loop ((iter-specs  (cadr   exp))
	     (test        (caaddr exp))
	     (tail-seq    (cdaddr exp))
	     (body        (cdddr  exp))
	     (ex-env (extend-env 
		      (map car (cadr exp))
		      (map (lambda (iter-spec) (eval-exp (cadr iter-spec) env)) 
			   (cadr exp))
		      env)))
    (if (eval-exp test                ex-env)
	(eval-exp `(begin ,@tail-seq) ex-env)
	(begin (eval-body body ex-env)
	       (step iter-specs ex-env)
	       (loop iter-specs test tail-seq body ex-env)))))

(define (my-define-macro x env)
  (assert `("error define-macro syntax: " ,x)
	  (and (list? x) (>= (length x) 3) (eq? (car x) 'define-macro)))
  (cond
   ;; (define-macro Id Exp)
   ((symbol? (cadr x))
    (let ((bound (get-bound (cadr x) env)))
      (cond
       ;; in case var is defined as macro
       ((and bound (macro-var? (cdr bound)))
        (set-cdr! bound (eval-exp (caddr x) env))
	(cadr x))
       ;; in case var is defined
       (bound
        (set-macroname! (cadr x))
	(set-cdr! bound (eval-exp (caddr x) env))
	(cadr x))
       ;; in case var is not defined
       (else
        (set! *global-env*
	      (cons (cons (cadr x) (eval-exp (caddr x) env)) *global-env*))
	(set-macroname! (cadr x))
	(cadr x)))))
   ;; (define-macro (var formals) body)
   ;; -> (define var (lambda (formals) body))
   ;; (define (var . formal) body) -> (define var (lambda formal body))
   ((and (pair? (cadr x)) (symbol? (caadr x)))
    (my-define-macro
     `(define-macro ,(caadr x) (lambda ,(cdadr x) ,@(cddr x)))
     env))
   (else
    (abort `("error define-macro syntax: " ,x)))))

;;; (lambda Arg Body)
;;; Arg  ::= Id | (Id* [Id . Id])
;;; Body ::= Define* Exp+
(define (my-lambda exp env)
  (define (improper-arg? arg)
    (cond
     ((and (symbol? (car arg)) (symbol? (cdr arg)))
      #t)
     ((and (symbol? (car arg)) (pair? (cdr arg)))
      (improper-arg? (cdr arg)))
     (else
      #f)))

  (assert `("error lambda syntax: " ,exp)
	  (and (list? exp) (>= (length exp) 3) (eq? (car exp) 'lambda)
	       (or (symbol? (cadr exp))
		   (and (list? (cadr exp))
			(not (member #f (map symbol? (cadr exp)))))
		   (and (pair? (cadr exp)) (improper-arg? (cadr exp))))))

  (lambda args (eval-exp (conv-to-exp (cddr exp) env)
			 (extend-env (cadr exp) args env))))

(define (conv-to-exp body env)
  (define (body? defexp)
    (cond
     ((null? defexp)
      #t)
     ((eq? (car defexp) #t)
      (body? (cdr defexp)))
     ((eq? (car defexp) #f)
      (not (member #t defexp)))))

  (define (separate-defexp expanded-body def exp boollst)
    (cond
     ((null? expanded-body)
      (if (null? def)
	  (cons 'begin (reverse exp))
	  `(letrec ,(reverse def) ,@(reverse exp))))
     ((car boollst)
      (separate-defexp (cdr expanded-body) 
		       (cons (cdr (desugar-def (car expanded-body))) def)
		       exp (cdr boollst)))		       
     (else
      (separate-defexp (cdr expanded-body) def (cons (car expanded-body) exp) 
		       (cdr boollst)))))

  (let* ((expanded-body (map (lambda (expr) (if (and (list? expr) (not (null? expr))
						     (macro-var? (car expr)))
						(expand-macro expr env)
						expr))
			     body))
	 (boollst       (map (lambda (def) (define? def)) expanded-body)))
    (assert `("error body syntax: " ,body) (body? boollst))
    (separate-defexp expanded-body '() '() boollst)))