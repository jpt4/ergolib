
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; RFFI - Ron's Foreign Function Interface
;;; 

(defun ff-lookup (name) (%REFERENCE-EXTERNAL-ENTRY-POINT (external name)))

(defun ff-load (path) (open-shared-library (namestring (pathname path))))

(defconstant +bytes-per-int+ (ceiling (log most-positive-fixnum 2) 8))

(defconstant +signed-int-type+
  (getf '(4 :signed-fullword 8 :signed-doubleword) +bytes-per-int+))

(defconstant +unsigned-int-type+
  (getf '(4 :unsigned-fullword 8 :unsigned-doubleword) +bytes-per-int+))

(defun convert-ff-type (type)
  (or (getf '(:int #.+signed-int-type+
              :uint #.+unsigned-int-type+
	      :int64 :signed-doubleword
              :uint64 :unsigned-doubleword
	      :int32 :signed-fullword
	      :uint32 :unsigned-fullword
              :ptr :address
              :cstr :address)
            type)
      type))

(defun safe-get-cstring (ptr)
  (if (%null-ptr-p ptr) nil (%get-cstring ptr)))

; DEFFF = DEFine Foreign Function
;
(defmacro defff (name (&rest argtypes) return-type)
  (let ( (c-name (if (consp name) (first name) name))
         (lisp-name (if (consp name) (second name) (intern (string-upcase name)))) )
    (let ( (args (mapcar (lambda (type) (gensym (symbol-name type))) argtypes)) )
      `(defun ,lisp-name ,args
         (with-cstrs ,(remove nil
                              (mapcar (lambda (arg type)
                                        (if (eq type :cstr) (list arg arg) '()))
                                      args argtypes))
           (,(if (eq return-type :cstr) 'safe-get-cstring 'identity)
            (ccl:ff-call
             ,(ff-lookup c-name)
             ,@(loop for type in argtypes for arg in args
                     collect (convert-ff-type type)
                     collect arg)
             ,(convert-ff-type return-type))))))))

(shadow 'ff-call)

;;; NOTE: The argument format for this FF-CALL is different from the normal
;;; MCL FF_CALL.  The format for this FF-CALL is:
;;;
;;;   (ff-call [return-type] name-or-entry-point [type] arg ...)
;;;
;;; Note that the types are optional.  If you leave them out FF-CALL will do
;;; its best to do the Right Thing.
;;;
;;; Note also that while you can pass an entry point instead of a name that
;;; doesn't save you very much because ff-lookup caches its results.
;;;
;;; In general, using FF-CALL is a bad idea.  Use DEFFF instead.

(defun ff-call (ff &rest args)
  (let ( (return-type :address) )
    (when (keywordp ff)
      (setf return-type (convert-ff-type ff))
      (setf ff (pop args)))
    (unless (fixnump ff) (setf ff (ff-lookup ff)))
    (if (keywordp (first args))
      (eval `(ccl:ff-call ,ff ,@(append args (list return-type))))
      (let* ( (strings (loop for arg in args if (stringp arg) collect arg))
              (stringvars (mapcar (lambda (arg)
                                    (declare (ignore arg))
                                    (gensym "S"))
                                  strings))
              (args (mapcan (lambda (arg)
                              (etypecase arg
                                (integer (list :signed-doubleword arg))
                                (macptr (list :address arg))
                                (string (list :address
                                              (nth (position arg strings)
                                                   stringvars)))))
                            args)) )
        (eval
         `(with-cstrs ,(mapcar #'list stringvars strings)
            (ccl:ff-call ,ff ,@args ,return-type)))))))

(provide 'rffi)

#|
; Examples:

(defff "popen" (:cstr :cstr) :ptr)
(defff "pclose" (:ptr) :int32)
(defff "fgetc" (:ptr) :int32)
(defff "fileno" (:ptr) :int32)
(defff "feof" (:ptr) :int32)
(defff "ferror" (:ptr) :int32)

(defun system (cmd &optional (action #'princ))
  (setf cmd (substitute #\lf #\newline cmd))
  (let ( (fileptr (popen cmd "r")) )
    (unwind-protect
        (loop for c = (fgetc fileptr)
          while (zerop (feof fileptr))
          do (if (>= c 0)
               (let ( (c (code-char c)) )
                 (funcall action (if (eql c #\lf) #\newline c))))
          finally (return fileptr))
      (pclose fileptr)
)))

(defun system1 (cmd)
  (let* ((fp (popen cmd "r"))
         (fd (fileno fp))
         (s (ccl::make-fd-stream fd)))
    (unwind-protect (read s) (pclose fp) (close s))))

(system "ls -l")

; Or juse use ccl:run-program!

; Watch this trick!

(system "cat<<EOF>~/foo.c
int foo(int x, int y) { return x+y; }
EOF")

(system "cd ~; gcc -m64 -bundle -o foo.dylib foo.c")

; open-shared-library doesn't do shell expansion so we have to jump
; through a little hoop

(defun get-homedir ()
  (with-output-to-string (s)
    (system "cd ~;pwd" (lambda (c) (unless (eql c #\newline) (princ c s))))))

(ff-load (concatenate 'string (get-homedir) "/foo.dylib"))

(ff-call :int "foo" 3 4)

;;;;;;
;
; Socket examples
;

(ff-load "/Users/ron/devel/sockets/sockets.dylib")

(defun foo ()
  (setf s (ccl::make-tcp-stream
           (ff-call :int "open_tcp_client" "www.google.com" 80) :direction :io))
  (format s "GET / HTTP/1.0~%~%")
  (force-output s)
  (ccl::while (print (read-line s nil nil)))
  (close s))

(time (foo))

(setf server (ff-call :int "open_server_socket" 1234))
(defun serve ()
  (let* ( (fd (ff-call :int "accept_client_socket" server))
	  (s (ccl::make-tcp-stream fd))
          (i (get-internal-real-time)) )
    (read-line s)
    (format s "HTTP/1.0 200 OK
Content-type: text/plain

Hello world ~s
" i)
    (finish-output s)
    (close s)
    (values s fd i)))

; Sockets from scratch
(defun foreign-type-of (r)
  (gethash (ccl::%macptr-type r) (ccl::ftd-ordinal-types ccl::*target-ftd*)))

(defun offset-of-field (ptr field)
  (ceiling
   (ccl::foreign-record-field-offset
    (ccl::%find-foreign-record-type-field (foreign-type-of ptr) field))
   8))

(defun address-of-field (ptr field)
  (%inc-ptr ptr (offset-of-field ptr field)))

(defun sizeof (ptr)
  (ceiling (ccl::ensure-foreign-type-bits (foreign-type-of ptr)) 8))

(ccl::foreign-size (:struct :sockaddr_un) :bytes)

(defmacro unix-call-sequence (&body forms)
  `(progn ,@(mapcar (lambda (form)
		      `(if (not (zerop ,form))
			 (error "~S returned non-zero result code" ',form)))
		    forms)))

(defun open-unix-server-socket (path)
  (rlet ((r :sockaddr_un))
    (#_bzero r (sizeof r))
    (with-cstrs ((cpath path))
      (#_bcopy cpath (address-of-field r :sun_path) (length path)))
    (setf (pref r :sockaddr_un.sun_family) #$AF_UNIX)
    (let ((sock (#_socket #$AF_UNIX #$SOCK_STREAM 0)))
      (unix-call-sequence
       (#_bind sock r (sizeof r))
       (#_listen sock 5))
      sock)))

(#_close sock)

|#
