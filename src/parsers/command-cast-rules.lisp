;;;
;;; Now parsing CAST rules for migrating from MySQL
;;;

(in-package :pgloader.parser)

(defrule cast-typemod-guard (and kw-when sexp)
  (:destructure (w expr) (declare (ignore w)) (cons :typemod expr)))

(defrule cast-default-guard (and kw-when kw-default quoted-string)
  (:destructure (w d value) (declare (ignore w d)) (cons :default value)))

(defrule cast-source-guards (* (or cast-default-guard
				   cast-typemod-guard))
  (:lambda (guards)
    (alexandria:alist-plist guards)))

;; at the moment we only know about extra auto_increment
(defrule cast-source-extra (and kw-with kw-extra kw-auto-increment)
  (:constant (list :auto-increment t)))

(defrule cast-source-type (and kw-type trimmed-name)
  (:destructure (kw name) (declare (ignore kw)) (list :type name)))

(defrule table-column-name (and namestring "." namestring)
  (:destructure (table-name dot column-name)
    (declare (ignore dot))
    (list :column (cons (text table-name) (text column-name)))))

(defrule cast-source-column (and kw-column table-column-name)
  ;; well, we want namestring . namestring
  (:destructure (kw name) (declare (ignore kw)) name))

(defrule cast-source (and (or cast-source-type cast-source-column)
			  (? cast-source-extra)
			  (? cast-source-guards)
			  ignore-whitespace)
  (:lambda (source)
    (bind (((name-and-type opts guards _)       source)
           ((&key (default nil d-s-p)
                  (typemod nil t-s-p)
                  &allow-other-keys)            guards)
           ((&key (auto-increment nil ai-s-p)
                  &allow-other-keys)            opts))
      `(,@name-and-type
		,@(when t-s-p (list :typemod typemod))
		,@(when d-s-p (list :default default))
		,@(when ai-s-p (list :auto-increment auto-increment))))))

(defrule cast-type-name (and (alpha-char-p character)
			     (* (or (alpha-char-p character)
				    (digit-char-p character))))
  (:text t))

(defrule cast-to-type (and kw-to cast-type-name ignore-whitespace)
  (:lambda (source)
    (bind (((_ type-name _) source))
      (list :type type-name))))

(defrule cast-keep-default  (and kw-keep kw-default)
  (:constant (list :drop-default nil)))

(defrule cast-keep-typemod (and kw-keep kw-typemod)
  (:constant (list :drop-typemod nil)))

(defrule cast-keep-not-null (and kw-keep kw-not kw-null)
  (:constant (list :drop-not-null nil)))

(defrule cast-drop-default  (and kw-drop kw-default)
  (:constant (list :drop-default t)))

(defrule cast-drop-typemod (and kw-drop kw-typemod)
  (:constant (list :drop-typemod t)))

(defrule cast-drop-not-null (and kw-drop kw-not kw-null)
  (:constant (list :drop-not-null t)))

(defrule cast-def (+ (or cast-to-type
			 cast-keep-default
			 cast-drop-default
			 cast-keep-typemod
			 cast-drop-typemod
			 cast-keep-not-null
			 cast-drop-not-null))
  (:lambda (source)
    (destructuring-bind
	  (&key type drop-default drop-typemod drop-not-null &allow-other-keys)
	(apply #'append source)
      (list :type type
	    :drop-default drop-default
	    :drop-typemod drop-typemod
	    :drop-not-null drop-not-null))))

(defun function-name-character-p (char)
  (or (member char #.(quote (coerce "/:.-%" 'list)))
      (alphanumericp char)))

(defrule function-name (* (function-name-character-p character))
  (:text t))

(defrule cast-function (and kw-using function-name)
  (:lambda (function)
    (bind (((_ fname) function))
      (intern (string-upcase fname) :pgloader.transforms))))

(defun fix-target-type (source target)
  "When target has :type nil, steal the source :type definition."
  (if (getf target :type)
      target
      (loop
	 for (key value) on target by #'cddr
	 append (list key (if (eq :type key) (getf source :type) value)))))

(defrule cast-rule (and cast-source (? cast-def) (? cast-function))
  (:lambda (cast)
    (destructuring-bind (source target function) cast
      (list :source source
	    :target (fix-target-type source target)
	    :using function))))

(defrule another-cast-rule (and comma cast-rule)
  (:lambda (source)
    (bind (((_ rule) source)) rule)))

(defrule cast-rule-list (and cast-rule (* another-cast-rule))
  (:lambda (source)
    (destructuring-bind (rule1 rules) source
      (list* rule1 rules))))

(defrule casts (and kw-cast cast-rule-list)
  (:lambda (source)
    (bind (((_ casts) source))
      (cons :casts casts))))