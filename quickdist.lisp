(in-package #:quickdist)

(defparameter *distinfo-template*
  "name: {name}
version: {version}
distinfo-subscription-url: {base-url}/{name}.txt
release-index-url: {base-url}/{name}/{version}/releases.txt
system-index-url: {base-url}/{name}/{version}/systems.txt
")
(defparameter *distinfo-file-template* "{dists-dir}/{name}.txt")
(defparameter *dist-dir-template*      "{dists-dir}/{name}/{version}")
(defparameter *archive-dir-template*   "{dists-dir}/{name}/archive")
(defparameter *archive-url-template*   "{base-url}/{name}/archive")

(defparameter *gnutar* "/bin/tar"
  "Location of the GNU TAR program")

(defvar *template-readtable*
  (let ((readtable (copy-readtable)))
    (set-syntax-from-char #\} #\) readtable)
    readtable))

(defun read-template-form (stream)
  (let ((*readtable* *template-readtable*)
        (*package* (symbol-package :keyword)))
    (read-delimited-list #\} stream)))

(defmacro do-character-stream ((var stream &optional result) &body body)
  `(loop for ,var = (read-char ,stream nil)
         while ,var do ,@body
         finally (return ,result)))

(defun render-template (template data)
  (with-output-to-string (out)
    (with-input-from-string (in template)
      (do-character-stream (c in)
        (if (not (char= c #\{))
            (write-char c out)
            (let ((form (read-template-form in)))
              (princ (or (getf data (car form))
                         (error "The value of {~a} is undefined." (car form)))
                     out)))))))

(defun effective-mtime (path)
  (if (not (fad:directory-pathname-p path))
      (file-write-date path)
      (apply #'max 0 (mapcar #'effective-mtime (fad:list-directory path)))))

(defun format-date (universal-time)
  (let* ((time (multiple-value-list (decode-universal-time universal-time)))
         (timestamp (reverse (subseq time 0 6))))
    (format nil "~{~2,'0d~}" timestamp)))

(defun md5sum (path)
  (ironclad:byte-array-to-hex-string
   (ironclad:digest-file :md5 path)))

(defun tar-content-sha1 (path)
  (let ((octets (babel-streams:with-output-to-sequence (buffer)
                  (external-program:run *gnutar* (list "-xOf" path) :output buffer))))
    (ironclad:byte-array-to-hex-string
     (ironclad:digest-sequence :sha1 (copy-seq octets)))))

(defun last-directory (path)
  (first (last (pathname-directory path))))

(defun native-namestring (path)
  #+ccl(ccl:native-translated-namestring path)
  #+sbcl(sb-ext:native-namestring path)
  #-(or ccl sbcl)(namestring path))

(defun archive (destdir-path source-path)
  (let* ((mtime (format-date (effective-mtime source-path)))
         (name (format nil "~a-~a" (last-directory source-path) mtime))
         (out-path (make-pathname :name name :type "tgz" :defaults (truename destdir-path))))
    (external-program:run *gnutar* (list "-C" (native-namestring source-path) "."
                                           "-czf" (native-namestring out-path)
                                           "--transform" (format nil "s#^.#~a#" name))
                          :output *standard-output* :error *error-output*)
    out-path))


(defun find-system-files (path black-list)
  (flet ((system-name->filename (name) (concatenate 'string name ".asd")))
    (let ((system-files nil)
          (blacklisted-filenames (mapcar #'system-name->filename black-list)))
      (flet ((add-system-file (path) (push path system-files))

             (asd-file-p (path) (and (string-equal "asd" (pathname-type path))
                                     (not (find (file-namestring path) blacklisted-filenames
                                                :test #'equalp)))))
        (fad:walk-directory path #'add-system-file :test #'asd-file-p))
      (sort system-files #'string< :key #'pathname-name))))

(defun asdf-dependency-name (form)
  (if (and (listp form) (eq :feature (car form)))
      (asdf-dependency-name (third form))
      (cond
        ((and (listp form) (eq :version (first form)))
         (second form))
        (t form))))


(defun stringify (value)
  (format nil "~(~A~)" value))


(defun stringify-list (list)
  (mapcar #'stringify list))


(defun get-systems (asd-path)
  (asdf:load-asd asd-path)
  (let ((project-name (pathname-name (fad:pathname-as-file asd-path))))
    (flet ((not-starts-with-name (system-name)
             (not (alexandria:starts-with-subseq project-name system-name)))
           (parse-dependency (dep)
             (string-downcase (if (listp dep)
                                  (first (reverse dep))
                                  dep))))
      (sort (loop for system-name in (remove-if #'not-starts-with-name (asdf:registered-systems))
               as system = (asdf:find-system system-name)
               collect (list* (string-downcase (asdf:component-name system))
                              (sort (mapcar #'parse-dependency
                                            (nconc (asdf:system-defsystem-depends-on system)
                                                   (asdf:system-depends-on system)))
                                    #'string-lessp)))
            #'string-lessp
            :key #'first))))


(defun unix-filename (path)
  (format nil "~a.~a" (pathname-name path) (pathname-type path)))


(defun unix-filename-relative-to (base path)
  (let ((base-name (native-namestring (truename base)))
        (path-name (native-namestring (truename path))))
    (subseq path-name (mismatch base-name path-name))))


(defun blacklisted (project-name black-alist)
  (let ((project-string (stringify project-name)))
    (when-let ((blacklisted (assoc project-string black-alist :test #'equal)))
      (rest blacklisted))))


(defun blacklistedp (project-name system-name black-alist)
  (find (stringify system-name) (blacklisted project-name black-alist)))


(defun create-dist (projects-path dist-path archive-path archive-url black-alist)
  (with-open-file (release-index (make-pathname :name "releases" :type "txt" :defaults dist-path)
                                 :direction :output :if-exists :supersede)
    (write-line "# project url size file-md5 content-sha1 prefix [system-file1..system-fileN]" release-index)
    (with-open-file (system-index (make-pathname :name "systems" :type "txt" :defaults dist-path)
                                  :direction :output :if-exists :supersede)
      (write-line "# project system-file system-name [dependency1..dependencyN]" system-index)
      (dolist (project-path (fad:list-directory projects-path))
        (when (fad:directory-pathname-p project-path)
          (let* ((project-name (last-directory project-path))
                 (system-files (find-system-files project-path
                                                  (blacklisted project-name black-alist))))
            (if (not system-files)
                (warn "No .asd files found in ~a, skipping." project-path)
                (with-simple-restart (skip-project "Skip this project, continue with the next.")
                  (let* ((tgz-path (archive archive-path project-path))
                         (project-prefix (pathname-name tgz-path))
                         (project-url (format nil "~a/~a" archive-url (unix-filename tgz-path))))
                    (format *error-output* "Processing ~a...~%" project-name)
                    (format release-index "~a ~a ~a ~a ~a ~a~{ ~a~}~%"
                            project-name project-url (file-size tgz-path)
                            (md5sum tgz-path) (tar-content-sha1 tgz-path) project-prefix
                            (mapcar (curry #'unix-filename-relative-to project-path)
                                    system-files))
                    (dolist (system-file system-files)
                      (dolist (name-and-dependencies (get-systems system-file))
                        (let ((*print-case* :downcase)
                              (system-name (pathname-name system-file)))
                          (unless (blacklistedp project-name system-name black-alist)
                            (format system-index "~a ~a ~a~{ ~a~}~%"
                                    project-name
                                    system-name
                                    (first name-and-dependencies)
                                    (rest name-and-dependencies)))))))))))))))


(defun quickdist (&key name (version :today) base-url projects-dir dists-dir black-alist)
  (let* ((version (if (not (eq version :today)) version (format-date (get-universal-time))))
         (projects-path (fad:pathname-as-directory projects-dir))
         (template-data (list :name name :version version
                              :base-url (string-right-trim "/" base-url)
                              :dists-dir (string-right-trim "/" (native-namestring dists-dir))))
         (distinfo-path (fad:pathname-as-file (render-template *distinfo-file-template*
                                                               template-data)))
         (dist-path (fad:pathname-as-directory (render-template *dist-dir-template*
                                                                template-data)))
         (archive-path (fad:pathname-as-directory (render-template *archive-dir-template*
                                                                   template-data)))
         (archive-url (render-template *archive-url-template* template-data)))
    (assert (fad:directory-exists-p projects-path))
    (ensure-directories-exist dist-path :verbose t)
    (ensure-directories-exist archive-path :verbose t)
    (create-dist projects-path dist-path archive-path archive-url
                 (mapcar #'stringify-list black-alist))
    (let ((distinfo (render-template *distinfo-template* template-data)))
      (dolist (path (list (make-pathname :name "distinfo" :type "txt" :defaults dist-path)
                          distinfo-path))
        (write-string-into-file distinfo path :if-exists :supersede)))))
